<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * Las GALERÍAS de la tienda. SIN TOKEN.
 *
 *   GET ecommerce/publico/galerias/{clave}
 *
 * Una galería es un SITIO del diseño con su clave fija —`inicio_banner`,
 * `pagos_tarjetas`, `espana_motos_tarjetas`— y lo que devuelve son las
 * imágenes que toca enseñar ahí AHORA: sin las apagadas y sin las que estén
 * fuera de su vigencia.
 *
 * LA CACHÉ ES POR CLAVE y corta, UN MINUTO, no diez como el encabezado. Las
 * imágenes llevan fecha de inicio y de fin: una promoción programada para las
 * 00:00 tiene que entrar sola, y con diez minutos de caché entraría tarde sin
 * que nadie hubiera tocado nada. Un minuto es suficiente para quitar la carga
 * y poco para que se note.
 *
 * Una clave que no existe da 404 y no una galería vacía: son dos cosas
 * distintas —«ese hueco no existe» y «ese hueco está sin llenar»— y la tienda
 * las trata distinto.
 */
class GaleriaPublicoController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ArchivosDeLaTienda;

    private const CACHE_PREFIJO = 'ecommerce.galerias.publica.';
    private const MINUTOS = 1;

    /** La llamará la pantalla de galerías cuando la haya. */
    public static function limpiar(string $clave): void
    {
        Cache::forget(self::CACHE_PREFIJO . $clave);
    }

    public function listar($clave)
    {
        try {
            $clave = (string) $clave;

            $data = Cache::remember(self::CACHE_PREFIJO . $clave, now()->addMinutes(self::MINUTOS),
                function () use ($clave) {
                    $fila = DB::selectOne('SELECT ecommerce.fn_galerias_publica(?::TEXT) as result', [$clave]);
                    return $fila && $fila->result ? json_decode($fila->result, true) : null;
                });

            if (!$data) {
                return $this->errorResponse('Galería no encontrada', 404)
                            ->header('Cache-Control', 'no-cache');
            }

            // La base guarda el nombre del fichero; la dirección se arma aquí
            $imagenes = array_map(function ($i) {
                $i['imagen']       = $this->urlArchivo($i['imagen'] ?? null, 'imagenes');
                $i['imagen_movil'] = $this->urlArchivo($i['imagen_movil'] ?? null, 'imagenes');
                return $i;
            }, $data['imagenes'] ?? []);

            // SE DEVUELVE LA LISTA PELADA, no la galería con sus imágenes
            // dentro. Quien la pide ya sabe qué sitio pidió —la clave está en
            // su propia llamada— y lo único que hace es recorrerla; el
            // nombre y el tipo sólo le sirven a la pantalla que la administra.
            return $this->successResponse($imagenes, 'Galería')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar la galería', ['clave' => $clave, 'error' => $e->getMessage()]);
            return $this->errorResponse('No se pudo cargar la galería', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }
}
