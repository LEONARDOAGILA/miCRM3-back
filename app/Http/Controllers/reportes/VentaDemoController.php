<?php

namespace App\Http\Controllers\reportes;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * EL TABLERO DE VENTAS DEMO (reportes.ventas_demo).
 *
 * Tres cosas y ninguna escribe nada: esto sólo lee.
 *
 *   GET inventario de opciones  qué se puede poner en filas, en columnas y
 *                               como medida. Lo decide la base, no el front.
 *   GET el pivote               la tabla cruzada, ya agregada.
 *   GET el detalle              las ventas una a una, paginadas.
 *
 * POR QUÉ LA AGREGACIÓN NO VIENE AL NAVEGADOR: agrupar y pivotar dentro de
 * ag-Grid es de la edición Enterprise —aquí está la Community— y, aunque se
 * comprara, obligaría a bajarse todas las filas para sumar doce números.
 * PostgreSQL agrupa y manda de vuelta sólo lo que se ve.
 *
 * LAS CLAVES NO SE CONCATENAN A CIEGAS: la función de la base tiene su lista
 * blanca (`reportes.fn_ventas_demo_expresion`) y lo que no esté ahí se
 * rechaza con P0015. Aquí se pasan tal cual y se deja que ella decida: una
 * sola puerta y no dos listas que puedan decir cosas distintas.
 */
class VentaDemoController extends Controller
{
    use ApiResponder;

    /** Errores de negocio de las funciones: son del usuario, no del servidor. */
    private const ERRORES_NEGOCIO = [
        'P0015' => 422,   // una dimensión o una medida que no existe
    ];

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

    /**
     * Los filtros del tablero, tal como los manda la pantalla.
     *
     * Se aceptan como JSON en `filtros` (o sueltos). No se validan contra una
     * lista aquí: la función de la base los mete por `quote_literal`, así que
     * una comilla —o un DROP TABLE— acaba siendo un texto que no encuentra
     * nada. Comprobado.
     */
    private function filtrosDe(Request $request): array
    {
        $crudos = $request->input('filtros');
        if (is_string($crudos)) {
            $crudos = json_decode($crudos, true);
        }
        if (!is_array($crudos)) {
            $crudos = [];
        }

        foreach (['desde', 'hasta', 'buscar'] as $suelto) {
            if ($request->filled($suelto)) {
                $crudos[$suelto] = $request->input($suelto);
            }
        }

        return $crudos;
    }

    // ================================================================

    /** Qué se puede elegir: dimensiones, medidas, operaciones y los valores que hay. */
    public function opciones()
    {
        try {
            $r = DB::selectOne('SELECT reportes.fn_ventas_demo_opciones() as result');
            return $this->successResponse(json_decode($r->result, true), 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en opciones de ventas demo', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * La tabla cruzada.
     *
     * ?filas=region&columnas=mes&medida=total&agregacion=SUM
     * &filtros={"desde":"2026-01-01","region":["Sierra"]}
     */
    public function pivote(Request $request)
    {
        try {
            $r = DB::selectOne(
                'SELECT reportes.fn_ventas_demo_pivote(?::TEXT, ?::TEXT, ?::TEXT, ?::TEXT, ?::JSONB, ?::TEXT, ?::INTEGER) as result',
                [
                    (string) $request->input('filas', 'region'),
                    (string) $request->input('columnas', 'mes'),
                    (string) $request->input('medida', 'total'),
                    (string) $request->input('agregacion', 'SUM'),
                    json_encode((object) $this->filtrosDe($request)),
                    (string) $request->input('orden', 'valor'),
                    (int) $request->input('limite', 200),
                ]
            );
            $data = json_decode($r->result, true);

            if (isset($data['success']) && $data['success'] === false) {
                return $this->errorResponse($data['message'], 500);
            }
            return $this->successResponse($data, 'La solicitud ha tenido éxito');

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en el pivote de ventas demo', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** El detalle, fila a fila. Mismo esquema de paginación que las demás pantallas. */
    public function detalle(Request $request)
    {
        try {
            $r = DB::selectOne(
                'SELECT reportes.fn_ventas_demo_listar_paginado(?::INTEGER, ?::INTEGER, ?::JSONB, ?::TEXT, ?::TEXT) as result',
                [
                    (int) $request->input('page', 1),
                    (int) $request->input('per_page', 25),
                    json_encode((object) $this->filtrosDe($request)),
                    (string) $request->input('ordenar', 'fecha'),
                    (string) $request->input('sentido', 'DESC'),
                ]
            );
            $data = json_decode($r->result, true);

            if (isset($data['success']) && $data['success'] === false) {
                return $this->errorResponse($data['message'], 500);
            }
            return $this->successResponse($data, 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en el detalle de ventas demo', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
