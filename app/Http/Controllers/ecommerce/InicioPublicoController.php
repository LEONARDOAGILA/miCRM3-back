<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * LA PORTADA de la tienda. SIN TOKEN.
 *
 *   GET ecommerce/publico/inicio
 *
 * No devuelve una página sino una LISTA DE SECCIONES en su orden, cada una con
 * su clave y sus datos. La tienda pinta las que conoce y se salta el resto,
 * así que esto puede ir creciendo según se trasladen sus fuentes sin que haya
 * que tocar la tienda.
 *
 * SALEN LAS QUE YA TIENEN DE DÓNDE SACAR DATOS: las dos de banner, las
 * categorías destacadas, el mosaico, las marcas y las SECCIONES DE PRODUCTOS.
 * Las tres que faltan —ofertas de la semana, grilla y bloques— tiran del
 * catálogo, que aún no está migrado, y se caen solas: una sección sin nada que
 * enseñar no se manda, porque dejaría un hueco con su título y nada debajo.
 *
 * LAS SECCIONES DE PRODUCTOS VIAJAN CON LA FOTO Y EL NOMBRE, y nada más. La
 * tarjeta de la tienda lleva además precio, descuento y existencias, y de eso
 * el catálogo no tiene nada todavía: media tarjeta sacaría todo «Agotado» y a
 * $0. Todas van con la clave `productos` y su `id`: la tienda conmuta por la
 * clave para saber qué pieza pintar, y una clave distinta por sección la
 * obligaría a adivinar.
 *
 * `ahora` VA SIEMPRE Y FUERA DE LA CACHÉ. Es la hora del SERVIDOR, y la usa la
 * cuenta regresiva de las ofertas: si se tomara la del navegador, cualquiera
 * con el reloj mal vería la promoción abierta o cerrada cuando no toca.
 */
class InicioPublicoController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ArchivosDeLaTienda;
    use \App\Http\Controllers\Concerns\ImagenesDelEcommerce;

    public const CACHE_CLAVE = 'ecommerce.inicio.publico';
    /** Corta, como las galerías: las secciones y sus imágenes llevan vigencia. */
    private const MINUTOS = 1;

    public static function limpiar(): void
    {
        Cache::forget(self::CACHE_CLAVE);
    }

    public function inicio()
    {
        try {
            $data = Cache::remember(self::CACHE_CLAVE, now()->addMinutes(self::MINUTOS), function () {
                $fila = DB::selectOne('SELECT ecommerce.fn_inicio_publico() as result');
                $datos = json_decode($fila->result, true) ?: ['secciones' => []];

                // La base guarda el nombre del fichero; la dirección se arma
                // aquí. Las de las galerías y las de las categorías están en
                // carpetas distintas, así que cada una con la suya.
                $datos['secciones'] = array_map(function ($s) {
                    if (isset($s['imagenes']) && is_array($s['imagenes'])) {
                        $s['imagenes'] = array_map(function ($i) {
                            $i['imagen']       = $this->urlArchivo($i['imagen'] ?? null, 'imagenes');
                            $i['imagen_movil'] = $this->urlArchivo($i['imagen_movil'] ?? null, 'imagenes');
                            return $i;
                        }, $s['imagenes']);
                    }
                    if (isset($s['categorias']) && is_array($s['categorias'])) {
                        $s['categorias'] = array_map(function ($c) {
                            $c['imagen'] = $this->urlImagenEcommerce($c['imagen'] ?? null);
                            return $c;
                        }, $s['categorias']);
                    }
                    // Las secciones de productos: de la base viene el nombre
                    // del fichero de la foto, y la carpeta es la del catálogo.
                    if (isset($s['productos']) && is_array($s['productos'])) {
                        $s['productos'] = array_map(function ($p) {
                            $p['imagen'] = $this->urlImagenDeProducto($p['imagen'] ?? null);
                            return $p;
                        }, $s['productos']);
                    }
                    // Las marcas traen dos candidatas en carpetas distintas: la
                    // programada (img/ecommerce) y el logo del catálogo
                    // (img/marcas). Aquí se queda UNA, que es lo que la tienda
                    // sabe pintar; la programada manda mientras esté en fecha.
                    if (isset($s['marcas']) && is_array($s['marcas'])) {
                        $s['marcas'] = array_map(function ($m) {
                            $m['imagen'] = $this->urlImagenEcommerce($m['imagen'] ?? null)
                                        ?? $this->urlLogoDeMarca($m['logo'] ?? null);
                            unset($m['logo']);
                            return $m;
                        }, $s['marcas']);
                    }
                    return $s;
                }, $datos['secciones'] ?? []);

                return $datos;
            });

            // Fuera de la caché a propósito: dentro se quedaría congelada un
            // minuto y la cuenta regresiva daría saltos.
            $data['ahora'] = now()->format('c');

            return $this->successResponse($data, 'Inicio')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar la portada', ['error' => $e->getMessage()]);
            return $this->errorResponse('No se pudo cargar el inicio', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }
}
