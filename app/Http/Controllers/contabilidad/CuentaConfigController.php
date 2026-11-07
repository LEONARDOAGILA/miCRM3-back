<?php

namespace App\Http\Controllers\contabilidad;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * Qué cuenta contable usa cada cosa (contabilidad.cuentas_config).
 *
 * De momento se configuran las CATEGORÍAS de inventario, que es de donde
 * salen las cuentas de un producto: inventario, ingreso, costo, devoluciones
 * y descuentos. El mismo mecanismo servirá para los clientes, las sucursales
 * y los impuestos sin tocar nada de esto: lo único que cambia es el ámbito.
 *
 * LAS CUENTAS SE HEREDAN: lo que no tiene puesto una categoría lo toma de las
 * de arriba, y al final del ámbito GLOBAL. Por eso la ficha devuelve las dos
 * cosas —`propia` y `efectiva`—: una es lo que se edita y la otra lo que se
 * va a usar de verdad.
 *
 * Toda la lógica vive en contabilidad.fn_cuentas_config_*; aquí sólo se
 * valida la entrada y se traduce la respuesta.
 *
 *   GET  contabilidad/cuentaConfig/conceptos[?ambito=CATEGORIA]
 *   GET  contabilidad/cuentaConfig/categorias[?transaccion=1]
 *   GET  contabilidad/cuentaConfig/obtener/{ambito}[/{id}]
 *   POST contabilidad/cuentaConfig/guardar/{ambito}[/{id}]   { cuentas: {CONCEPTO: id|null|'NO_APLICA'} }
 */
class CuentaConfigController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato o viene mal
        'P0013' => 404,   // la cuenta está en la papelera
        'P0016' => 422,   // la categoría no existe
        'P0021' => 409,   // la cuenta no sirve: inactiva o de grupo
        'P0022' => 409,   // la cuenta no es del tipo que pide el concepto
    ];

    /** Lo que se acepta para decir «aquí este concepto no existe». */
    private const NO_APLICA = ['NO_APLICA', 'NO APLICA', 'N/A'];

    /** Los ámbitos que admite la tabla. La lista está también en el CHECK. */
    private const AMBITOS = ['CATEGORIA', 'PRODUCTO', 'GRUPO_CLIENTE', 'CLIENTE', 'SUCURSAL', 'PUNTO_VENTA', 'IMPUESTO', 'FORMA_PAGO', 'GLOBAL'];

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

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

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

    /** El ámbito, en mayúsculas y de la lista; null si no vale. */
    private function ambitoValido($ambito): ?string
    {
        $a = strtoupper(trim((string) $ambito));
        return in_array($a, self::AMBITOS, true) ? $a : null;
    }

    // ================================================================
    // LEER
    // ================================================================

    /** Qué cuentas se le piden a cada cosa, y de qué tipo pueden ser. */
    public function conceptos(Request $request)
    {
        try {
            $ambito = $request->filled('ambito') ? $this->ambitoValido($request->input('ambito')) : null;

            $result = DB::selectOne(
                'SELECT contabilidad.fn_conceptos_contables_listar(?::VARCHAR) as result', [$ambito]);
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'] ?? [], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en conceptos contables', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar los conceptos contables', 500);
        }
    }

    /**
     * El árbol de categorías con la cuenta que usa cada una.
     *
     * Sin paginar, como el árbol de categorías del que sale: las filas vienen
     * en el orden en que se dibujan y cada una trae su `nivel`.
     */
    public function categorias(Request $request)
    {
        try {
            $soloTransaccion = $request->input('transaccion', '0') === '1';

            $result = DB::selectOne(
                'SELECT contabilidad.fn_cuentas_config_categorias(?::BOOLEAN) as result', [$soloTransaccion]);
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar las cuentas por categoría', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en cuentas por categoría', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * El árbol de GRUPOS DE CLIENTES con la cuenta que usa cada uno.
     *
     * El hermano de `categorias`: mismo trato —sin paginar, con el `nivel` de
     * cada fila— pero sobre ventas.grupos_clientes y con los conceptos del
     * cliente (cuenta por cobrar, anticipos, mora, incobrables).
     */
    public function grupos(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '0') === '1';

            $result = DB::selectOne(
                'SELECT contabilidad.fn_cuentas_config_grupos(?::BOOLEAN) as result', [$soloActivos]);
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar las cuentas por grupo de clientes', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en cuentas por grupo de clientes', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Los conceptos de una cosa: lo que tiene puesto y lo que usaría. */
    public function obtener(Request $request, $ambito, $id = null)
    {
        try {
            $a = $this->ambitoValido($ambito);
            if ($a === null) {
                return $this->errorResponse('Ámbito no válido', 422);
            }
            if (($a === 'GLOBAL') !== ($id === null || $id === '')) {
                return $this->errorResponse('El ámbito GLOBAL no lleva id, y los demás lo necesitan', 422);
            }

            $result = DB::selectOne(
                'SELECT contabilidad.fn_cuentas_config_obtener(?::VARCHAR, ?::BIGINT) as result',
                [$a, $id === null || $id === '' ? null : (int) $id]);
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message'] ?? 'La solicitud ha tenido éxito');

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en obtener cuentas config',
                       ['message' => $e->getMessage(), 'ambito' => $ambito, 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    /**
     * Guarda las cuentas de una cosa.
     *
     * Body: { cuentas: { "INGRESO": 123, "COSTO": null, "INVENTARIO": "NO_APLICA" } }:
     *
     *   · un id        la cuenta que usa;
     *   · null         quitar lo propio y volver a heredar;
     *   · "NO_APLICA"  aquí este concepto no existe, y no se hereda nada
     *                  (el inventario de un servicio, por ejemplo).
     *
     * Lo que no venga no se toca, así que se puede mandar sólo lo que cambió.
     */
    public function guardar(Request $request, $ambito, $id = null)
    {
        try {
            $a = $this->ambitoValido($ambito);
            if ($a === null) {
                return $this->errorResponse('Ámbito no válido', 422);
            }
            if (($a === 'GLOBAL') !== ($id === null || $id === '')) {
                return $this->errorResponse('El ámbito GLOBAL no lleva id, y los demás lo necesitan', 422);
            }

            $datos = $this->datosDe($request);
            $validator = Validator::make($datos, [
                'cuentas' => 'required|array|min:1',
            ], [
                'cuentas.required' => 'No se indicó ninguna cuenta',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            // Tres estados por concepto, y los tres tienen que sobrevivir al
            // json_encode: el id, el nulo —que QUITA lo propio y vuelve a
            // heredar— y el «no aplica», que corta la herencia.
            $cuentas = [];
            foreach ((array) ($datos['cuentas'] ?? []) as $concepto => $valor) {
                if ($valor === null || $valor === '') {
                    $cuentas[$concepto] = null;
                } elseif (is_string($valor) && in_array(strtoupper(trim($valor)), self::NO_APLICA, true)) {
                    $cuentas[$concepto] = 'NO_APLICA';
                } elseif (is_numeric($valor)) {
                    $cuentas[$concepto] = (int) $valor;
                } else {
                    return $this->errorResponse(
                        "La cuenta de «{$concepto}» tiene que ser un id, vacío para heredar, o NO_APLICA", 422);
                }
            }

            $result = DB::selectOne(
                'SELECT contabilidad.fn_cuentas_config_guardar(?::VARCHAR, ?::BIGINT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $a,
                    $id === null || $id === '' ? null : (int) $id,
                    json_encode($cuentas, JSON_FORCE_OBJECT),
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Cuentas contables guardadas',
                       ['ambito' => $a, 'ambito_id' => $id, 'conceptos' => array_keys($cuentas)]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'guardar cuentas config rechazado',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(),
                        'ambito' => $ambito, 'id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en guardar cuentas config',
                       ['message' => $e->getMessage(), 'line' => $e->getLine(), 'ambito' => $ambito, 'id' => $id]);
            return $this->errorResponse('Ocurrió un error al guardar las cuentas contables', 500);
        }
    }
}
