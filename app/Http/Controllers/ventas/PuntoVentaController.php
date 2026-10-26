<?php

namespace App\Http\Controllers\ventas;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * CRUD de puntos de venta (core.puntos_venta).
 *
 * Un punto de venta es UNA CAJA. Una sucursal tiene varias —la 1, la 2…— y
 * lo que de verdad las distingue es que cada una cuadra su propio dinero: de
 * ahí que lo importante de esta ficha no sea el nombre sino SUS CUENTAS
 * CONTABLES, que se configuran con el mecanismo de siempre
 * (contabilidad.cuentas_config, ámbito PUNTO_VENTA) y siguen la cadena
 * punto de venta → su sucursal → lo que valga para todos.
 *
 * Las cuentas NO se guardan por aquí: para eso está CuentaConfigController,
 * que es el mismo para categorías, grupos de clientes y cajas. La pantalla
 * guarda primero la caja —que es la que da el id— y después sus cuentas.
 *
 *   GET    ventas/puntoVenta/allPuntosVenta      ?activos=0&sucursal_id=
 *   GET    ventas/puntoVenta/listPuntosVenta     ?activos=1  (para los combos)
 *   GET    ventas/puntoVenta/findByIdPuntoVenta/{id}
 *   GET    ventas/puntoVenta/sugerencia          ?sucursal_id=  código y número libres
 *   POST   ventas/puntoVenta/addPuntoVenta
 *   POST   ventas/puntoVenta/editPuntoVenta/{id}
 *   POST   ventas/puntoVenta/activarPuntoVenta/{id}   { activo? }; sin ella, alterna
 *   DELETE ventas/puntoVenta/deletePuntoVenta/{id}
 *   GET    ventas/puntoVenta/papelera
 *   POST   ventas/puntoVenta/restaurarPuntosVenta     { ids:[..] }
 *   POST   ventas/puntoVenta/eliminarDefinitivo       { ids:[..] }  (permiso «vaciar»)
 *   POST   ventas/puntoVenta/vaciarPapelera           (permiso «vaciar»)
 */
class PuntoVentaController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato o un número fuera de rango
        'P0006' => 409,   // código o número repetido
        'P0016' => 404,   // la caja o la sucursal no existen
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    public function __construct()
    {
        $this->middleware('auth:api');
    }

    // ================================================================
    // AYUDANTES
    // ================================================================

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

    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    private function reglas(): array
    {
        return [
            'sucursal_id' => 'required|integer|min:1',
            'nombre'      => 'required|string|min:2|max:100',
            // El código y el número son opcionales: si no vienen, la base
            // propone los siguientes libres de esa sucursal
            'codigo'      => 'nullable|string|max:20',
            'numero'      => 'nullable|integer|min:1|max:999',
            'descripcion' => 'nullable|string|max:2000',
            'activo'      => 'nullable|boolean',
        ];
    }

    private function mensajes(): array
    {
        return [
            'sucursal_id.required' => 'Hay que decir de qué sucursal es el punto de venta',
            'nombre.required'      => 'El nombre del punto de venta es obligatorio',
            'nombre.min'           => 'El nombre debe tener al menos 2 caracteres',
            'nombre.max'           => 'El nombre no puede superar los 100 caracteres',
            'codigo.max'           => 'El código no puede superar los 20 caracteres',
            'numero.min'           => 'El número del punto de venta va del 1 al 999',
            'numero.max'           => 'El número del punto de venta va del 1 al 999',
        ];
    }

    // ================================================================
    // LISTAR
    // ================================================================

    /**
     * Todas las cajas, agrupadas por sucursal.
     *
     * Sin paginar a propósito: una empresa tiene decenas, no miles, y se
     * miran por tienda. Cada una trae CUÁNTAS CUENTAS LE FALTAN, que es lo
     * que hay que ver de un vistazo: una caja sin cuenta de efectivo no
     * puede asentar nada.
     */
    public function allPuntosVenta(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '0') === '1';
            $sucursal    = $request->filled('sucursal_id') ? (int) $request->input('sucursal_id') : null;

            $result = DB::selectOne(
                'SELECT core.fn_puntos_venta_listar(?::BOOLEAN, ?::BIGINT) as result',
                [$soloActivos, $sucursal]
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar los puntos de venta', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allPuntosVenta', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Lo mismo, para los combos de otras pantallas. */
    public function listPuntosVenta(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $sucursal    = $request->filled('sucursal_id') ? (int) $request->input('sucursal_id') : null;

            $result = DB::selectOne(
                'SELECT core.fn_puntos_venta_listar(?::BOOLEAN, ?::BIGINT) as result',
                [$soloActivos, $sucursal]
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'] ?? [], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listPuntosVenta', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdPuntoVenta($id)
    {
        try {
            $result = DB::selectOne('SELECT core.fn_puntos_venta_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'El punto de venta no existe', 404);
            }
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdPuntoVenta', ['message' => $e->getMessage(), 'punto_venta_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Qué código y qué número le tocarían a la siguiente caja de una
     * sucursal, para que darla de alta sea escribir un nombre.
     */
    public function sugerencia(Request $request)
    {
        try {
            if (!$request->filled('sucursal_id')) {
                return $this->errorResponse('Hay que decir de qué sucursal', 422);
            }

            $result = DB::selectOne(
                'SELECT core.fn_puntos_venta_sugerencia(?::BIGINT) as result',
                [(int) $request->input('sucursal_id')]
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'] ?? [], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en sugerencia de punto de venta', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addPuntoVenta(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT core.fn_puntos_venta_crear(?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INTEGER, ?::TEXT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $d['sucursal_id'],
                    $d['nombre'],
                    $d['codigo'] ?? null,
                    isset($d['numero']) && $d['numero'] !== '' ? (int) $d['numero'] : null,
                    $d['descripcion'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Punto de venta creado', ['punto_venta_id' => $r['data']['id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addPuntoVenta rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addPuntoVenta', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear el punto de venta', 500);
        }
    }

    public function editPuntoVenta(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT core.fn_puntos_venta_modificar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INTEGER, ?::TEXT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    (int) $d['sucursal_id'],
                    $d['nombre'],
                    $d['codigo'] ?? null,
                    isset($d['numero']) && $d['numero'] !== '' ? (int) $d['numero'] : null,
                    $d['descripcion'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Punto de venta actualizado', ['punto_venta_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editPuntoVenta rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'punto_venta_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editPuntoVenta', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'punto_venta_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar el punto de venta', 500);
        }
    }

    /** Activa o desactiva la caja desde la casilla de la rejilla. */
    public function activarPuntoVenta(Request $request, $id)
    {
        try {
            // El booleano con filter_var: "false" en texto es true a secas
            $activo = $request->exists('activo') && $request->input('activo') !== null && $request->input('activo') !== ''
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE)
                : null;

            $result = DB::selectOne(
                'SELECT core.fn_puntos_venta_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 500);
            }

            sistemaLog('info', 'Punto de venta activado/desactivado',
                       ['punto_venta_id' => $id, 'activo' => $r['data']['activo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarPuntoVenta', ['message' => $e->getMessage(), 'punto_venta_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cambiar el estado del punto de venta', 500);
        }
    }

    public function deletePuntoVenta(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT core.fn_puntos_venta_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Punto de venta enviado a la papelera', ['punto_venta_id' => $id]);
            return $this->successResponse($r['data'] ?? null, $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deletePuntoVenta', ['message' => $e->getMessage(), 'punto_venta_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar el punto de venta', 500);
        }
    }

    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================
    //
    // «Eliminar» es un borrado lógico: la caja sale del listado pero sus
    // cuentas se quedan, para que al restaurarla vuelva con lo suyo puesto.
    // Al borrarla DE VERDAD sí se van con ella (lo hace la función de base:
    // cuentas_config apunta al punto de venta por ámbito e id, y eso no es
    // una clave ajena que la base pueda limpiar sola).

    public function papelera()
    {
        try {
            $result = DB::selectOne('SELECT core.fn_puntos_venta_papelera_listar() as result');
            $r = json_decode($result->result, true);
            return $this->successResponse($r ?? [], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de puntos de venta', ['message' => $e->getMessage()]);
            return $this->errorResponse('Ocurrió un error al listar la papelera', 500);
        }
    }

    public function restaurarPuntosVenta(Request $request)
    {
        return $this->accionPapelera($request, 'core.fn_puntos_venta_restaurar', 'restaurarPuntosVenta');
    }

    public function eliminarDefinitivo(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS y además se lleva las cuentas
        // configuradas de la caja: hace falta el permiso «vaciar», que es
        // otro distinto de «papelera». Se comprueba AQUÍ y no sólo en el
        // front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allPuntosVenta', 'vaciar',
                'No tiene permiso para eliminar definitivamente puntos de venta')) {
            return $no;
        }

        return $this->accionPapelera($request, 'core.fn_puntos_venta_eliminar_definitivo', 'eliminarDefinitivo');
    }

    public function vaciarPapelera(Request $request)
    {
        if ($no = $this->exigirPermiso('allPuntosVenta', 'vaciar',
                'No tiene permiso para vaciar la papelera de puntos de venta')) {
            return $no;
        }

        return $this->accionPapelera($request, 'core.fn_puntos_venta_papelera_vaciar', 'vaciarPapelera', false);
    }

    /** El tronco común de restaurar / eliminar definitivo / vaciar. */
    private function accionPapelera(Request $request, string $funcion, string $nombre, bool $conIds = true)
    {
        try {
            $auditoria = $this->auditoria($request);

            if ($conIds) {
                $validator = Validator::make($request->all(), [
                    'ids'   => 'required|array|min:1|max:500',
                    'ids.*' => 'integer',
                ], [
                    'ids.required' => 'No se indicó ningún punto de venta',
                ]);
                if ($validator->fails()) {
                    return $this->errorResponse($validator->errors()->first(), 422);
                }
                $result = DB::selectOne(
                    "SELECT {$funcion}(?::JSONB, " . self::CASTS_AUDIT . ") as result",
                    array_merge([json_encode(array_map('intval', $validator->validated()['ids']))], $auditoria)
                );
            } else {
                $result = DB::selectOne("SELECT {$funcion}(" . self::CASTS_AUDIT . ") as result", $auditoria);
            }
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo completar la operación', 409);
            }

            sistemaLog('info', 'Papelera de puntos de venta: ' . $nombre, ['data' => $r['data'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', $nombre . ' rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en ' . $nombre, ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al procesar la papelera', 500);
        }
    }
}
