<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * ESPAÑA MOTOS, lo que lee la tienda. SIN TOKEN.
 *
 *   GET ecommerce/publico/espana-motos
 *
 * SIN PUBLICAR DEVUELVE 404 y no una página vacía. Son dos cosas distintas:
 * «esto no existe» deja que la tienda enseñe su aviso de siempre, mientras
 * que una respuesta a medias pintaría una portada con huecos mientras se está
 * montando, a la vista de cualquiera.
 */
class EspanaMotosPublicoController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ArchivosDeLaTienda;

    public const CACHE_CLAVE = 'ecommerce.espana_motos.publica';
    /** Corta, como las galerías: sus imágenes llevan vigencia. */
    private const MINUTOS = 1;

    public static function limpiar(): void
    {
        Cache::forget(self::CACHE_CLAVE);
    }

    public function pagina()
    {
        try {
            $data = Cache::remember(self::CACHE_CLAVE, now()->addMinutes(self::MINUTOS), function () {
                $fila = DB::selectOne('SELECT ecommerce.fn_espana_motos_publica() as result');
                return $fila && $fila->result ? json_decode($fila->result, true) : null;
            });

            if (!$data) {
                return $this->errorResponse('España Motos no está disponible', 404)
                            ->header('Cache-Control', 'no-cache');
            }

            // Las direcciones de los ficheros se arman aquí
            foreach (['banner', 'tarjetas'] as $bloque) {
                $data[$bloque] = array_map(function ($i) {
                    $i['imagen']       = $this->urlArchivo($i['imagen'] ?? null, 'imagenes');
                    $i['imagen_movil'] = $this->urlArchivo($i['imagen_movil'] ?? null, 'imagenes');
                    return $i;
                }, $data[$bloque] ?? []);
            }

            if (!empty($data['fondo']['imagen'])) {
                $data['fondo']['imagen'] = $this->urlArchivo($data['fondo']['imagen'], 'imagenes');
            }

            return $this->successResponse($data, 'España Motos')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar España Motos', ['error' => $e->getMessage()]);
            return $this->errorResponse('No se pudo cargar España Motos', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }
}
