<?php

namespace App\Http\Controllers\auth;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * Grupos de usuarios (seguridad.grupos): árbol al estilo de las unidades
 * organizativas de Active Directory. Cada usuario pertenece a un grupo y el
 * grupo lleva los valores por defecto (perfil, horario, administrador, tipo
 * de acceso) que heredan sus usuarios.
 *
 * Mismo esquema que UserController: la lógica vive en seguridad.fn_grupos_*;
 * aquí sólo se valida la entrada, se llama con el contexto del usuario
 * autenticado y se traduce la respuesta.
 *
 *   GET    auth/grupo/allGrupos[?activos=1]     árbol completo (plano, con nivel y ruta)
 *   GET    auth/grupo/findByIdGrupo/{id}
 *   POST   auth/grupo/addGrupo
 *   POST   auth/grupo/editGrupo/{id}
 *   DELETE auth/grupo/deleteGrupo/{id}
 *   POST   auth/grupo/moverGrupo/{id}           { padre_id, antes_de } (arrastrar y soltar)
 */
class GrupoController extends Controller
{
    use ApiResponder;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // nombre obligatorio
        'P0006' => 409,   // nombre duplicado entre hermanos
        'P0008' => 422,   // perfil inexistente
        'P0009' => 422,   // horario inexistente
        'P0010' => 422,   // tipo de acceso inválido
        'P0013' => 404,   // el grupo no existe
        'P0014' => 409,   // tiene usuarios o subgrupos
        'P0016' => 422,   // el padre / destino no existe
        'P0017' => 422,   // ciclo
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

    private function reglas(): array
    {
        return [
            'nombre'           => 'required|string|min:2|max:100',
            'padre_id'         => 'nullable|integer',
            'descripcion'      => 'nullable|string|max:1000',
            'perfil_id'        => 'nullable|integer',
            'chorario_id'      => 'nullable|integer',
            'es_administrador' => 'nullable|boolean',
            'tipo_acceso'      => 'nullable|string|in:SISTEMA,WEB',
            'activo'           => 'nullable|boolean',
            'aplicar_usuarios' => 'nullable|boolean',   // sólo al modificar: pone perfil/horario/tipo del grupo a sus usuarios
        ];
    }

    private function mensajes(): array
    {
        return [
            'nombre.required'  => 'El nombre del grupo es obligatorio',
            'nombre.min'       => 'El nombre del grupo debe tener al menos 2 caracteres',
            'nombre.max'       => 'El nombre del grupo no puede superar los 100 caracteres',
            'descripcion.max'  => 'La descripción no puede superar los 1000 caracteres',
            'tipo_acceso.in'   => 'El tipo de acceso debe ser SISTEMA o WEB',
        ];
    }

    /** Cuerpo de la petición: JSON plano o el envoltorio { json: "…" } de los FormData. */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    /** Los 8 parámetros de negocio de crear/modificar, en el orden de la función. */
    private function parametros(array $d): array
    {
        return [
            $d['nombre'],
            isset($d['padre_id']) && $d['padre_id'] !== '' ? (int) $d['padre_id'] : null,
            $d['descripcion'] ?? null,
            isset($d['perfil_id']) && $d['perfil_id'] !== '' ? (int) $d['perfil_id'] : null,
            isset($d['chorario_id']) && $d['chorario_id'] !== '' ? (int) $d['chorario_id'] : null,
            array_key_exists('es_administrador', $d) ? ((bool) $d['es_administrador'] ? 'true' : 'false') : 'false',
            $d['tipo_acceso'] ?? 'SISTEMA',
            array_key_exists('activo', $d) ? ((bool) $d['activo'] ? 'true' : 'false') : 'true',
        ];
    }

    private function auditoria(Request $request): array
    {
        [$usuarioId, $usuarioLogin, $usuarioNombre] = $this->contextoUsuario();
        return [
            $usuarioId ? (int) $usuarioId : null,
            $usuarioLogin,
            $usuarioNombre,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid(),
        ];
    }

    private const CASTS_DATOS = '?::VARCHAR, ?::BIGINT, ?::TEXT, ?::BIGINT, ?::BIGINT, ?::BOOLEAN, ?::VARCHAR, ?::BOOLEAN';
    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    // ================================================================
    // LISTAR / OBTENER
    // ================================================================

    public function allGrupos(Request $request)
    {
        try {
            $soloActivos = filter_var($request->input('activos', false), FILTER_VALIDATE_BOOLEAN);
            $result = DB::selectOne('SELECT seguridad.fn_grupos_listar(?::BOOLEAN) as result', [$soloActivos ? 'true' : 'false']);
            $resultado = json_decode($result->result, true);
            return $this->successResponse([
                'grupos'         => $resultado['data'] ?? [],
                'sin_grupo'      => $resultado['sin_grupo'] ?? 0,
                'total_usuarios' => $resultado['total_usuarios'] ?? 0,
                'en_papelera'    => $resultado['en_papelera'] ?? 0,
            ], 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allGrupos', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar los grupos', 500);
        }
    }

    public function findByIdGrupo($id)
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_grupos_obtener(?::BIGINT) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);
            if (!($resultado['success'] ?? false)) {
                return $this->errorResponse($resultado['message'] ?? 'Grupo no encontrado', 404);
            }
            return $this->successResponse($resultado['data'], $resultado['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdGrupo', ['message' => $e->getMessage(), 'grupo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al obtener el grupo', 500);
        }
    }

    // ================================================================
    // CREAR / MODIFICAR / ELIMINAR
    // ================================================================

    public function addGrupo(Request $request)
    {
        [, $usuarioLogin] = $this->contextoUsuario();
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT seguridad.fn_grupos_crear(' . self::CASTS_DATOS . ', ' . self::CASTS_AUDIT . ') as result',
                array_merge($this->parametros($d), $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Grupo creado', ['grupo_id' => $resultado['data']['id'] ?? null, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addGrupo rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addGrupo', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear el grupo', 500);
        }
    }

    public function editGrupo(Request $request, $id)
    {
        [, $usuarioLogin] = $this->contextoUsuario();
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $aplicar = array_key_exists('aplicar_usuarios', $d) && (bool) $d['aplicar_usuarios'];
            $result = DB::selectOne(
                'SELECT seguridad.fn_grupos_modificar(?::BIGINT, ' . self::CASTS_DATOS . ', ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->parametros($d), [$aplicar ? 'true' : 'false'], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Grupo actualizado', ['grupo_id' => $id, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editGrupo rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'grupo_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editGrupo', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'grupo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar el grupo', 500);
        }
    }

    public function deleteGrupo(Request $request, $id)
    {
        [, $usuarioLogin] = $this->contextoUsuario();
        try {
            $result = DB::selectOne(
                'SELECT seguridad.fn_grupos_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Grupo eliminado', ['grupo_id' => $id, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteGrupo rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'grupo_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteGrupo', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'grupo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar el grupo', 500);
        }
    }

    /**
     * Arrastrar y soltar en el árbol: { padre_id: n|null, antes_de: n|null }.
     */
    public function moverGrupo(Request $request, $id)
    {
        [, $usuarioLogin] = $this->contextoUsuario();
        try {
            $validator = Validator::make($request->all(), [
                'padre_id' => 'nullable|integer',
                'antes_de' => 'nullable|integer',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT seguridad.fn_grupos_mover(?::BIGINT, ?::BIGINT, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $d['padre_id'] ?? null, $d['antes_de'] ?? null], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Grupo movido', ['grupo_id' => $id, 'padre_id' => $d['padre_id'] ?? null, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'moverGrupo rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'grupo_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en moverGrupo', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'grupo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al mover el grupo', 500);
        }
    }
}
