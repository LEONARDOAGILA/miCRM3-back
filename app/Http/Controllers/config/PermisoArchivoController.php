<?php
namespace App\Http\Controllers\config;

use Illuminate\Support\Facades\DB;
use Illuminate\Http\Request;
use Exception;

use App\Http\Controllers\Controller;
use App\Http\Controllers\Concerns\ContextoAuditoria;
use App\Http\Controllers\Concerns\PermisosDeArchivo;
use App\Http\Resources\ApiResponder;
use App\Http\Resources\Funciones;
use App\Models\Archivo;
use App\Models\PermisoArchivo;

/**
 * Permisos por archivo (por usuario) y la vista "Mis archivos".
 *
 * Administración (quien tiene `administrar` sobre el nodo, o admin/propietario):
 *   GET    permisosArchivo/{id}              filas del nodo + heredadas + público/propietario
 *   POST   permisosArchivo/{id}              crea o actualiza la fila de un usuario
 *   DELETE permisosArchivo/{id}/{userId}     quita la fila de un usuario
 *   GET    usuariosParaPermisos?search=      usuarios para el selector
 *   GET    accesosArchivo/{id}               últimos accesos (quién abrió/descargó)
 *
 * Usuario final:
 *   GET    misArchivos                       árbol con lo que puede ver (con sus banderas)
 *   GET    miPermisoArchivo/{id}             banderas efectivas sobre un nodo
 *   POST   abrirArchivo/{id}                 autoriza `ejecutar`, deja rastro y devuelve el registro
 *
 * La regla vive en seguridad.fn_permiso_archivo; aquí sólo se consulta.
 */
class PermisoArchivoController extends Controller
{
    use ApiResponder, ContextoAuditoria, PermisosDeArchivo;

    public function __construct() {
        $this->middleware('auth:api');
    }

    // ================================================================
    // ADMINISTRAR PERMISOS DE UN NODO
    // ================================================================

    /**
     * Todo lo que hace falta para la pantalla de permisos de un nodo:
     *   archivo      nombre, escarpeta, publico, propietario (id/login/nombre)
     *   directos     filas de este nodo, con datos del usuario
     *   heredados    filas de ancestros con `hereda`, con `desde` (la carpeta),
     *                una por usuario (la más cercana); sólo usuarios sin fila directa
     *   puedeAdministrar  si el que consulta puede tocar (admin, propietario o `administrar`)
     */
    public function permisosDe(Request $request, $id){
        try {
            $archivo = Archivo::with('parent')->findOrFail($id);
            $puedeAdministrar = $this->puede('administrar', (int) $archivo->id);

            $directos = $this->filasConUsuario(PermisoArchivo::where('archivo_id', $archivo->id))
                ->map(fn ($f) => $f + ['origen' => 'DIRECTO', 'desde' => null]);

            // Ancestros de cerca a lejos
            $ancestros = [];
            $padre = $archivo->padre;
            while ($padre) {
                $p = Archivo::find($padre);
                if (!$p) { break; }
                $ancestros[] = $p;
                $padre = $p->padre;
            }

            $heredados = collect();
            $yaVistos  = $directos->pluck('user_id')->all();
            foreach ($ancestros as $anc) {
                $filas = $this->filasConUsuario(
                    PermisoArchivo::where('archivo_id', $anc->id)->where('hereda', true)->whereNotIn('user_id', $yaVistos)
                );
                foreach ($filas as $f) {
                    $heredados->push($f + ['origen' => 'HEREDADO', 'desde' => ['id' => $anc->id, 'nombre' => $anc->nombre]]);
                    $yaVistos[] = $f['user_id'];
                }
            }

            $propietario = $archivo->propietario_id
                ? DB::table('seguridad.users')->where('id', $archivo->propietario_id)->select('id', 'login_user', 'name', 'surname')->first()
                : null;

            return $this->successResponse([
                'archivo' => [
                    'id' => $archivo->id, 'nombre' => $archivo->nombre, 'escarpeta' => (bool) $archivo->escarpeta,
                    'publico' => (bool) $archivo->publico, 'padre' => $archivo->padre,
                    'propietario' => $propietario,
                ],
                'directos'  => $directos->values(),
                'heredados' => $heredados->values(),
                'puedeAdministrar' => $puedeAdministrar,
                // Ceder la propiedad: sólo el propietario actual o un administrador (como Google Drive)
                'puedeTransferir'  => $this->puedeTransferir($archivo),
            ], 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Sólo el propietario actual o un administrador pueden ceder la propiedad. */
    private function puedeTransferir(Archivo $archivo): bool
    {
        return $this->esAdminDeArchivos() || ((int) $archivo->propietario_id === (int) auth()->id());
    }

    /**
     * Cede la propiedad a otro usuario (como "Transferir la propiedad" de
     * Google Drive). Body:
     *   user_id            nuevo propietario (activo, distinto del actual)
     *   incluir_contenido  carpetas: también todo lo que cuelga (por defecto true)
     *   conservar_acceso   el propietario saliente queda con una fila directa
     *                      de editor (todo menos administrar) para no perder
     *                      el acceso (por defecto true)
     * Sólo el propietario actual o un administrador. El trigger de auditoría
     * de core.archivos deja constancia del cambio de propietario_id.
     */
    public function transferirPropietario(Request $request, $id){
        DB::beginTransaction();
        try {
            $this->contextoAuditoria($request, 'core.archivos');
            $archivo = Archivo::findOrFail($id);
            if (!$this->puedeTransferir($archivo)) {
                DB::rollBack();
                return $this->errorResponse('Sólo el propietario o un administrador pueden ceder la propiedad', 403);
            }

            $datos = $this->validate($request, [
                'user_id'           => 'required|integer',
                'incluir_contenido' => 'nullable|boolean',
                'conservar_acceso'  => 'nullable|boolean',
            ]);
            $nuevoId = (int) $datos['user_id'];
            $nuevo = DB::table('seguridad.users')->where('id', $nuevoId)->select('id', 'login_user', 'name', 'surname', 'isactive')->first();
            if (!$nuevo) {
                DB::rollBack();
                return $this->errorResponse('El usuario no existe', 422);
            }
            if (!$nuevo->isactive) {
                DB::rollBack();
                return $this->errorResponse('El usuario está inactivo: no puede ser propietario', 422);
            }
            if ($nuevoId === (int) $archivo->propietario_id) {
                DB::rollBack();
                return $this->errorResponse('Ese usuario ya es el propietario', 422);
            }

            $anteriorId       = $archivo->propietario_id ? (int) $archivo->propietario_id : null;
            $incluirContenido = (bool) ($datos['incluir_contenido'] ?? true);
            $conservarAcceso  = (bool) ($datos['conservar_acceso'] ?? true);

            // Qué cambia de dueño: el elemento y, si es carpeta y se pide, lo que cuelga
            // de ella (incluida la papelera, para que no quede huérfano al restaurar)
            $ids = [(int) $archivo->id];
            if ($archivo->escarpeta && $incluirContenido) {
                $ids = collect(DB::select(
                    'WITH RECURSIVE r AS (
                        SELECT id FROM core.archivos WHERE id = ?
                        UNION ALL
                        SELECT a.id FROM core.archivos a JOIN r ON a.padre = r.id
                     ) SELECT id FROM r', [$archivo->id]
                ))->pluck('id')->map(fn ($v) => (int) $v)->all();
            }

            // Uno a uno con Eloquent para que salte el trigger de auditoría por fila
            $cambiados = 0;
            foreach (Archivo::withTrashed()->whereIn('id', $ids)->get() as $a) {
                if ((int) $a->propietario_id === $nuevoId) { continue; }
                $a->propietario_id = $nuevoId;
                $a->save();
                $cambiados++;
            }

            // El nuevo propietario ya no necesita su fila directa (tiene todo por ser dueño)
            PermisoArchivo::whereIn('archivo_id', $ids)->where('user_id', $nuevoId)->delete();

            // El saliente se queda como editor del elemento raíz de la cesión (hereda hacia abajo)
            if ($conservarAcceso && $anteriorId && $anteriorId !== $nuevoId) {
                PermisoArchivo::updateOrCreate(
                    ['archivo_id' => $archivo->id, 'user_id' => $anteriorId],
                    [
                        'ver' => true, 'ejecutar' => true, 'descargar' => true, 'crear' => true,
                        'editar' => true, 'eliminar' => true, 'restaurar' => true, 'administrar' => false,
                        'hereda' => true, 'denegar' => false, 'vigente_hasta' => null,
                    ]
                );
            }

            DB::commit();
            $nombre = trim(($nuevo->name ?? '') . ' ' . ($nuevo->surname ?? '')) ?: $nuevo->login_user;
            return $this->successResponse([
                'propietario' => ['id' => $nuevo->id, 'login_user' => $nuevo->login_user, 'name' => $nuevo->name, 'surname' => $nuevo->surname],
                'cambiados'   => $cambiados,
            ], $cambiados > 1
                ? "Ahora {$nombre} es propietario de «{$archivo->nombre}» y de {$cambiados} elementos en total"
                : "Ahora {$nombre} es propietario de «{$archivo->nombre}»");
        } catch (\Illuminate\Validation\ValidationException $e) {
            DB::rollBack();
            return $this->errorResponse($e->validator->errors()->first(), 422);
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Filas de permisos con los datos del usuario (login, nombre, tipo, activo), como arrays. */
    private function filasConUsuario($consulta) {
        return $consulta
            ->join('seguridad.users as u', 'u.id', '=', 'seguridad.permisos_archivos.user_id')
            ->orderBy('u.name')->orderBy('u.surname')
            ->get([
                'seguridad.permisos_archivos.*',
                'u.login_user', 'u.name', 'u.surname', 'u.type_user', 'u.isactive', 'u.avatar',
            ])
            ->map(function ($f) {
                $a = $f->toArray();
                $a['vigente_hasta'] = $f->vigente_hasta ? $f->vigente_hasta->format('Y-m-d') : null;
                $a['caducado'] = $f->vigente_hasta ? $f->vigente_hasta->isPast() : false;
                return $a;
            });
    }

    /**
     * Crea o actualiza la fila (archivo, usuario). Body: user_id + banderas +
     * hereda + denegar + vigente_hasta (YYYY-MM-DD o null).
     * Sólo quien puede administrar el nodo. No se puede tocar el propio
     * permiso ni el de un admin (no lo necesitan).
     */
    public function guardar(Request $request, $id){
        DB::beginTransaction();
        try {
            $this->contextoAuditoria($request, 'seguridad.permisos_archivos');
            $archivo = Archivo::findOrFail($id);
            if (!$this->puede('administrar', (int) $archivo->id)) {
                DB::rollBack();
                return $this->errorResponse('No tiene permiso para administrar los permisos de este elemento', 403);
            }

            $datos = $this->validate($request, [
                'user_id'       => 'required|integer',
                'ver'           => 'nullable|boolean',
                'ejecutar'      => 'nullable|boolean',
                'descargar'     => 'nullable|boolean',
                'crear'         => 'nullable|boolean',
                'editar'        => 'nullable|boolean',
                'eliminar'      => 'nullable|boolean',
                'administrar'   => 'nullable|boolean',
                'restaurar'     => 'nullable|boolean',
                'hereda'        => 'nullable|boolean',
                'denegar'       => 'nullable|boolean',
                'vigente_hasta' => 'nullable|date',
            ]);
            if (!DB::table('seguridad.users')->where('id', (int) $datos['user_id'])->exists()) {
                DB::rollBack();
                return $this->errorResponse('El usuario no existe', 422);
            }
            if ((int) $datos['user_id'] === (int) auth()->id() && !$this->esAdminDeArchivos()) {
                DB::rollBack();
                return $this->errorResponse('No puede cambiar sus propios permisos', 422);
            }

            $valores = [
                'hereda'        => (bool) ($datos['hereda'] ?? true),
                'denegar'       => (bool) ($datos['denegar'] ?? false),
                'vigente_hasta' => !empty($datos['vigente_hasta']) ? \Carbon\Carbon::parse($datos['vigente_hasta'])->endOfDay() : null,
            ];
            foreach (PermisoArchivo::BANDERAS as $b) {
                // Con denegar, las banderas dan igual: se guardan en false para que se lea claro
                $valores[$b] = $valores['denegar'] ? false : (bool) ($datos[$b] ?? false);
            }
            if (!$valores['denegar'] && !$valores['ver']) {
                // Sin "ver" nada tiene sentido: no aparece en su árbol
                $valores['ver'] = array_reduce(PermisoArchivo::BANDERAS, fn ($c, $b) => $c || $valores[$b], false);
            }

            $fila = PermisoArchivo::updateOrCreate(
                ['archivo_id' => $archivo->id, 'user_id' => (int) $datos['user_id']],
                $valores
            );

            DB::commit();
            return $this->successResponse($fila, 'Permiso guardado');
        } catch (\Illuminate\Validation\ValidationException $e) {
            DB::rollBack();
            return $this->errorResponse(collect($e->errors())->flatten()->first(), 422);
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Quita la fila (archivo, usuario). Los heredados se quitan en la carpeta de la que vienen. */
    public function quitar(Request $request, $id, $userId){
        DB::beginTransaction();
        try {
            $this->contextoAuditoria($request, 'seguridad.permisos_archivos');
            $archivo = Archivo::findOrFail($id);
            if (!$this->puede('administrar', (int) $archivo->id)) {
                DB::rollBack();
                return $this->errorResponse('No tiene permiso para administrar los permisos de este elemento', 403);
            }
            $borradas = PermisoArchivo::where('archivo_id', $archivo->id)->where('user_id', (int) $userId)->delete();
            DB::commit();
            return $this->successResponse(['borradas' => $borradas], $borradas ? 'Permiso quitado' : 'No había permiso que quitar');
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Usuarios activos para el selector: por login, nombre o apellido. Máximo 30. */
    public function usuarios(Request $request){
        try {
            $q = trim((string) $request->input('search', ''));
            $consulta = DB::table('seguridad.users')
                ->select('id', 'login_user', 'name', 'surname', 'type_user', 'isactive', 'avatar')
                ->where('isactive', true)
                ->whereNull('deleted_at');
            if ($q !== '') {
                $consulta->where(function ($w) use ($q) {
                    $w->where('login_user', 'ILIKE', "%{$q}%")
                      ->orWhere('name', 'ILIKE', "%{$q}%")
                      ->orWhere('surname', 'ILIKE', "%{$q}%")
                      ->orWhere('email', 'ILIKE', "%{$q}%");
                });
            }
            return $this->successResponse($consulta->orderBy('name')->orderBy('surname')->limit(30)->get(), 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Historial de acciones de un archivo (quién lo abrió o descargó), para
     * quien administra. Filtros opcionales: accion (EJECUTAR | DESCARGAR),
     * desde / hasta (Y-m-d, día completo) y limit (por defecto 500). Para una
     * carpeta se incluyen las acciones sobre todo lo que cuelga de ella.
     */
    public function accesos(Request $request, $id){
        try {
            $archivo = Archivo::withTrashed()->findOrFail($id);   // también desde la papelera
            if (!$this->puede('administrar', (int) $archivo->id)) {
                return $this->errorResponse('No tiene permiso para ver el historial de este elemento', 403);
            }
            $request->validate([
                'accion' => 'nullable|in:EJECUTAR,DESCARGAR',
                'desde'  => 'nullable|date_format:Y-m-d',
                'hasta'  => 'nullable|date_format:Y-m-d',
                'limit'  => 'nullable|integer|min:1|max:5000',
            ]);

            // Carpeta: ella y todos sus descendientes; archivo: sólo él
            $ids = [(int) $archivo->id];
            if ($archivo->escarpeta) {
                $ids = collect(DB::select(
                    'WITH RECURSIVE r AS (
                        SELECT id FROM core.archivos WHERE id = ?
                        UNION ALL
                        SELECT a.id FROM core.archivos a JOIN r ON a.padre = r.id
                     ) SELECT id FROM r', [$archivo->id]
                ))->pluck('id')->map(fn ($v) => (int) $v)->all();
            }

            $q = DB::table('core.archivos_accesos as x')
                ->leftJoin('seguridad.users as u', 'u.id', '=', 'x.user_id')
                ->leftJoin('core.archivos as a', 'a.id', '=', 'x.archivo_id')
                ->whereIn('x.archivo_id', $ids);
            if ($request->filled('accion')) { $q->where('x.accion', $request->accion); }
            if ($request->filled('desde'))  { $q->where('x.created_at', '>=', $request->desde . ' 00:00:00'); }
            if ($request->filled('hasta'))  { $q->where('x.created_at', '<=', $request->hasta . ' 23:59:59'); }

            // Totales por acción (sin el límite de filas)
            $totales = (clone $q)->selectRaw('x.accion, count(*) as n')->groupBy('x.accion')->pluck('n', 'accion');

            $filas = $q->orderByDesc('x.created_at')
                ->limit((int) ($request->limit ?: 500))
                ->get(['x.id', 'x.archivo_id', 'a.nombre as archivo_nombre', 'a.tipo as archivo_tipo', 'x.accion', 'x.user_id',
                       'x.usuario_login', 'x.ip_address', 'x.user_agent', 'x.created_at', 'u.name', 'u.surname'])
                ->map(function ($f) {
                    $f->fecha = \Carbon\Carbon::parse($f->created_at)->format('Y-m-d H:i:s');
                    return $f;
                });

            return $this->successResponse([
                'filas'   => $filas,
                'totales' => [
                    'ejecutar'  => (int) ($totales['EJECUTAR'] ?? 0),
                    'descargar' => (int) ($totales['DESCARGAR'] ?? 0),
                ],
            ], 'La solicitud ha tenido éxito');
        } catch (\Illuminate\Validation\ValidationException $e) {
            return $this->errorResponse($e->validator->errors()->first(), 422);
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // USUARIO FINAL: MIS ARCHIVOS
    // ================================================================

    /**
     * Árbol con lo que el usuario puede VER, con sus banderas en cada nodo
     * (`permiso`). Una carpeta que no se ve pero tiene algo visible dentro
     * se incluye como "carpeta de paso" (permiso.ver = false, sólo para
     * llegar). Fechas formateadas como el árbol del administrador.
     */
    public function misArchivos(){
        try {
            $userId = (int) auth()->id();
            $visibles = collect(DB::select('SELECT archivo_id FROM seguridad.fn_archivos_visibles(?)', [$userId]))
                ->pluck('archivo_id')->map(fn ($v) => (int) $v)->all();
            if (!$visibles) {
                return $this->successResponse([], 'La solicitud ha tenido éxito');
            }

            // Ancestros de los visibles: carpetas de paso
            $todos = Archivo::get()->keyBy('id');
            $incluir = array_fill_keys($visibles, true);
            foreach ($visibles as $id) {
                $padre = $todos[$id]->padre ?? null;
                while ($padre && !isset($incluir[$padre]) && isset($todos[$padre])) {
                    $incluir[$padre] = false;   // de paso
                    $padre = $todos[$padre]->padre;
                }
            }

            $funciones = new Funciones();
            $nodos = [];
            foreach ($incluir as $id => $veDirecto) {
                $a = $todos[$id];
                $funciones->formatoFechaItem($a, ['created_at', 'updated_at']);
                $n = $a->toArray();
                $n['permiso'] = $veDirecto
                    ? (array) $this->permisoEfectivo($userId, (int) $id)
                    : ['ver' => false, 'ejecutar' => false, 'descargar' => false, 'crear' => false,
                       'editar' => false, 'eliminar' => false, 'administrar' => false, 'restaurar' => false, 'origen' => 'PASO'];
                $n['children'] = [];
                $nodos[$id] = $n;
            }

            // Armar el árbol (hijos ordenados: carpetas primero, luego orden y nombre)
            $raices = [];
            foreach ($nodos as $id => &$n) {
                $padre = $n['padre'];
                if ($padre && isset($nodos[$padre])) { $nodos[$padre]['children'][] = &$n; }
                else { $raices[] = &$n; }
            }
            unset($n);
            $ordenar = function (array &$lista) use (&$ordenar) {
                usort($lista, fn ($x, $y) => [$y['escarpeta'], $x['orden'], $x['nombre']] <=> [$x['escarpeta'], $y['orden'], $y['nombre']]);
                foreach ($lista as &$h) {
                    if ($h['children']) { $ordenar($h['children']); } else { unset($h['children']); }
                }
            };
            $ordenar($raices);

            return $this->successResponse($raices, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Banderas efectivas del usuario autenticado sobre un nodo. */
    public function miPermiso($id){
        try {
            return $this->successResponse($this->permisoEfectivo((int) auth()->id(), (int) $id), 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Abrir un archivo desde "Mis archivos": comprueba `ejecutar`, deja
     * rastro (EJECUTAR) y devuelve el registro con sus banderas (el visor
     * oculta Descargar / Abrir en pestaña si no tiene `descargar`).
     */
    public function abrir(Request $request, $id){
        try {
            $archivo = Archivo::findOrFail($id);
            if ($archivo->escarpeta) {
                return $this->errorResponse('Las carpetas no se abren', 422);
            }
            $p = $this->permisoEfectivo((int) auth()->id(), (int) $archivo->id);
            if (!$p->ejecutar) {
                return $this->errorResponse('No tiene permiso para abrir este archivo', 403);
            }
            $this->registrarAcceso($request, (int) $archivo->id, 'EJECUTAR');
            $funciones = new Funciones();
            $funciones->formatoFechaItem($archivo, ['created_at', 'updated_at']);
            $datos = $archivo->toArray();
            $datos['permiso'] = (array) $p;
            return $this->successResponse($datos, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
