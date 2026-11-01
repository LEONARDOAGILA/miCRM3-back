<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Support\Facades\DB;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * El resumen de la portada del módulo: cuántas cosas hay en cada área.
 *
 *   GET ecommerce/resumen/getResumen
 *
 * UNA SOLA LLAMADA para las once tarjetas. El CRM viejo pedía una por
 * tarjeta: la portada parpadeaba mientras iban llegando y, con una sola
 * caída, esa tarjeta se quedaba en «No se pudo cargar» para siempre. Aquí
 * todo sale de una consulta; si falla, falla la portada entera y se ve.
 *
 * SIN CACHÉ, al revés que lo público. Esto lo mira quien acaba de cambiar
 * algo, justo para comprobar que cambió: una caché de diez minutos haría
 * dudar de si se guardó.
 */
class ResumenController extends Controller
{
    use ApiResponder;

    public function __construct()
    {
        $this->middleware('auth:api');
    }

    public function getResumen()
    {
        try {
            $r = json_decode(DB::selectOne('SELECT ecommerce.fn_resumen() as result')->result, true);
            return $this->successResponse($r['data'] ?? [], $r['message'] ?? 'Resumen');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en el resumen de la página web', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
