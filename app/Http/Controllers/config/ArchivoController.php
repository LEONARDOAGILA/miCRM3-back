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


use App\Services\AuditoriaService;
use App\Models\Archivo;

class ArchivoController extends Controller
{
    use ApiResponder;      

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
     *   padre     id de la carpeta; 0 o ausente = raíz
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
            $padre   = (int) $request->input('padre', 0);
            $perPage = max(1, min(100, (int) $request->input('per_page', 10)));
            $search  = trim((string) $request->input('search', ''));

            $base = Archivo::where('padre', $padre);
            if ($search !== '') {
                $base->where(function ($q) use ($search) {
                    $q->where('nombre', 'ILIKE', "%{$search}%")
                      ->orWhere('descripcion', 'ILIKE', "%{$search}%");
                });
            }

            // Totales de la carpeta (con el filtro aplicado) para la barra de estado
            $carpetas = (clone $base)->where('escarpeta', true)->count();
            $archivos = (clone $base)->where('escarpeta', false)->count();

            $pagina = (clone $base)
                ->orderByDesc('escarpeta')
                ->orderBy('orden')
                ->orderBy('nombre')
                ->paginate($perPage);

            $funciones = new Funciones();
            $items = collect($pagina->items())->map(function ($item) use ($funciones) {
                $funciones->formatoFechaItem($item, ['created_at', 'updated_at']);
                return $item;
            })->values();

            return $this->successResponse([
                'data' => $items,
                'meta' => [
                    'total'        => $pagina->total(),
                    'per_page'     => $pagina->perPage(),
                    'current_page' => $pagina->currentPage(),
                    'last_page'    => max(1, $pagina->lastPage()),
                    'carpetas'     => $carpetas,
                    'archivos'     => $archivos,
                ],
            ], 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function getArchivoTree(){
        $archivoTree = Archivo::where('padre', 0)
                        ->orderBy('orden') // Ordenar el primer nivel por 'order2'
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

    

    public function addArchivo(Request $request){
        DB::beginTransaction();

        try {
            $exitoso = null;

                // Valida los datos (puedes usar la validación de Laravel, por ejemplo)
                $validatedData = $this->validate($request, [
                    'padre' => 'nullable|integer',
                    'orden' => 'nullable|integer',
                    'nivel' => 'nullable|integer',
                    'nombre' => 'required|string|max:255',
                    'url' => 'nullable|string|max:500',
                    'descripcion' => 'nullable|string',
                    'modulo' => 'nullable|string|max:255',
                    'icono' => 'nullable|string|max:255',
                    'color' => 'nullable|string|max:255',
                    'tipo' => 'nullable|string|max:30',
                    'tamano' => 'nullable|numeric',
                    'escarpeta' => 'required|boolean',
                    'activo' => 'nullable|boolean',
                    'nueva_ventana' => 'nullable|boolean',
                    'proteger_url' => 'nullable|boolean',
                ]);

                // Procesa los datos y crea uno nuevo
                $archivo = new Archivo();
                $archivo->padre = $validatedData['padre'];
                $archivo->orden = $validatedData['orden'];
                $archivo->nivel = $validatedData['nivel'];
                $archivo->nombre = $validatedData['nombre'];
                $archivo->url = $validatedData['url'];
                $archivo->descripcion = $validatedData['descripcion'];
                $archivo->modulo = $validatedData['modulo'];
                $archivo->icono = $validatedData['icono'];
                $archivo->color = $validatedData['color'];
                $archivo->escarpeta = $validatedData['escarpeta'];
                $archivo->tipo = $validatedData['tipo'] ?? 'link';
                $archivo->tamano = $validatedData['tamano'] ?? null;
                $archivo->activo = $validatedData['activo'] ?? true;   // antes no se grababa y quedaba NULL
                $archivo->nueva_ventana = $validatedData['nueva_ventana'] ?? false;   // abrir en otra pestaña
                $archivo->proteger_url = $validatedData['proteger_url'] ?? true;   // sin "abrir en pestaña" ni descarga (por defecto, como la columna)
                $archivo->save(); // Guarda
                // Registrar auditoría
                $this->auditar('INSERT', $archivo->id, null, $archivo->toArray());
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
            $validatedData = $this->validate($request, [
                'orden'       => 'nullable|integer',
                'nombre'      => 'required|string|max:255',
                'url'         => 'nullable|string|max:500',
                'descripcion' => 'nullable|string',
                'modulo'      => 'nullable|string|max:255',
                'icono'       => 'nullable|string|max:255',
                'color'       => 'nullable|string|max:255',
                'tipo'        => 'nullable|string|max:30',
                'tamano'      => 'nullable|numeric',
                'activo'      => 'nullable|boolean',
                'nueva_ventana' => 'nullable|boolean',   // abrir el enlace en otra pestaña del navegador
                'proteger_url'  => 'nullable|boolean',   // ocultar la url: sin abrir en pestaña ni descargar
            ]);

            $archivo = Archivo::findOrFail($id);
            $antes   = clone $archivo;

            // Si se sustituyó un fichero subido por otro (o por un enlace), el
            // anterior ya no lo referencia nadie: se borra del disco.
            $urlNueva = $validatedData['url'] ?? $archivo->url;
            if ($urlNueva !== $archivo->url) {
                $this->borrarFisico($archivo);
            }

            $archivo->fill($validatedData);
            $archivo->save();

            $this->auditar('UPDATE', $archivo->id, $antes->toArray(), $archivo->toArray());

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
     * Envía un archivo o carpeta a la papelera, con todo su contenido.
     */
    public function deleteArchivo(Request $request, $id){
        DB::beginTransaction();

        try {
            $archivo = Archivo::findOrFail($id);
            $ids     = $this->idsDelSubarbol($archivo->id, false);   // él y sus descendientes vivos

            Archivo::whereIn('id', $ids)->update(['deleted_at' => now(), 'es_eliminado' => true]);

            $this->auditar('DELETE', $archivo->id, $archivo->toArray(), [
                'papelera' => true,
                'elementos_enviados' => count($ids),
            ]);

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
    public function papelera(){
        try {
            $funciones = new Funciones();
            $todos = Archivo::withTrashed()->get()->keyBy('id');   // para armar las rutas

            $items = Archivo::onlyTrashed()->orderByDesc('deleted_at')->get()
                ->map(function ($item) use ($todos, $funciones) {
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
            $archivo = Archivo::onlyTrashed()->findOrFail($id);

            $ids = $this->idsDelSubarbol($archivo->id, true);   // él y sus descendientes en papelera

            // Antecesores que también estén en la papelera
            $padre = $archivo->padre;
            while ($padre) {
                $p = Archivo::withTrashed()->find($padre);
                if (!$p) { break; }
                if ($p->trashed()) { $ids[] = $p->id; }
                $padre = $p->padre;
            }

            Archivo::withTrashed()->whereIn('id', $ids)->update(['deleted_at' => null, 'es_eliminado' => false]);

            $this->auditar('RESTORE', $archivo->id, null, ['elementos_restaurados' => count($ids)]);

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
        DB::beginTransaction();

        try {
            $archivo = Archivo::onlyTrashed()->findOrFail($id);
            $ids = $this->idsDelSubarbol($archivo->id, true);

            $this->auditar('DELETE', $archivo->id, $archivo->toArray(), [
                'definitivo' => true,
                'elementos_borrados' => count($ids),
            ]);

            // Ficheros subidos: fuera del disco antes de perder la referencia
            Archivo::withTrashed()->whereIn('id', $ids)->get()->each(fn ($a) => $this->borrarFisico($a));
            Archivo::withTrashed()->whereIn('id', $ids)->forceDelete();

            DB::commit();
            return $this->successResponse(['borrados' => count($ids)], 'Se eliminó definitivamente');
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Borra de verdad todo lo que hay en la papelera. */
    public function vaciarPapelera(){
        DB::beginTransaction();

        try {
            $items = Archivo::onlyTrashed()->get();
            foreach ($items as $item) {
                $this->auditar('DELETE', $item->id, $item->toArray(), ['definitivo' => true, 'vaciar_papelera' => true]);
                $this->borrarFisico($item);
            }
            $borrados = Archivo::onlyTrashed()->forceDelete();

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

    /** Tipo (columna `tipo`) que corresponde a una extensión. */
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
    public function descargarArchivo($id){
        $archivo = Archivo::find($id);
        if (!$archivo || $archivo->escarpeta) {
            return $this->errorResponse('No existe el archivo', 404);
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
     * Registro en auditoria.auditoria a través del servicio. Antes se llamaba
     * a AuditoriaService::registrarAuditoria(), un método estático que no
     * existe: cada alta fallaba con "Call to undefined method" y hacía
     * rollback. La tabla se registra como 'archivo', que es lo que consulta
     * el modal de auditoría del front.
     */
    private function auditar(string $operacion, int $id, ?array $antes, ?array $despues): void {
        (new AuditoriaService())->registrar('archivo', $id, $operacion, $antes, $despues);
    }
}
