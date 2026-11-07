<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * El ENCABEZADO Y EL PIE que pinta la tienda, en una sola llamada. SIN TOKEN.
 *
 *   GET ecommerce/publico/secciones
 *
 * Es lo PRIMERO que pide la tienda al abrir cualquier página: sin esto no hay
 * menú, ni buscador, ni pie. Por eso va en una sola petición y con caché.
 *
 * LA CACHÉ ES DE DIEZ MINUTOS y la limpia quien edita (ver el método
 * `limpiar`, que llaman EncabezadoController y PiePaginaController). Esto se
 * consulta en cada visita y cambia dos veces al mes: dejarlo sin caché sería
 * una consulta por visitante para devolver siempre lo mismo. Diez minutos es
 * el techo de lo que puede tardar en verse un cambio si la limpieza fallara.
 *
 * EL JSON LO ARMA LA BASE (`fn_secciones_publicas`), no este controlador: las
 * reglas de qué se enseña y qué no —un enlace con desplegables no lleva
 * dirección propia, uno sin hijos y sin dirección no se pinta— viven junto a
 * los datos y no repartidas entre SQL y PHP.
 */
class SeccionPublicaController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ImagenesDelEcommerce;

    public const CACHE_CLAVE = 'ecommerce.secciones.publicas';
    private const MINUTOS = 10;

    /** La llaman las pantallas de administración después de cada cambio. */
    public static function limpiar(): void
    {
        Cache::forget(self::CACHE_CLAVE);
    }

    public function listar()
    {
        try {
            $data = Cache::remember(self::CACHE_CLAVE, now()->addMinutes(self::MINUTOS), function () {
                $fila = DB::selectOne('SELECT ecommerce.fn_secciones_publicas() as result');
                $datos = json_decode($fila->result, true) ?: [];

                // La base guarda el nombre del fichero de la imagen de cada
                // columna del pie; la dirección se arma aquí, como en el resto
                // del ecommerce. Se hace DENTRO de la caché para no rehacerlo
                // en cada petición
                foreach ($datos as &$seccion) {
                    // `$seccion['grupos'] ?? []` dentro del foreach NO vale: el `??`
                    // devuelve una copia y la referencia escribiría en ella, no en
                    // los datos. Se mira antes y se recorre el array de verdad
                    if (!isset($seccion['grupos']) || !is_array($seccion['grupos'])) {
                        continue;
                    }
                    foreach ($seccion['grupos'] as &$grupo) {
                        if (is_array($grupo['imagen'] ?? null)) {
                            $grupo['imagen']['url'] = $this->urlImagenEcommerce($grupo['imagen']['archivo'] ?? null);
                            unset($grupo['imagen']['archivo']);
                        }
                    }
                    unset($grupo);
                }
                unset($seccion);

                return $datos;
            });

            return $this->successResponse($data, 'Encabezado y pie de página')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar el encabezado y el pie', ['error' => $e->getMessage()]);

            // La tienda tiene su propia maqueta de reserva para este caso, así
            // que un 500 aquí no la deja en blanco: le dice que use la suya.
            return $this->errorResponse('No se pudo cargar el encabezado y el pie', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }
}
