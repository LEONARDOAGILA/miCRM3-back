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
 * CRUD de cargos (rh.cargos).
 *
 * Mismo esquema que auth\UserController: toda la lógica vive en las funciones
 * PL/pgSQL rh.fn_cargos_* (validaciones, auditoría, transacción); aquí sólo se
 * valida la entrada, se llama a la función con el contexto del usuario
 * autenticado y se traduce la respuesta.
 *
 *   GET    rh/cargo/allCargos?page&per_page&search   listado paginado (grilla)
 *   GET    rh/cargo/listCargos[?activos=0]           lista simple (combos / selector)
 *   GET    rh/cargo/findByIdCargo/{id}
 *   POST   rh/cargo/addCargo
 *   POST   rh/cargo/editCargo/{id}
 *   DELETE rh/cargo/deleteCargo/{id}
 */
class CargoController extends Controller
{
    use ApiResponder;

    /**
     * SQLSTATE que las funciones de rh usan para las reglas de negocio.
     * Son errores del usuario, no fallos del servidor: se responden como 4xx.
     */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // nombre obligatorio
        'P0006' => 409,   // nombre duplicado
        'P0013' => 404,   // el cargo no existe
        'P0014' => 409,   // no se puede eliminar: tiene empleados / historial
        'P0015' => 422,   // salario inválido
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
            'nombre'       => 'required|string|min:3|max:100',
            'descripcion'  => 'nullable|string|max:1000',
            'nivel'        => 'nullable|string|max:50',
            'salario_base' => 'nullable|numeric|min:0|max:999999999',
            'activo'       => 'nullable|boolean',
        ];
    }

    /** Mensajes en español (el locale de la app es 'en'). */
    private function mensajes(): array
    {
        return [
            'nombre.required'     => 'El nombre del cargo es obligatorio',
            'nombre.min'          => 'El nombre del cargo debe tener al menos 3 caracteres',
            'nombre.max'          => 'El nombre del cargo no puede superar los 100 caracteres',
            'descripcion.max'     => 'La descripción no puede superar los 1000 caracteres',
            'nivel.max'           => 'El nivel no puede superar los 50 caracteres',
            'salario_base.numeric'=> 'El salario base debe ser un número',
            'salario_base.min'    => 'El salario base no puede ser negativo',
            'salario_base.max'    => 'El salario base es demasiado grande',
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

    public function allCargos(Request $request)
    {
        try {
            $page    = (int) $request->input('page', 1);
            $perPage = (int) $request->input('per_page', 15);
            $search  = (string) $request->input('search', '');

            $result = DB::selectOne('SELECT rh.fn_cargos_listar_paginado(?, ?, ?) as result', [$page, $perPage, $search]);
            $resultado = json_decode($result->result, true);

            if (isset($resultado['success']) && $resultado['success'] === false) {
                return $this->errorResponse($resultado['message'], 500);
            }
            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allCargos', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function listCargos(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $result = DB::selectOne('SELECT rh.fn_cargos_listar(?::BOOLEAN) as result', [$soloActivos]);
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en listCargos', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdCargo($id)
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_cargos_obtener(?::BIGINT) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);
            if (!$resultado['success']) {
                return $this->errorResponse($resultado['message'], $resultado['data'] === null ? 404 : 400);
            }
            return $this->successResponse($resultado['data'], $resultado['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdCargo', ['message' => $e->getMessage(), 'cargo_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // CREAR / MODIFICAR / ELIMINAR
    // ================================================================

    public function addCargo(Request $request)
    {
        [$usuarioId, $usuarioLogin, $usuarioNombre] = $this->contextoUsuario();
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne('
                SELECT rh.fn_cargos_crear(
                    ?::VARCHAR,   -- p_nombre
                    ?::TEXT,      -- p_descripcion
                    ?::VARCHAR,   -- p_nivel
                    ?::NUMERIC,   -- p_salario_base
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
                $d['descripcion'] ?? null,
                $d['nivel'] ?? null,
                isset($d['salario_base']) && $d['salario_base'] !== '' ? $d['salario_base'] : null,
                array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                $usuarioId ? (int) $usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid(),
            ]);

            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Cargo creado', ['cargo_id' => $resultado['data']['id'] ?? null, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addCargo rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addCargo', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear el cargo', 500);
        }
    }

    public function editCargo(Request $request, $id)
    {
        [$usuarioId, $usuarioLogin, $usuarioNombre] = $this->contextoUsuario();
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne('
                SELECT rh.fn_cargos_modificar(
                    ?::BIGINT,    -- p_id
                    ?::VARCHAR,   -- p_nombre
                    ?::TEXT,      -- p_descripcion
                    ?::VARCHAR,   -- p_nivel
                    ?::NUMERIC,   -- p_salario_base
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
                $d['descripcion'] ?? null,
                $d['nivel'] ?? null,
                isset($d['salario_base']) && $d['salario_base'] !== '' ? $d['salario_base'] : null,
                array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                $usuarioId ? (int) $usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid(),
            ]);

            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Cargo actualizado', ['cargo_id' => $id, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editCargo rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'cargo_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editCargo', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cargo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar el cargo', 500);
        }
    }

    public function deleteCargo(Request $request, $id)
    {
        [$usuarioId, $usuarioLogin, $usuarioNombre] = $this->contextoUsuario();
        try {
            $result = DB::selectOne('
                SELECT rh.fn_cargos_eliminar(
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
            sistemaLog('info', 'Cargo eliminado', ['cargo_id' => $id, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteCargo rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'cargo_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteCargo', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cargo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar el cargo', 500);
        }
    }
}
