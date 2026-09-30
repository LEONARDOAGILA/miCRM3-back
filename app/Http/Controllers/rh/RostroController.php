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
 * Plantillas faciales de los empleados (rh.rostros_empleados).
 *
 * Cada muestra es un descriptor de 128 números que calcula el navegador con
 * face-api.js; aquí sólo se guardan y se devuelven para que el kiosco compare
 * sin volver a procesar las fotos. La lógica vive en rh.fn_rostros_*.
 *
 *   GET    rh/rostro/allRostros[?empleado_id]   empleados con sus muestras (kiosco)
 *   POST   rh/rostro/addRostro                  { empleado_id, descriptores: [[128], …], origen }
 *   DELETE rh/rostro/deleteRostro/{id}          una muestra
 *   DELETE rh/rostro/deleteRostrosEmpleado/{empleadoId}   todas las del empleado
 */
class RostroController extends Controller
{
    use ApiResponder;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // faltan datos
        'P0010' => 422,   // valor no admitido
        'P0013' => 404,   // no existe
        'P0022' => 422,   // descriptor inválido
    ];

    public function __construct() {
        $this->middleware('auth:api');
    }

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
            $u->id ?? null,
            $u->login_user ?? null,
            trim(($u->name ?? '') . ' ' . ($u->surname ?? '')) ?: null,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid(),
        ];
    }

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    public function allRostros(Request $request)
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_rostros_listar(?::BIGINT) as result', [
                $request->filled('empleado_id') ? (int) $request->input('empleado_id') : null,
            ]);
            $resultado = json_decode($result->result, true);
            return $this->successResponse($resultado['data'] ?? [], 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allRostros', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar los rostros', 500);
        }
    }

    public function addRostro(Request $request)
    {
        $validator = Validator::make($request->all(), [
            'empleado_id'     => 'required|integer',
            'descriptores'    => 'required|array|min:1|max:20',
            'descriptores.*'  => 'array|size:128',
            'origen'          => 'nullable|string|in:CAMARA,FOTO',
        ], [
            'empleado_id.required'  => 'Falta el empleado',
            'descriptores.required' => 'No se recibió ninguna muestra facial',
            'descriptores.*.size'   => 'Cada muestra facial debe tener 128 números',
        ]);
        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }
        $d = $validator->validated();

        try {
            $result = DB::selectOne(
                'SELECT rh.fn_rostros_guardar(?::BIGINT, ?::JSONB, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $d['empleado_id'],
                    json_encode($d['descriptores']),
                    strtoupper($d['origen'] ?? 'CAMARA'),
                ], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Muestras faciales guardadas', ['empleado_id' => $d['empleado_id'], 'muestras' => count($d['descriptores'])]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addRostro', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar el rostro', 500);
        }
    }

    public function deleteRostro(Request $request, $id)
    {
        return $this->eliminar($request, (int) $id, null);
    }

    public function deleteRostrosEmpleado(Request $request, $empleadoId)
    {
        return $this->eliminar($request, null, (int) $empleadoId);
    }

    private function eliminar(Request $request, ?int $id, ?int $empleadoId)
    {
        try {
            $result = DB::selectOne(
                'SELECT rh.fn_rostros_eliminar(?::BIGINT, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$id, $empleadoId], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Muestras faciales eliminadas', ['rostro_id' => $id, 'empleado_id' => $empleadoId]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al eliminar rostros', ['message' => $e->getMessage(), 'rostro_id' => $id, 'empleado_id' => $empleadoId]);
            return $this->errorResponse('Ocurrió un error al eliminar el rostro', 500);
        }
    }
}
