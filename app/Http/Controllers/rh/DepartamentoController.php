<?php

namespace App\Http\Controllers\rh;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * CRUD de departamentos (rh.departamentos).
 *
 * Mismo esquema que rh\CargoController: toda la lógica vive en las funciones
 * PL/pgSQL rh.fn_departamentos_* (validaciones, auditoría, transacción); aquí
 * sólo se valida la entrada, se llama a la función con el contexto del
 * usuario autenticado y se traduce la respuesta.
 *
 *   GET    rh/departamento/allDepartamentos?page&per_page&search   listado paginado (grilla)
 *   GET    rh/departamento/listDepartamentos[?activos=0]           lista simple (combos / selector)
 *   GET    rh/departamento/listResponsables                        empleados activos (combo Responsable)
 *   GET    rh/departamento/findByIdDepartamento/{id}
 *   POST   rh/departamento/addDepartamento
 *   POST   rh/departamento/editDepartamento/{id}
 *   DELETE rh/departamento/deleteDepartamento/{id}
 */
class DepartamentoController extends Controller
{
    use ApiResponder;

    /**
     * SQLSTATE que las funciones de rh usan para las reglas de negocio.
     * Son errores del usuario, no fallos del servidor: se responden como 4xx.
     */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // nombre obligatorio
        'P0006' => 409,   // nombre duplicado
        'P0013' => 404,   // el departamento no existe
        'P0014' => 409,   // no se puede eliminar: tiene empleados / historial
        'P0016' => 409,   // código duplicado
        'P0017' => 422,   // responsable inexistente o inactivo
    ];

    public function __construct() {
        $this->middleware('auth:api');
    }

    /** Convierte el error de una función PL/pgSQL en [mensaje, código HTTP]. */
    private function traducirErrorPostgres(QueryException $e): array
    {
        $sqlState = $e->errorInfo[0] ?? null;
        if (!isset(self::ERRORES_NEGOCIO[$sqlState])) {
            return ['Ocurrió un error al procesar la solicitud', 500];
        }
        $mensaje = $e->errorInfo[2] ?? $e->getMessage();
        $mensaje = preg_replace('/^.*?ERROR:\s*/s', '', $mensaje);
        $mensaje = preg_split('/\R\s*(CONTEXT|CONTEXTO|DETALLE|DETAIL|HINT):/', $mensaje)[0];
        return [trim($mensaje), self::ERRORES_NEGOCIO[$sqlState]];
    }

    /** Usuario autenticado en la forma que esperan las funciones (id, login, nombre). */
    private function contextoUsuario(): array
    {
        $u = auth('api')->user();
        return [
            $u->id ?? null,
            $u->login_user ?? null,
            trim(($u->name ?? '') . ' ' . ($u->surname ?? '')) ?: null,
        ];
    }

    /** Reglas de validación comunes a crear y modificar. */
    private function reglas(): array
    {
        return [
            'nombre'      => 'required|string|min:3|max:100',
            'codigo'      => 'nullable|string|max:20',
            'descripcion' => 'nullable|string|max:1000',
            'empleado_id' => 'nullable|integer',
            'activo'      => 'nullable|boolean',
        ];
    }

    /** Mensajes en español (el locale de la app es 'en'). */
    private function mensajes(): array
    {
        return [
            'nombre.required'     => 'El nombre del departamento es obligatorio',
            'nombre.min'          => 'El nombre del departamento debe tener al menos 3 caracteres',
            'nombre.max'          => 'El nombre del departamento no puede superar los 100 caracteres',
            'codigo.max'          => 'El código no puede superar los 20 caracteres',
            'descripcion.max'     => 'La descripción no puede superar los 1000 caracteres',
            'empleado_id.integer' => 'El responsable no es válido',
            'activo.boolean'      => 'El estado debe ser activo o inactivo',
        ];
    }

    /**
     * Cuerpo de la petición: JSON plano, o el envoltorio { json: "…" } que
     * usan los formularios que mandan FormData (editUser). Se admiten los dos.
     */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    // ================================================================
    // LISTAR
    // ================================================================

    public function allDepartamentos(Request $request)
    {
        try {
            $page    = (int) $request->input('page', 1);
            $perPage = (int) $request->input('per_page', 15);
            $search  = (string) $request->input('search', '');

            $result = DB::selectOne('SELECT rh.fn_departamentos_listar_paginado(?, ?, ?) as result', [$page, $perPage, $search]);
            $resultado = json_decode($result->result, true);

            if (isset($resultado['success']) && $resultado['success'] === false) {
                return $this->errorResponse($resultado['message'], 500);
            }
            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allDepartamentos', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function listDepartamentos(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $result = DB::selectOne('SELECT rh.fn_departamentos_listar(?::BOOLEAN) as result', [$soloActivos]);
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en listDepartamentos', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Empleados activos (id, nombre, cargo) para el combo "Responsable" del formulario. */
    public function listResponsables()
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_departamentos_responsables() as result');
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en listResponsables', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdDepartamento($id)
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_departamentos_obtener(?::BIGINT) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);
            if (!$resultado['success']) {
                return $this->errorResponse($resultado['message'], $resultado['data'] === null ? 404 : 400);
            }
            return $this->successResponse($resultado['data'], $resultado['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdDepartamento', ['message' => $e->getMessage(), 'departamento_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // CREAR / MODIFICAR / ELIMINAR
    // ================================================================

    public function addDepartamento(Request $request)
    {
        [$usuarioId, $usuarioLogin, $usuarioNombre] = $this->contextoUsuario();
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne('
                SELECT rh.fn_departamentos_crear(
                    ?::VARCHAR,   -- p_nombre
                    ?::VARCHAR,   -- p_codigo
                    ?::TEXT,      -- p_descripcion
                    ?::BIGINT,    -- p_empleado_id
                    ?::BOOLEAN,   -- p_activo
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                $d['nombre'],
                $d['codigo'] ?? null,
                $d['descripcion'] ?? null,
                !empty($d['empleado_id']) ? (int) $d['empleado_id'] : null,
                array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                $usuarioId ? (int) $usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid(),
            ]);

            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Departamento creado', ['departamento_id' => $resultado['data']['id'] ?? null, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addDepartamento rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addDepartamento', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear el departamento', 500);
        }
    }

    public function editDepartamento(Request $request, $id)
    {
        [$usuarioId, $usuarioLogin, $usuarioNombre] = $this->contextoUsuario();
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne('
                SELECT rh.fn_departamentos_modificar(
                    ?::BIGINT,    -- p_id
                    ?::VARCHAR,   -- p_nombre
                    ?::VARCHAR,   -- p_codigo
                    ?::TEXT,      -- p_descripcion
                    ?::BIGINT,    -- p_empleado_id
                    ?::BOOLEAN,   -- p_activo
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                (int) $id,
                $d['nombre'],
                $d['codigo'] ?? null,
                $d['descripcion'] ?? null,
                !empty($d['empleado_id']) ? (int) $d['empleado_id'] : null,
                array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                $usuarioId ? (int) $usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid(),
            ]);

            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Departamento actualizado', ['departamento_id' => $id, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editDepartamento rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'departamento_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editDepartamento', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'departamento_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar el departamento', 500);
        }
    }

    public function deleteDepartamento(Request $request, $id)
    {
        [$usuarioId, $usuarioLogin, $usuarioNombre] = $this->contextoUsuario();
        try {
            $result = DB::selectOne('
                SELECT rh.fn_departamentos_eliminar(
                    ?::BIGINT,    -- p_id
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                (int) $id,
                $usuarioId ? (int) $usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid(),
            ]);

            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Departamento eliminado', ['departamento_id' => $id, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteDepartamento rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'departamento_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteDepartamento', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'departamento_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar el departamento', 500);
        }
    }
}
