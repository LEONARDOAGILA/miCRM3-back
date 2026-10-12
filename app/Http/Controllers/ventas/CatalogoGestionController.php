<?php

namespace App\Http\Controllers\ventas;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Illuminate\Support\Facades\Validator;

/**
 * El catálogo de tipos y asuntos de gestión.
 *
 * El asunto de una gestión se elige de aquí, no se escribe: era la única forma
 * de que un informe por asunto no saliera partido entre «Cobranza» y
 * «cobranzas». Esta pantalla es la que mantiene esa lista.
 *
 * Mismo esquema que GestionController: toda la lógica vive en funciones
 * PL/pgSQL y aquí sólo se valida la entrada y se traduce el error.
 */
class CatalogoGestionController extends Controller
{
    use ApiResponder;

    /** SQLSTATE de las funciones → código HTTP. Los mismos que usa gestión. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,  // falta un dato obligatorio
        'P0013' => 404,  // no existe
        'P0020' => 409,  // repetido
        'P0021' => 409,  // no se puede: el asunto ya está en uso
        'P0022' => 422,  // incoherente
    ];

    public function __construct() {
        $this->middleware('auth:api');
    }

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

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

    private function auditoria(Request $request): array
    {
        $u = auth('api')->user();
        return [
            isset($u->id) ? (int) $u->id : null,
            $u->login_user ?? null,
            trim(($u->name ?? '') . ' ' . ($u->surname ?? '')) ?: null,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid(),
        ];
    }

    /** Cuerpo de la petición: JSON plano o el envoltorio { json: "…" } (FormData). */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    // ================================================================
    // LO QUE LEE EL FORMULARIO DE GESTIÓN
    // ================================================================

    /**
     * Los tipos activos con sus asuntos activos, en una sola petición.
     *
     * Va en una porque el formulario de gestión lo pide al abrirse y dos
     * viajes se notan: el combo de asuntos tiene que estar lleno antes de que
     * el usuario elija el tipo.
     */
    public function catalogo()
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_gestiones_catalogo() as result');
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en catálogo de gestiones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener el catálogo', 500);
        }
    }

    // ================================================================
    // TIPOS
    // ================================================================

    public function allTipos(Request $request)
    {
        try {
            $incluirInactivos = filter_var($request->query('inactivos', true), FILTER_VALIDATE_BOOLEAN);
            $result = DB::selectOne('SELECT ventas.fn_gestiones_tipos_listar(?::BOOLEAN) as result', [$incluirInactivos]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allTipos', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener los tipos', 500);
        }
    }

    public function saveTipo(Request $request, $id = null)
    {
        try {
            $validator = Validator::make($this->datosDe($request), [
                'codigo' => 'required|string|min:3|max:20',
                'nombre' => 'required|string|min:3|max:60',
                'icono'  => 'nullable|string|max:40',
                'orden'  => 'nullable|integer|min:0|max:9999',
                'activo' => 'nullable|boolean',
            ], [
                'codigo.required' => 'El código es obligatorio',
                'codigo.min'      => 'El código debe tener al menos 3 caracteres',
                'nombre.required' => 'El nombre es obligatorio',
                'nombre.min'      => 'El nombre debe tener al menos 3 caracteres',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_tipos_guardar(?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::INTEGER, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id ? (int) $id : null,
                    $d['codigo'],
                    $d['nombre'],
                    $d['icono'] ?? null,
                    isset($d['orden']) ? (int) $d['orden'] : 100,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Tipo de gestión guardado', ['tipo_id' => $r['data']['id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'saveTipo rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en saveTipo', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar el tipo', 500);
        }
    }

    public function deleteTipo(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_tipos_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Tipo de gestión eliminado', ['tipo_id' => $id, 'desactivado' => $r['data']['desactivado'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteTipo rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteTipo', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al eliminar el tipo', 500);
        }
    }

    // ================================================================
    // ASUNTOS
    // ================================================================

    public function allAsuntos(Request $request)
    {
        try {
            $tipoId = $request->query('tipo_id');
            $incluirInactivos = filter_var($request->query('inactivos', true), FILTER_VALIDATE_BOOLEAN);
            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_asuntos_listar(?::BIGINT, ?::BOOLEAN) as result',
                [$tipoId !== null && $tipoId !== '' ? (int) $tipoId : null, $incluirInactivos]
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allAsuntos', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener los asuntos', 500);
        }
    }

    public function saveAsunto(Request $request, $id = null)
    {
        try {
            $validator = Validator::make($this->datosDe($request), [
                'tipo_id' => 'required|integer',
                'nombre'  => 'required|string|min:3|max:200',
                'orden'   => 'nullable|integer|min:0|max:9999',
                'activo'  => 'nullable|boolean',
                // Lo que se le manda al cliente con este asunto: texto suelto
                // en WhatsApp, HTML en un correo. Sin tope de largo porque un
                // correo con formato no lo tiene.
                'mensaje' => 'nullable|string|max:100000',
            ], [
                'tipo_id.required' => 'Debe indicar a qué tipo pertenece el asunto',
                'nombre.required'  => 'El asunto es obligatorio',
                'nombre.min'       => 'El asunto debe tener al menos 3 caracteres',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_asuntos_guardar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::INTEGER, ?::BOOLEAN, ?::TEXT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id ? (int) $id : null,
                    (int) $d['tipo_id'],
                    $d['nombre'],
                    isset($d['orden']) ? (int) $d['orden'] : 100,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                    // Si no viene, el mensaje se queda como estaba: la pantalla
                    // que sólo renombra no tiene por qué reenviarlo entero.
                    array_key_exists('mensaje', $d) ? (string) $d['mensaje'] : null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Asunto de gestión guardado', ['asunto_id' => $r['data']['id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'saveAsunto rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en saveAsunto', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar el asunto', 500);
        }
    }

    public function deleteAsunto(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_asuntos_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Asunto de gestión eliminado', ['asunto_id' => $id, 'desactivado' => $r['data']['desactivado'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteAsunto rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteAsunto', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al eliminar el asunto', 500);
        }
    }
}
