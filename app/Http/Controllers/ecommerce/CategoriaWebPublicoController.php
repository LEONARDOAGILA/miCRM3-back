<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * El MENÚ DE CATEGORÍAS que pinta la tienda. SIN TOKEN.
 *
 *   GET ecommerce/publico/categorias-menu
 *
 * Es el desplegable «CATEGORÍAS» del encabezado y lo que arma el panel de
 * filtros de /shop: sin esto, la tienda no sabe por dónde dejar navegar.
 *
 * Devuelve el árbol ya anidado —{id, nombre, hijos:[…]}— y no una lista plana
 * con su padre, que es lo que hacía el CRM viejo: el que lo pinta sólo tiene
 * que recorrerlo. Armarlo en la base cuesta lo mismo y evita que cada
 * consumidor rehaga el árbol a su manera.
 *
 * CON CACHÉ DE DIEZ MINUTOS, por lo mismo que el encabezado: se pide en cada
 * visita y cambia cuando alguien reorganiza el catálogo, que no es a diario.
 * La tira la pantalla de categorías cuando la haya; mientras tanto, diez
 * minutos es lo que puede tardar en verse un cambio del catálogo.
 */
class CategoriaWebPublicoController extends Controller
{
    use ApiResponder;

    public const CACHE_CLAVE = 'ecommerce.categorias.menu';
    private const MINUTOS = 10;

    public static function limpiar(): void
    {
        Cache::forget(self::CACHE_CLAVE);
    }

    public function menu()
    {
        try {
            $data = Cache::remember(self::CACHE_CLAVE, now()->addMinutes(self::MINUTOS), function () {
                $fila = DB::selectOne('SELECT ecommerce.fn_categorias_web_menu_publico() as result');
                return json_decode($fila->result, true) ?: [];
            });

            return $this->successResponse($data, 'Categorías')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar el menú de categorías', ['error' => $e->getMessage()]);

            // La tienda se queda sin menú de categorías pero sigue en pie: su
            // servicio lo deja vacío y lo marca como fallo.
            return $this->errorResponse('No se pudieron cargar las categorías', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }
}
