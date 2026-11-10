<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * El MENÚ DE MARCAS que pinta la tienda. SIN TOKEN.
 *
 *   GET ecommerce/publico/marcas-menu
 *
 * Es el desplegable «MARCAS» del encabezado, el de al lado de «CATEGORÍAS», y
 * se parece a aquél en todo lo que se puede: misma forma de nodo, mismo tipo
 * de respuesta y misma caché. Lo que cambia es que una marca no tiene marcas
 * dentro, así que la lista es plana y `hijos` siempre llega vacío.
 *
 * A DÓNDE LLEVA CADA MARCA LO DECIDE LA BASE: su página si alguien le armó una
 * y, si no, el catálogo filtrado de siempre (`/shop?marca=12`).
 *
 * CON CACHÉ DE DIEZ MINUTOS, como el de categorías: se pide al abrir el menú y
 * cambia cuando alguien reordena las marcas o esconde una, que no es a diario.
 * La tiran las pantallas del CRM que tocan eso (MarcaWebController) y la de
 * cuerpos, porque una página nueva de marca cambia a dónde lleva su enlace.
 */
class MarcaWebPublicoController extends Controller
{
    use ApiResponder;

    public const CACHE_CLAVE = 'ecommerce.marcas.menu';
    private const MINUTOS = 10;

    public static function limpiar(): void
    {
        Cache::forget(self::CACHE_CLAVE);
    }

    public function menu()
    {
        try {
            $data = Cache::remember(self::CACHE_CLAVE, now()->addMinutes(self::MINUTOS), function () {
                $fila = DB::selectOne('SELECT ecommerce.fn_marcas_web_menu_publico() as result');
                return json_decode($fila->result, true) ?: [];
            });

            return $this->successResponse($data, 'Marcas')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar el menú de marcas', ['error' => $e->getMessage()]);

            // La tienda se queda sin menú de marcas pero sigue en pie: su
            // servicio lo deja vacío y lo marca como fallo.
            return $this->errorResponse('No se pudieron cargar las marcas', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }
}
