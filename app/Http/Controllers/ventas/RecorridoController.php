<?php

namespace App\Http\Controllers\ventas;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;

/**
 * Recorridos del cobrador: por dónde anduvo y dónde se paró.
 *
 * El celular va mandando posiciones durante la jornada y esta pantalla las
 * reconstruye: el trazo, los kilómetros, dónde se detuvo y cuánto rato, y si
 * esas paradas coinciden con clientes de la cartera.
 *
 * Mismo esquema que el resto del módulo: la lógica vive en funciones PL/pgSQL
 * (ventas.fn_recorridos_*) y aquí sólo se valida la entrada y se traduce el
 * error.
 *
 * DOS PÚBLICOS DISTINTOS. 'registrar' lo llama el celular del propio cobrador
 * y las tres lecturas las llama el supervisor desde la pantalla. Por eso
 * 'registrar' NO acepta un usuario_id del cuerpo: escribe siempre sobre el
 * usuario del token. Si lo aceptara, cualquiera con una sesión válida podría
 * fabricarle un recorrido a otro, que es precisamente lo que esto viene a
 * evitar.
 *
 * Rutas (prefijo /ventas/recorrido):
 *   POST registrar                 { puntos: [...], dispositivo? }
 *   GET  cobradores?desde&hasta
 *   GET  dias/{usuarioId}?desde&hasta
 *   GET  delDia/{usuarioId}?fecha&radio_parada&minutos_parada&radio_cliente
 */
class RecorridoController extends Controller
{
    use ApiResponder;

    /** SQLSTATE de las funciones a código HTTP. Los mismos que usa el módulo. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,  // falta un dato obligatorio o está mal
        'P0013' => 404,  // el usuario no existe
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    /**
     * Tope de puntos por envío.
     *
     * Una jornada de ocho horas con una lectura cada treinta segundos son unos
     * mil puntos. Dos mil deja sitio de sobra para que el celular vacíe una
     * cola acumulada sin conexión, y pone un techo a lo que puede llegar de
     * una vez.
     */
    private const MAX_PUNTOS = 2000;

    public function __construct()
    {
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
            isset($u->id) ? (int) $u->id : null,
            $u->login_user ?? null,
            trim(($u->name ?? '') . ' ' . ($u->surname ?? '')) ?: null,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid(),
        ];
    }

    /** Cuerpo de la petición: JSON plano o el envoltorio { json: "..." } (FormData). */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    // ================================================================
    // ESCRIBIR: LO QUE MANDA EL CELULAR
    // ================================================================

    /**
     * Recibe un lote de posiciones del usuario del token.
     *
     * Reenviar el mismo lote no duplica nada: la base lo resuelve con una
     * restricción única por (usuario, instante). La respuesta dice cuántos
     * entraron, cuántos ya estaban y cuántos se descartaron, que es lo que el
     * celular necesita para saber si puede vaciar su cola.
     */
    public function registrar(Request $request)
    {
        try {
            $datos = $this->datosDe($request);

            $validator = Validator::make($datos, [
                'puntos'               => ['required', 'array', 'min:1', 'max:' . self::MAX_PUNTOS],
                'puntos.*.fecha_hora'  => ['required', 'date'],
                'puntos.*.lat'         => ['required', 'numeric', 'between:-90,90'],
                'puntos.*.lng'         => ['required', 'numeric', 'between:-180,180'],
                'puntos.*.precision_m' => ['nullable', 'numeric', 'min:0'],
                'puntos.*.altitud'     => ['nullable', 'numeric'],
                'puntos.*.velocidad'   => ['nullable', 'numeric'],
                'puntos.*.rumbo'       => ['nullable', 'numeric', 'between:0,360'],
                'puntos.*.bateria'     => ['nullable', 'integer', 'between:0,100'],
                'dispositivo'          => ['nullable', 'string', 'max:120'],
                // Por encima de este error el punto ni se guarda. Se deja
                // configurable porque dentro de un edificio el GPS da 200 m y
                // aun así el recorrido sirve.
                'precision_max'        => ['nullable', 'numeric', 'min:1', 'max:10000'],
            ], [
                'puntos.required' => 'No llegó ninguna posición',
                'puntos.max'      => 'Demasiadas posiciones en un envío (máximo ' . self::MAX_PUNTOS . ')',
            ]);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            // El usuario sale del token, nunca del cuerpo. Ver la cabecera.
            $usuarioId = (int) (auth('api')->user()->id ?? 0);
            if ($usuarioId <= 0) {
                return $this->errorResponse('No se pudo identificar al usuario', 401);
            }

            $result = DB::selectOne(
                'SELECT ventas.fn_recorridos_registrar('
                . '?::BIGINT, ?::JSONB, ?::VARCHAR, ?::NUMERIC, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $usuarioId,
                    json_encode($d['puntos']),
                    $d['dispositivo'] ?? null,
                    $d['precision_max'] ?? 1000,
                ], $this->auditoria($request))
            );

            $r = json_decode($result->result, true);

            return ($r['success'] ?? false)
                ? $this->successResponse($r['data'], $r['message'])
                : $this->errorResponse($r['message'], 500);
        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en registrar recorrido', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar el recorrido', 500);
        }
    }

    // ================================================================
    // LEER: LO QUE MIRA EL SUPERVISOR
    // ================================================================

    /** Quiénes dejaron rastro en el rango, con cuántos días y puntos cada uno. */
    public function cobradores(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_recorridos_cobradores(?::DATE, ?::DATE) as result',
                [$request->query('desde'), $request->query('hasta')]
            );
            $r = json_decode($result->result, true);

            return ($r['success'] ?? false)
                ? $this->successResponse($r['data'], $r['message'])
                : $this->errorResponse($r['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en cobradores con recorrido', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener los cobradores', 500);
        }
    }

    /** Qué días tiene recorrido un usuario, con los kilómetros de cada uno. */
    public function dias(Request $request, $usuarioId)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_recorridos_dias(?::BIGINT, ?::DATE, ?::DATE) as result',
                [(int) $usuarioId, $request->query('desde'), $request->query('hasta')]
            );
            $r = json_decode($result->result, true);

            return ($r['success'] ?? false)
                ? $this->successResponse($r['data'], $r['message'])
                : $this->errorResponse($r['message'], 500);
        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en dias con recorrido', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener los días', 500);
        }
    }

    /**
     * El recorrido de un día: puntos, resumen y paradas.
     *
     * Los criterios de parada viajan como parámetros y no están fijos en la
     * base: «parado» con 60 m y 5 min es una visita, con 200 m y 20 min es un
     * almuerzo, y quien mira necesita poder cambiar de pregunta sin que nadie
     * recalcule nada.
     */
    public function delDia(Request $request, $usuarioId)
    {
        try {
            $validator = Validator::make($request->query(), [
                'fecha'          => ['nullable', 'date_format:Y-m-d'],
                'radio_parada'   => ['nullable', 'numeric', 'min:5', 'max:2000'],
                'minutos_parada' => ['nullable', 'integer', 'min:1', 'max:600'],
                'radio_cliente'  => ['nullable', 'numeric', 'min:5', 'max:2000'],
            ], [
                'fecha.date_format' => 'La fecha debe venir como AAAA-MM-DD',
            ]);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ventas.fn_recorridos_del_dia(?::BIGINT, ?::DATE, ?::NUMERIC, ?::INTEGER, ?::NUMERIC) as result',
                [
                    (int) $usuarioId,
                    $request->query('fecha'),
                    $request->query('radio_parada', 60),
                    $request->query('minutos_parada', 5),
                    $request->query('radio_cliente', 80),
                ]
            );
            $r = json_decode($result->result, true);

            return ($r['success'] ?? false)
                ? $this->successResponse($r['data'], $r['message'])
                : $this->errorResponse($r['message'], 500);
        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en recorrido del dia', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener el recorrido', 500);
        }
    }
}
