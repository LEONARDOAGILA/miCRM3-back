<?php
namespace App\Http\Controllers\config;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Illuminate\Http\Request;
use Exception;


use App\Http\Controllers\Controller;
use App\Http\Resources\Funciones;
use App\Http\Resources\ApiResponder;


use App\Models\Archivo;
use App\Http\Controllers\Concerns\ContextoAuditoria;
use App\Http\Controllers\Concerns\PermisosDeArchivo;

class ArchivoController extends Controller
{
    use ApiResponder, ContextoAuditoria, PermisosDeArchivo;

    public function __construct() {
        $this->middleware('auth:api',['except' =>[
            'allArchivos',
            'getArchivoTree',
            'findByIdArchivo',

            'list',
            'findByUser',
            'findByUser2',
        ]]);
    }

    /**
     * Contenido de una carpeta, paginado en servidor.
     *
     * Parámetros (query string):
     *   padre     id de la carpeta; 0, vacío o ausente = raíz (padre IS NULL)
     *   page      página (desde 1)
     *   per_page  filas por página (1-100, por defecto 10)
     *   search    filtra por nombre o descripción dentro de esa carpeta
     *
     * Respuesta con la misma forma que los listados paginados de seguridad
     * (allUsers, listHorarios), para que el front la consuma igual:
     *   data: { data: [...], meta: { total, per_page, current_page, last_page,
     *                                 carpetas, archivos } }
     * `carpetas` y `archivos` son los totales de la carpeta (no de la página),
     * para la barra de estado. Las carpetas van antes que los archivos, y
     * dentro de cada grupo por `orden` y nombre.
     */
    public function allArchivos(Request $request){
        try {
            $padre   = (int) $request->input('padre', 0) ?: null;   // null = raíz
            // per_page=0 → sin paginar: la carpeta entera (el front filtra y
            // ordena en ag-Grid). Con un valor, página de 1 a 500 filas.
            $perPage = (int) $request->input('per_page', 10);
            $todo    = $perPage <= 0;
            $perPage = $todo ? 0 : min(500, $perPage);
            $search  = trim((string) $request->input('search', ''));

            $base = Archivo::hijosDe($padre);
            if ($search !== '') {
                $base->where(function ($q) use ($search) {
                    $q->where('nombre', 'ILIKE', "%{$search}%")
                      ->orWhere('descripcion', 'ILIKE', "%{$search}%");
                });
            }

            // Totales de la carpeta (con el filtro aplicado) para la barra de estado
            $carpetas = (clone $base)->where('escarpeta', true)->count();
            $archivos = (clone $base)->where('escarpeta', false)->count();

            $consulta = (clone $base)
                ->orderByDesc('escarpeta')
                ->orderBy('orden')
                ->orderBy('nombre');

            $funciones = new Funciones();
            $formatear = function ($item) use ($funciones) {
                $funciones->formatoFechaItem($item, ['created_at', 'updated_at']);
                return $item;
            };

            if ($todo) {
                $items = $consulta->get()->map($formatear)->values();
                $meta  = [
                    'total'        => $items->count(),
                    'per_page'     => $items->count(),
                    'current_page' => 1,
                    'last_page'    => 1,
                ];
            } else {
                $pagina = $consulta->paginate($perPage);
                $items  = collect($pagina->items())->map($formatear)->values();
                $meta   = [
                    'total'        => $pagina->total(),
                    'per_page'     => $pagina->perPage(),
                    'current_page' => $pagina->currentPage(),
                    'last_page'    => max(1, $pagina->lastPage()),
                ];
            }

            return $this->successResponse([
                'data' => $items,
                'meta' => $meta + ['carpetas' => $carpetas, 'archivos' => $archivos],
            ], 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function getArchivoTree(){
        $archivoTree = Archivo::raices()               // padre IS NULL
                        ->orderBy('orden')
                        ->orderBy('nombre')
                        ->with('children') // Cargar los hijos recursivamente
                        ->get();

    // Formatear fechas
    $dateFields = ['created_at', 'updated_at'];
    $archivoTree->map(function ($item) use ($dateFields) {
        $funciones = new Funciones();
        $funciones->formatoFechaItem($item, $dateFields);
        
        // Aplicar recursivamente a los hijos
        if ($item->children->isNotEmpty()) {
            $this->formatChildrenDates($item->children, $dateFields);
        }
        
        return $item;
    });

        // Eliminar el campo 'children' si está vacío
        $archivoTree->each(function ($archivo) {
            if ($archivo->children->isEmpty()) {
                unset($archivo->children);
            } else {
                // Si hay hijos, aplicar la misma lógica recursivamente
                $this->removeEmptyChildren($archivo->children);
            }
        });

        return $this->successResponse($archivoTree, 'La solicitud ha tenido éxito');
    }

    // Método auxiliar recursivo para formatear fechas de hijos
    private function formatChildrenDates($children, $dateFields)
    {
        $funciones = new Funciones();
        
        $children->each(function ($child) use ($funciones, $dateFields) {
            $funciones->formatoFechaItem($child, $dateFields);
            
            if ($child->children->isNotEmpty()) {
                $this->formatChildrenDates($child->children, $dateFields);
            }
        });
    }

    private function removeEmptyChildren($children) {
        $children->each(function ($child) {
            if ($child->children->isEmpty()) {
                unset($child->children);
            } else {
                $this->removeEmptyChildren($child->children);
            }
        });
    }

    

    /**
     * Alta de carpeta o archivo. `padre` 0/vacío = raíz (se graba NULL); si
     * viene un id, tiene que ser una carpeta viva: la FK de la tabla ya
     * impide apuntar a un id inexistente, pero la validación da un mensaje
     * claro en vez del error de integridad. El nivel se calcula del padre,
     * no se confía en el que mande el front.
     */
    public function addArchivo(Request $request){
        DB::beginTransaction();

        try {
            $exitoso = null;
                $this->contextoAuditoria($request);

                // Longitudes = las de core.archivos
                $validatedData = $this->validate($request, [
                    'padre' => 'nullable|integer|min:0',
                    'orden' => 'nullable|integer',
                    'nombre' => 'required|string|max:100',
                    'url' => 'nullable|string|max:200',
                    'descripcion' => 'nullable|string|max:200',
                    'modulo' => 'nullable|string|max:100',
                    'icono' => 'nullable|string|max:100',
                    'color' => 'nullable|string|max:15',
                    'tipo' => 'nullable|string|max:30',
                    'tamano' => 'nullable|numeric',
                    'extension_archivo' => 'nullable|string|max:10',
                    'escarpeta' => 'required|boolean',
                    'activo' => 'nullable|boolean',
                    'nueva_ventana' => 'nullable|boolean',
                    'proteger_url' => 'nullable|boolean',
                    'publico' => 'nullable|boolean',
                ]);

                $padre = $this->carpetaPadre($validatedData['padre'] ?? null);   // null = raíz
                if (!$this->puedeCrearEn($padre?->id)) {
                    DB::rollBack();
                    return $this->errorResponse($padre ? 'No tiene permiso para crear dentro de esta carpeta' : 'Sólo un administrador puede crear en la raíz', 403);
                }

                // Procesa los datos y crea uno nuevo
                $archivo = new Archivo();
                $archivo->padre = $padre?->id;
                $archivo->orden = $validatedData['orden'] ?? 0;
                $archivo->nivel = $padre ? ($padre->nivel + 1) : 0;
                $archivo->nombre = $validatedData['nombre'];
                $archivo->url = $validatedData['url'];
                $archivo->descripcion = $validatedData['descripcion'];
                $archivo->modulo = $validatedData['modulo'];
                $archivo->icono = $validatedData['icono'];
                $archivo->color = $validatedData['color'];
                $archivo->escarpeta = $validatedData['escarpeta'];
                $archivo->tamano = $validatedData['tamano'] ?? null;
                $archivo->extension_archivo = isset($validatedData['extension_archivo']) ? strtolower($validatedData['extension_archivo']) : null;   // para reportería
                $archivo->tipo = self::tipoRegistro($archivo);   // UNIDAD / CARPETA / LINK / ARCHIVO <EXT>
                $archivo->activo = $validatedData['activo'] ?? true;   // antes no se grababa y quedaba NULL
                $archivo->nueva_ventana = $validatedData['nueva_ventana'] ?? false;   // abrir en otra pestaña
                $archivo->proteger_url = $validatedData['proteger_url'] ?? true;   // sin "abrir en pestaña" ni descarga (por defecto, como la columna)
                $archivo->publico = $validatedData['publico'] ?? false;   // lo ven todos los usuarios logueados
                $archivo->propietario_id = auth()->id();                   // quien lo crea tiene todos los permisos
                $archivo->save(); // Guarda (la auditoría la hace el trigger de la tabla)
                $exitoso = Archivo::orderBy('id', 'desc')->get();
                // Especificar las propiedades que representan fechas en tu objeto Nota
                $dateFields = ['created_at', 'updated_at'];
                
                // Utilizar la función map para transformar y obtener una nueva colección
                $exitoso->map(function ($item) use ($dateFields) {
                    $funciones = new Funciones();
                    $funciones->formatoFechaItem($item, $dateFields);
                    return $item;
                });
                
                DB::commit();
                
                return $this->successResponse($exitoso,'Se guardó con éxito');
        } catch (Exception $e) {
                DB::rollBack();
                return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Un archivo/carpeta por id, con las fechas formateadas como el resto.
     */
    public function findByIdArchivo($id){
        try {
            $archivo = Archivo::findOrFail($id);

            $funciones = new Funciones();
            $funciones->formatoFechaItem($archivo, ['created_at', 'updated_at']);

            return $this->successResponse($archivo, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse('No existe el archivo', 404);
        }
    }

    /**
     * Modifica un archivo o carpeta.
     *
     * Sólo se tocan los campos editables: el padre, el nivel y si es carpeta
     * se fijan al crearlo y no cambian desde aquí (moverlo de rama sería
     * otra operación, con sus propias comprobaciones).
     */
    public function editArchivo(Request $request, $id){
        DB::beginTransaction();

        try {
            $this->contextoAuditoria($request);

            // Longitudes = las de core.archivos
            $validatedData = $this->validate($request, [
                'orden'       => 'nullable|integer',
                'nombre'      => 'required|string|max:100',
                'url'         => 'nullable|string|max:200',
                'descripcion' => 'nullable|string|max:200',
                'modulo'      => 'nullable|string|max:100',
                'icono'       => 'nullable|string|max:100',
                'color'       => 'nullable|string|max:15',
                'tipo'        => 'nullable|string|max:30',
                'tamano'      => 'nullable|numeric',
                'extension_archivo' => 'nullable|string|max:10',
                'activo'      => 'nullable|boolean',
                'nueva_ventana' => 'nullable|boolean',   // abrir el enlace en otra pestaña del navegador
                'proteger_url'  => 'nullable|boolean',   // ocultar la url: sin abrir en pestaña ni descargar
                'publico'       => 'nullable|boolean',   // lo ven todos los usuarios logueados
            ]);

            $archivo = Archivo::findOrFail($id);
            if (!$this->puede('editar', (int) $archivo->id)) {
                DB::rollBack();
                return $this->errorResponse('No tiene permiso para modificar este elemento', 403);
            }
            // `publico` sólo lo cambia quien administra el nodo
            if (array_key_exists('publico', $validatedData) && !$this->puede('administrar', (int) $archivo->id)) {
                unset($validatedData['publico']);
            }

            // Si se sustituyó un fichero subido por otro (o por un enlace), el
            // anterior ya no lo referencia nadie: se borra del disco.
            $urlNueva = $validatedData['url'] ?? $archivo->url;
            if ($urlNueva !== $archivo->url) {
                $this->borrarFisico($archivo);
            }

            if (array_key_exists('extension_archivo', $validatedData) && $validatedData['extension_archivo'] !== null) {
                $validatedData['extension_archivo'] = strtolower($validatedData['extension_archivo']);
            }
            $archivo->fill($validatedData);
            $archivo->tipo = self::tipoRegistro($archivo);   // lo decide el registro, no el front
            $archivo->save();   // auditoría: trigger de la tabla

            $funciones = new Funciones();
            $funciones->formatoFechaItem($archivo, ['created_at', 'updated_at']);

            DB::commit();
            return $this->successResponse($archivo, 'Se modificó con éxito');
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }


    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================
    // "Eliminar" no borra: marca deleted_at (SoftDeletes) en el elemento y en
    // todo lo que cuelga de él, como al mandar una carpeta a la papelera de
    // Windows. Desde la papelera se restaura (con su contenido) o se borra de
    // verdad. Las consultas normales (árbol, hijos) no ven lo que está en la
    // papelera porque el modelo lleva SoftDeletes.

    /**
     * Mueve un archivo o carpeta (con todo su contenido) a otra carpeta.
     * Body: { padre: id de la carpeta destino, o 0/null para la raíz }.
     *
     * Comprobaciones: el destino existe, está vivo y es carpeta; no es el
     * propio elemento ni una carpeta que cuelgue de él (crearía un ciclo:
     * la FK no lo impide). Al mover se recalcula el `nivel` de todo el
     * subárbol, el `tipo` (UNIDAD ↔ CARPETA si una carpeta entra o sale de
     * la raíz) y el `orden` (último del destino). Si ya está ahí, no hace nada.
     */
    public function moverArchivo(Request $request, $id){
        DB::beginTransaction();

        try {
            $this->contextoAuditoria($request);
            $validatedData = $this->validate($request, [
                'padre' => 'nullable|integer|min:0',
            ]);

            $archivo = Archivo::findOrFail($id);
            $destino = $this->carpetaPadre($validatedData['padre'] ?? null);   // null = raíz

            if (($destino?->id) === $archivo->padre) {
                DB::rollBack();
                return $this->successResponse(['movidos' => 0], 'Ya está en esa ubicación');
            }
            if (!$this->puedeMoverA((int) $archivo->id, $destino?->id)) {
                DB::rollBack();
                return $this->errorResponse('No tiene permiso para mover este elemento a esa carpeta (hace falta editar sobre él y crear en el destino)', 403);
            }
            if ($error = $this->porQueNoSePuedeMover($archivo, $destino)) {
                DB::rollBack();
                return $this->errorResponse($error, 422);
            }

            $movidos = $this->aplicarMovimiento($archivo, $destino);

            DB::commit();

            $funciones = new Funciones();
            $funciones->formatoFechaItem($archivo, ['created_at', 'updated_at']);
            $mensaje = $movidos > 1
                ? "Se movió con {$movidos} elementos"
                : 'Se movió con éxito';
            return $this->successResponse(['archivo' => $archivo, 'movidos' => $movidos], $mensaje);
        } catch (\Illuminate\Validation\ValidationException $e) {
            DB::rollBack();
            return $this->errorResponse(collect($e->errors())->flatten()->first(), 422);
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Mueve varios elementos a la vez a la misma carpeta (o a la raíz), en
     * una sola transacción: si uno no se puede mover, no se mueve ninguno.
     * Body: { ids: [..], padre: id | 0 }.
     * Los que ya estén en el destino se saltan (no es error).
     */
    public function moverArchivos(Request $request){
        DB::beginTransaction();

        try {
            $this->contextoAuditoria($request);
            $validatedData = $this->validate($request, [
                'ids'   => 'required|array|min:1',
                'ids.*' => 'integer|distinct',
                'padre' => 'nullable|integer|min:0',
            ]);

            $destino  = $this->carpetaPadre($validatedData['padre'] ?? null);
            $archivos = Archivo::whereIn('id', $validatedData['ids'])->get();
            if ($archivos->count() !== count($validatedData['ids'])) {
                DB::rollBack();
                return $this->errorResponse('Alguno de los elementos ya no existe o está en la papelera', 404);
            }

            $movidos = 0; $saltados = 0;
            foreach ($archivos as $archivo) {
                if (($destino?->id) === $archivo->padre) { $saltados++; continue; }
                if (!$this->puedeMoverA((int) $archivo->id, $destino?->id)) {
                    DB::rollBack();
                    return $this->errorResponse("«{$archivo->nombre}»: no tiene permiso para moverlo a esa carpeta", 403);
                }
                if ($error = $this->porQueNoSePuedeMover($archivo, $destino)) {
                    DB::rollBack();
                    return $this->errorResponse("«{$archivo->nombre}»: {$error}", 422);
                }
                $movidos += $this->aplicarMovimiento($archivo, $destino);
            }

            DB::commit();
            $n = $archivos->count() - $saltados;
            $mensaje = $n === 0
                ? 'Ya estaban en esa ubicación'
                : "Se movieron {$n} " . ($n === 1 ? 'elemento' : 'elementos') . ($movidos > $n ? " ({$movidos} con su contenido)" : '');
            return $this->successResponse(['movidos' => $movidos, 'saltados' => $saltados], $mensaje);
        } catch (\Illuminate\Validation\ValidationException $e) {
            DB::rollBack();
            return $this->errorResponse(collect($e->errors())->flatten()->first(), 422);
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Envía varios elementos (con su contenido) a la papelera de una vez.
     * Body: { ids: [..] }. Una sola transacción.
     */
    public function eliminarArchivos(Request $request){
        DB::beginTransaction();

        try {
            $this->contextoAuditoria($request);
            $validatedData = $this->validate($request, [
                'ids'   => 'required|array|min:1',
                'ids.*' => 'integer|distinct',
            ]);

            $ids = [];
            foreach ($validatedData['ids'] as $id) {
                $archivo = Archivo::findOrFail($id);
                if (!$this->puede('eliminar', (int) $archivo->id)) {
                    DB::rollBack();
                    return $this->errorResponse("«{$archivo->nombre}»: no tiene permiso para eliminarlo", 403);
                }
                $ids = array_merge($ids, $this->idsDelSubarbol($archivo->id, false));
            }
            $ids = array_values(array_unique($ids));

            // El trigger de la tabla audita cada fila (UPDATE de deleted_at)
            Archivo::whereIn('id', $ids)->update(['deleted_at' => now(), 'es_eliminado' => true, 'deleted_by' => $this->loginActual()]);

            DB::commit();
            $n = count($validatedData['ids']);
            $mensaje = count($ids) > $n
                ? "Se enviaron {$n} elementos a la papelera (" . count($ids) . ' con su contenido)'
                : "Se enviaron {$n} " . ($n === 1 ? 'elemento' : 'elementos') . ' a la papelera';
            return $this->successResponse(['enviados' => count($ids)], $mensaje);
        } catch (\Illuminate\Validation\ValidationException $e) {
            DB::rollBack();
            return $this->errorResponse(collect($e->errors())->flatten()->first(), 422);
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Motivo por el que $archivo no puede ir dentro de $destino; null si puede. */
    private function porQueNoSePuedeMover(Archivo $archivo, ?Archivo $destino): ?string {
        if (!$destino) { return null; }
        if ($destino->id === $archivo->id) {
            return 'no se puede mover una carpeta dentro de sí misma';
        }
        if (in_array($destino->id, $this->idsDelSubarbol($archivo->id, false), true)) {
            return 'no se puede mover una carpeta dentro de una de sus subcarpetas';
        }
        return null;
    }

    /**
     * Cambia el padre de $archivo (ya validado): nivel, orden (último del
     * destino), tipo (UNIDAD ↔ CARPETA) y renivela sus descendientes.
     * Devuelve cuántos registros tocó (él + descendientes).
     */
    private function aplicarMovimiento(Archivo $archivo, ?Archivo $destino): int {
        $padreNuevo = $destino?->id;
        $archivo->padre = $padreNuevo;
        $archivo->nivel = $destino ? $destino->nivel + 1 : 0;
        $archivo->orden = (int) Archivo::hijosDe($padreNuevo)->where('id', '<>', $archivo->id)->max('orden') + 1;
        $archivo->tipo  = self::tipoRegistro($archivo);
        $archivo->save();   // auditoría: trigger de la tabla

        // Descendientes: cada uno un nivel más que su padre, en cascada
        return 1 + $this->renivelarDescendientes($archivo);
    }

    /** Recalcula el nivel de los descendientes vivos de $nodo. Devuelve cuántos tocó. */
    private function renivelarDescendientes(Archivo $nodo): int {
        $n = 0;
        foreach (Archivo::hijosDe($nodo->id)->get() as $hijo) {
            $nivel = $nodo->nivel + 1;
            if ($hijo->nivel !== $nivel) {
                $hijo->nivel = $nivel;
                $hijo->save();
            }
            $n += 1 + $this->renivelarDescendientes($hijo);
        }
        return $n;
    }

    /**
     * Envía un archivo o carpeta a la papelera, con todo su contenido.
     */
    public function deleteArchivo(Request $request, $id){
        DB::beginTransaction();

        try {
            $this->contextoAuditoria($request);
            $archivo = Archivo::findOrFail($id);
            if (!$this->puede('eliminar', (int) $archivo->id)) {
                DB::rollBack();
                return $this->errorResponse('No tiene permiso para eliminar este elemento', 403);
            }
            $ids     = $this->idsDelSubarbol($archivo->id, false);   // él y sus descendientes vivos

            // El trigger de la tabla audita cada fila (UPDATE de deleted_at)
            Archivo::whereIn('id', $ids)->update(['deleted_at' => now(), 'es_eliminado' => true, 'deleted_by' => $this->loginActual()]);

            DB::commit();
            $mensaje = count($ids) > 1
                ? 'Se enviaron ' . count($ids) . ' elementos a la papelera'
                : 'Se envió a la papelera';
            return $this->successResponse(['enviados' => count($ids)], $mensaje);
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Contenido de la papelera, más reciente primero. Cada elemento lleva
     * `ruta`: dónde estaba (nombres de sus antecesores), para saber a dónde
     * volvería al restaurarlo.
     */
    /**
     * Cuánto ocupan los ficheros subidos y cuánto disco queda, para el pie
     * del árbol del administrador ("SSD Storage" en la plantilla).
     *
     *   subidos      bytes que suman los ficheros subidos vivos (columna tamano)
     *   subidos_papelera  lo mismo para los que están en la papelera (siguen en disco)
     *   ficheros / enlaces / carpetas   cuántos hay de cada uno (vivos)
     *   por_tipo     desglose de bytes y unidades por extensión (ARCHIVO PDF…)
     *   disco        libre y total del disco donde está storage/app/public
     */
    public function almacenamiento(){
        if (!$this->esAdminDeArchivos()) { return $this->errorResponse('Sólo un administrador puede usar la papelera', 403); }
        try {
            $subidos = fn ($q) => $q->where('escarpeta', false)->where('url', 'like', 'storage/' . self::CARPETA_SUBIDAS . '/%');

            $vivos   = $subidos(Archivo::query());
            $porTipo = (clone $vivos)
                ->selectRaw('tipo, count(*) as unidades, coalesce(sum(tamano), 0) as bytes')
                ->groupBy('tipo')->orderByDesc('bytes')->get()
                ->map(fn ($r) => ['tipo' => $r->tipo, 'unidades' => (int) $r->unidades, 'bytes' => (float) $r->bytes]);

            $rutaDisco = Storage::disk('public')->path('');
            $libre = @disk_free_space($rutaDisco);
            $total = @disk_total_space($rutaDisco);

            return $this->successResponse([
                'subidos'          => (float) (clone $vivos)->sum('tamano'),
                'subidos_papelera' => (float) $subidos(Archivo::onlyTrashed())->sum('tamano'),
                'ficheros'         => (int) (clone $vivos)->count(),
                'enlaces'          => (int) Archivo::where('escarpeta', false)->where('url', 'not like', 'storage/%')->count(),
                'carpetas'         => (int) Archivo::where('escarpeta', true)->count(),
                'por_tipo'         => $porTipo,
                'disco'            => [
                    'libre' => $libre !== false ? (float) $libre : null,
                    'total' => $total !== false ? (float) $total : null,
                ],
            ], 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Contenido de la papelera. Un administrador la ve entera; el resto sólo
     * lo que puede RESTAURAR (permiso `restaurar`, propio o heredado de la
     * carpeta donde estaba). Cada elemento trae `ruta` (dónde estaba) y
     * `puede_restaurar` / `puede_borrar` para que el front pinte los botones.
     */
    public function papelera(){
        try {
            $esAdmin   = $this->esAdminDeArchivos();
            $funciones = new Funciones();
            $todos = Archivo::withTrashed()->get()->keyBy('id');   // para armar las rutas

            $items = Archivo::onlyTrashed()->orderByDesc('deleted_at')->get()
                ->filter(fn ($item) => $esAdmin || $this->puedeRestaurar((int) $item->id))
                ->map(function ($item) use ($todos, $funciones, $esAdmin) {
                    $item->puede_restaurar = true;
                    $item->puede_borrar    = $esAdmin;   // borrar definitivamente: sólo administradores
                    $ruta  = [];
                    $padre = $item->padre;
                    while ($padre && isset($todos[$padre])) {
                        array_unshift($ruta, $todos[$padre]->nombre);
                        $padre = $todos[$padre]->padre;
                    }
                    $item->ruta = $ruta ? implode(' / ', $ruta) : 'Raíz';
                    $funciones->formatoFechaItem($item, ['created_at', 'updated_at', 'deleted_at']);
                    return $item;
                })
                ->values();

            return $this->successResponse($items, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Restaura un elemento de la papelera con su contenido. Si la carpeta en la
     * que estaba también está en la papelera, se restauran sus antecesores:
     * si no, quedaría huérfano y no aparecería en el árbol.
     */
    public function restaurarArchivo(Request $request, $id){
        DB::beginTransaction();

        try {
            $this->contextoAuditoria($request);
            $archivo = Archivo::onlyTrashed()->findOrFail($id);
            if (!$this->puedeRestaurar((int) $archivo->id)) {
                DB::rollBack();
                return $this->errorResponse('No tiene permiso para restaurar este elemento', 403);
            }

            $ids = $this->idsDelSubarbol($archivo->id, true);   // él y sus descendientes en papelera

            // Antecesores que también estén en la papelera
            $padre = $archivo->padre;
            while ($padre) {
                $p = Archivo::withTrashed()->find($padre);
                if (!$p) { break; }
                if ($p->trashed()) { $ids[] = $p->id; }
                $padre = $p->padre;
            }

            // Auditoría: trigger de la tabla (UPDATE por fila)
            Archivo::withTrashed()->whereIn('id', $ids)->update(['deleted_at' => null, 'es_eliminado' => false, 'deleted_by' => null]);

            DB::commit();
            return $this->successResponse(['restaurados' => count($ids)], 'Se restauró con éxito');
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Borra de verdad un elemento de la papelera y todo lo que cuelga de él.
     * No hay vuelta atrás.
     */
    public function eliminarDefinitivo(Request $request, $id){
        if (!$this->esAdminDeArchivos()) { return $this->errorResponse('Sólo un administrador puede usar la papelera', 403); }
        DB::beginTransaction();

        try {
            $this->contextoAuditoria($request);
            $archivo = Archivo::onlyTrashed()->findOrFail($id);
            $ids = $this->idsDelSubarbol($archivo->id, true);

            // Ficheros subidos: fuera del disco antes de perder la referencia
            Archivo::withTrashed()->whereIn('id', $ids)->get()->each(fn ($a) => $this->borrarFisico($a));
            // Auditoría: trigger de la tabla (DELETE por fila). Se borran de
            // hijos a padres para no depender del ON DELETE SET NULL de la FK.
            Archivo::withTrashed()->whereIn('id', $ids)->orderByDesc('nivel')->get()->each(fn ($a) => $a->forceDelete());

            DB::commit();
            return $this->successResponse(['borrados' => count($ids)], 'Se eliminó definitivamente');
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Borra de verdad todo lo que hay en la papelera. */
    public function vaciarPapelera(Request $request){
        if (!$this->esAdminDeArchivos()) { return $this->errorResponse('Sólo un administrador puede usar la papelera', 403); }
        DB::beginTransaction();

        try {
            $this->contextoAuditoria($request);
            // De hijos a padres (nivel desc) para no depender del SET NULL de la FK
            $items = Archivo::onlyTrashed()->orderByDesc('nivel')->get();
            foreach ($items as $item) {
                $this->borrarFisico($item);
                $item->forceDelete();   // auditoría: trigger de la tabla
            }
            $borrados = $items->count();

            DB::commit();
            return $this->successResponse(['borrados' => $borrados], 'Papelera vaciada');
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }


    // ================================================================
    // FICHEROS SUBIDOS
    // ================================================================
    // Un "archivo" del administrador puede ser un enlace (tipo = link, la url
    // es externa) o un fichero subido (imagen, pdf, excel, word, video, otro).
    // Los subidos se guardan en storage/app/public/img/file-manager, que se
    // sirve en public/storage/img/file-manager gracias al enlace simbólico
    // (php artisan storage:link). En `url` se guarda la ruta relativa
    // "storage/img/file-manager/<fichero>"; el front le antepone la base.

    /** Carpeta dentro del disco `public` donde se guardan las subidas. */
    private const CARPETA_SUBIDAS = 'img/file-manager';

    /**
     * Extensiones que se clasifican en cada tipo. Lo que no esté aquí se
     * guarda como 'otro': no se rechaza nada por la extensión.
     */
    private const EXTENSIONES = [
        'imagen' => ['jpg', 'jpeg', 'png', 'gif', 'webp', 'svg', 'bmp', 'tif', 'tiff', 'ico'],
        'pdf'    => ['pdf'],
        'excel'  => ['xls', 'xlsx', 'xlsm', 'csv', 'ods'],
        'word'   => ['doc', 'docx', 'rtf', 'odt'],
        'video'  => ['mp4', 'webm', 'ogv', 'mov', 'avi', 'mkv', 'wmv', 'm4v', '3gp'],
        'audio'  => ['mp3', 'wav', 'ogg', 'oga', 'm4a', 'aac', 'flac', 'wma', 'opus', 'weba'],
    ];

    /**
     * Valor de la columna `tipo` de un registro. Lo decide el propio
     * registro, nunca el front:
     *   carpeta en la raíz → UNIDAD          carpeta dentro de otra → CARPETA
     *   fichero subido     → ARCHIVO <EXT>   (ARCHIVO PDF, ARCHIVO MP4…)
     *   enlace             → LINK
     * Hay que llamarlo con padre, escarpeta, extension_archivo y url ya puestos.
     */
    public static function tipoRegistro(Archivo $a): string {
        if ($a->escarpeta) {
            return $a->padre ? 'CARPETA' : 'UNIDAD';
        }
        $ext = strtolower(trim((string) $a->extension_archivo));
        if ($ext === '' && str_starts_with((string) $a->url, 'storage/')) {
            $ext = strtolower(pathinfo((string) $a->url, PATHINFO_EXTENSION));   // subidas antiguas sin extensión grabada
        }
        return $ext !== '' ? 'ARCHIVO ' . strtoupper($ext) : 'LINK';
    }

    /** Categoría (imagen, pdf, excel…) que corresponde a una extensión; la usa la subida para el front. */
    public static function tipoPorExtension(string $extension): string {
        $ext = strtolower($extension);
        foreach (self::EXTENSIONES as $tipo => $lista) {
            if (in_array($ext, $lista, true)) { return $tipo; }
        }
        return 'otro';
    }

    /**
     * Sube un fichero y devuelve dónde quedó y de qué tipo es. No crea el
     * registro: eso lo hace addArchivo / editArchivo con la url que se
     * devuelve aquí.
     *
     * El tipo se deduce de la EXTENSIÓN del nombre, no del contenido: la
     * regla `mimes:` de Laravel inspecciona los bytes, y un .xlsx o un .docx
     * son ZIP por dentro (los rechazaba como "zip"), y varios formatos de
     * video no están en su tabla. Tampoco hay tope de tamaño propio: manda
     * el de php.ini (upload_max_filesize / post_max_size).
     */
    public function subirArchivo(Request $request){
        try {
            if (!$request->hasFile('archivo') || !$request->file('archivo')->isValid()) {
                // Si supera post_max_size, PHP descarta la petición entera y
                // aquí no llega ni el fichero: el mensaje lo explica.
                return $this->errorResponse('No se recibió el archivo. Si es muy grande, revise upload_max_filesize y post_max_size en php.ini', 422);
            }

            $fichero   = $request->file('archivo');
            $extension = strtolower($fichero->getClientOriginalExtension());
            if ($extension === '') {
                return $this->errorResponse('El archivo no tiene extensión; no se puede clasificar', 422);
            }
            $tipo = self::tipoPorExtension($extension);

            $base   = Str::slug(pathinfo($fichero->getClientOriginalName(), PATHINFO_FILENAME)) ?: 'archivo';
            // Nombre único y legible: <nombre>-<fecha>-<aleatorio>.<ext>
            $nombre = substr($base, 0, 60) . '-' . date('Ymd-His') . '-' . Str::lower(Str::random(6)) . '.' . $extension;

            $ruta = $fichero->storeAs(self::CARPETA_SUBIDAS, $nombre, 'public');
            if (!$ruta) {
                return $this->errorResponse('No se pudo guardar el archivo en el servidor', 500);
            }

            return $this->successResponse([
                'url'             => 'storage/' . $ruta,          // relativa a la base del back
                'tipo'            => $tipo,
                'nombre_original' => $fichero->getClientOriginalName(),
                'nombre'          => $nombre,
                'extension'       => $extension,
                'mime'            => $fichero->getClientMimeType(),
                'tamano'          => $fichero->getSize(),          // bytes
            ], 'Archivo subido');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Descarga uno o varios elementos en un .zip. Body: { ids: [..] }.
     *
     * Las carpetas entran con toda su estructura (subcarpetas como rutas
     * dentro del zip). Sólo van los ficheros subidos: los enlaces se
     * incluyen como accesos directos .url (abren en el navegador) y los
     * ficheros con proteger_url se omiten (no se pueden descargar). Si al
     * final no hay nada que meter, 422.
     *
     * Nombre del zip: el de la carpeta si es una sola; si no,
     * "archivos-<fecha>.zip". El fichero temporal se borra tras enviarlo.
     * Necesita la extensión zip de PHP (ZipArchive).
     */
    public function descargarZip(Request $request){
        try {
            $validatedData = $this->validate($request, [
                'ids'   => 'required|array|min:1',
                'ids.*' => 'integer|distinct',
            ]);
            if (!class_exists(\ZipArchive::class)) {
                return $this->errorResponse('El servidor no tiene la extensión zip de PHP habilitada', 500);
            }

            $raices = Archivo::whereIn('id', $validatedData['ids'])->get();
            if ($raices->isEmpty()) {
                return $this->errorResponse('No existe ninguno de los elementos', 404);
            }

            $tmp = tempnam(sys_get_temp_dir(), 'micrm3-zip-');
            $zip = new \ZipArchive();
            if ($zip->open($tmp, \ZipArchive::OVERWRITE) !== true) {
                return $this->errorResponse('No se pudo crear el zip', 500);
            }

            $stats = ['ficheros' => 0, 'enlaces' => 0, 'omitidos' => 0];
            foreach ($raices as $nodo) {
                $this->agregarAlZip($zip, $nodo, '', $stats);
            }
            $zip->close();

            if ($stats['ficheros'] + $stats['enlaces'] === 0) {
                @unlink($tmp);
                return $this->errorResponse(
                    $stats['omitidos']
                        ? 'Nada que descargar: los ficheros seleccionados están protegidos'
                        : 'Nada que descargar: no hay ficheros ni enlaces en la selección',
                    422
                );
            }

            $nombre = $raices->count() === 1 && $raices->first()->escarpeta
                ? $this->nombreSeguro($raices->first()->nombre)
                : 'archivos-' . date('Ymd-Hi');

            return response()->download($tmp, $nombre . '.zip', [
                'Content-Type' => 'application/zip',
                // Para que el front pueda avisar de lo que se omitió
                'X-Zip-Ficheros' => $stats['ficheros'],
                'X-Zip-Enlaces'  => $stats['enlaces'],
                'X-Zip-Omitidos' => $stats['omitidos'],
            ])->deleteFileAfterSend(true);
        } catch (\Illuminate\Validation\ValidationException $e) {
            return $this->errorResponse(collect($e->errors())->flatten()->first(), 422);
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Mete $nodo en el zip bajo $rutaZip (carpeta padre dentro del zip, ''
     * en el nivel superior) y baja recursivamente por sus hijos vivos.
     */
    private function agregarAlZip(\ZipArchive $zip, Archivo $nodo, string $rutaZip, array &$stats): void {
        $nombre = $this->nombreSeguro($nodo->nombre);

        if ($nodo->escarpeta) {
            $carpeta = ($rutaZip === '' ? '' : $rutaZip . '/') . $nombre;
            $zip->addEmptyDir($carpeta);   // aunque esté vacía, que se vea
            foreach (Archivo::hijosDe($nodo->id)->orderBy('orden')->orderBy('nombre')->get() as $hijo) {
                $this->agregarAlZip($zip, $hijo, $carpeta, $stats);
            }
            return;
        }

        $prefijo = ($rutaZip === '' ? '' : $rutaZip . '/');
        $url     = (string) $nodo->url;

        // Fichero subido
        if (str_starts_with($url, 'storage/' . self::CARPETA_SUBIDAS . '/')) {
            // Protegido o sin permiso de descarga para este usuario: fuera del zip
            if ($nodo->proteger_url || !$this->puede('descargar', (int) $nodo->id)) { $stats['omitidos']++; return; }
            $rutaDisco = substr($url, strlen('storage/'));
            if (!Storage::disk('public')->exists($rutaDisco)) { $stats['omitidos']++; return; }
            $ext = pathinfo($rutaDisco, PATHINFO_EXTENSION);
            $zip->addFile(Storage::disk('public')->path($rutaDisco), $prefijo . $nombre . ($ext !== '' ? '.' . $ext : ''));
            $stats['ficheros']++;
            $this->registrarAcceso(request(), (int) $nodo->id, 'DESCARGAR');   // historial: también cuenta dentro del zip
            return;
        }

        // Enlace: acceso directo de Windows (.url), que también abre en Mac/Linux desde el navegador
        if ($url !== '' && !$nodo->proteger_url) {
            $zip->addFromString($prefijo . $nombre . '.url', "[InternetShortcut]\r\nURL={$url}\r\n");
            $stats['enlaces']++;
            return;
        }
        $stats['omitidos']++;
    }

    /** Nombre válido para fichero/carpeta dentro del zip (sin / \ : * ? " < > |). */
    private function nombreSeguro(?string $nombre): string {
        $limpio = trim(preg_replace('/[\\\\\/:*?"<>|\x00-\x1F]+/', ' ', (string) $nombre));
        return $limpio !== '' ? $limpio : 'archivo';
    }

    /**
     * Entrega un fichero subido como ADJUNTO (Content-Disposition: attachment),
     * para que el navegador lo descargue en vez de abrirlo.
     *
     * Hace falta porque el front y el back están en orígenes distintos y el
     * atributo `download` de un <a> sólo funciona en la misma origen: con la
     * url directa de storage el navegador abría el fichero en otra pestaña.
     * El nombre de descarga es el nombre del registro + la extensión real, no
     * el nombre interno con fecha y aleatorio.
     *
     * Va con token como el resto del grupo: el front lo pide con HttpClient
     * (responseType blob) y dispara la descarga desde memoria.
     */
    public function descargarArchivo(Request $request, $id){
        $archivo = Archivo::find($id);
        if (!$archivo || $archivo->escarpeta) {
            return $this->errorResponse('No existe el archivo', 404);
        }
        // Permiso por usuario (seguridad.fn_permiso_archivo); admin y propietario pasan
        if (!$this->puede('descargar', (int) $archivo->id)) {
            return $this->errorResponse('No tiene permiso para descargar este archivo', 403);
        }

        if ($archivo->proteger_url) {
            // El front ya no muestra el botón; esto cubre la llamada directa
            return $this->errorResponse('Este archivo está protegido: sólo se puede ver dentro del sistema', 403);
        }

        $url     = (string) $archivo->url;
        $prefijo = 'storage/' . self::CARPETA_SUBIDAS . '/';
        if (!str_starts_with($url, $prefijo)) {
            // Un enlace externo no se descarga desde aquí
            return $this->errorResponse('Este archivo es un enlace, no un fichero subido', 422);
        }

        $rutaDisco = substr($url, strlen('storage/'));   // img/file-manager/<fichero>
        if (!Storage::disk('public')->exists($rutaDisco)) {
            return $this->errorResponse('El fichero ya no está en el servidor', 404);
        }

        $extension = pathinfo($rutaDisco, PATHINFO_EXTENSION);
        // Nombre legible y seguro para el navegador (sin / \ : * ? " < > |)
        $base   = trim(preg_replace('/[\\\\\/:*?"<>|\x00-\x1F]+/', ' ', (string) $archivo->nombre)) ?: 'archivo';
        $nombre = $base . ($extension !== '' ? '.' . $extension : '');

        $this->registrarAcceso($request, (int) $archivo->id, 'DESCARGAR');
        return Storage::disk('public')->download($rutaDisco, $nombre);
    }

    /**
     * Borra del disco el fichero de un registro, si es una subida nuestra.
     * Los enlaces (tipo link, url externa) no tienen nada que borrar.
     */
    private function borrarFisico(Archivo $archivo): void {
        $url = (string) $archivo->url;
        $prefijo = 'storage/' . self::CARPETA_SUBIDAS . '/';
        if ($archivo->escarpeta || !str_starts_with($url, $prefijo)) { return; }

        $rutaDisco = substr($url, strlen('storage/'));   // img/file-manager/<fichero>
        if (Storage::disk('public')->exists($rutaDisco)) {
            Storage::disk('public')->delete($rutaDisco);
        }
    }
    // ================================================================
    // AUXILIARES
    // ================================================================

    /**
     * Ids de un elemento y de todos sus descendientes.
     * @param bool $enPapelera true = sólo los que están en la papelera;
     *                         false = sólo los vivos.
     */
    private function idsDelSubarbol(int $id, bool $enPapelera): array {
        $ids = [$id];
        $pendientes = [$id];
        while ($pendientes) {
            $consulta = $enPapelera ? Archivo::onlyTrashed() : Archivo::query();
            $hijos = $consulta->whereIn('padre', $pendientes)->pluck('id')->all();
            $ids = array_merge($ids, $hijos);
            $pendientes = $hijos;
        }
        return array_values(array_unique($ids));
    }

    /**
     * Carpeta padre para un alta: null si `padre` es 0/null (raíz). Si viene
     * un id, tiene que existir, estar viva y ser carpeta; si no, se corta con
     * un mensaje claro (la FK de la tabla ya lo impediría, pero con un error
     * de integridad ilegible).
     */
    private function carpetaPadre(?int $padre): ?Archivo {
        if (!$padre) { return null; }
        $carpeta = Archivo::find($padre);
        if (!$carpeta) {
            throw new Exception('La carpeta destino no existe o está en la papelera');
        }
        if (!$carpeta->escarpeta) {
            throw new Exception('Sólo se puede crear dentro de una carpeta');
        }
        return $carpeta;
    }

}
