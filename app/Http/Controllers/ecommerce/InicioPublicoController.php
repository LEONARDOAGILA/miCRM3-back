<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * LAS PÁGINAS DE SECCIONES de la tienda. SIN TOKEN.
 *
 *   GET ecommerce/publico/inicio           el cuerpo principal  → /
 *   GET ecommerce/publico/cuerpo/{ruta}    un cuerpo secundario → /movilidad
 *
 * No devuelven una página sino una LISTA DE SECCIONES en su orden, cada una con
 * su clave y sus datos, más lo que es del cuerpo: su título, su texto y si
 * debajo va el catálogo de su categoría. La tienda pinta las secciones que
 * conoce y se salta el resto, así que esto puede ir creciendo según se
 * trasladen sus fuentes sin que haya que tocar la tienda.
 *
 * LA DIRECCIÓN QUE NO ES NADA DEVUELVE 404: no existe, está apagada o está en
 * la papelera. Es la verdad, y la tienda enseña su pantalla de «no
 * encontrado» en vez de una página vacía con el encabezado y el pie.
 *
 * SALEN LAS SECCIONES QUE YA TIENEN DE DÓNDE SACAR DATOS: las dos de banner,
 * las categorías destacadas, el mosaico, las marcas y las SECCIONES DE
 * PRODUCTOS. Las tres que faltan —ofertas de la semana, grilla y bloques—
 * tiran del catálogo, que aún no está migrado, y se caen solas: una sección
 * sin nada que enseñar no se manda, porque dejaría un hueco con su título y
 * nada debajo.
 *
 * LAS SECCIONES DE PRODUCTOS van todas con la clave `productos` y su `id`: la
 * tienda conmuta por la clave para saber qué pieza pintar, y una clave distinta
 * por sección la obligaría a adivinar. Lo que cambia entre ellas es CUÁNTOS
 * productos viajan:
 *
 *   · las DE FILA —izquierda, derecha, cartel, sola— viajan enteras: son tres,
 *     cuatro, diez, las que alguien eligió para verlas todas con las flechas;
 *   · las PAGINADAS viajan con UNA PÁGINA y con sus filtros ya contados sobre
 *     la lista entera (`total`, `ultima_pagina`, `facetas`). Hacen de catálogo,
 *     y hasta el 09/11/2026 también viajaban enteras: /tecnologia mandaba sus
 *     noventa y un productos con la ficha de cada uno —63 KB— para pintar doce
 *     tarjetas. Las demás páginas y lo que se marque en los filtros los pide la
 *     tienda a `publico/productos?escaparate=…`.
 *
 * LA PRIMERA PÁGINA VIAJA CON LA PÁGINA a propósito, y SIN FILTROS: es lo que
 * se ve al entrar, y pedirla aparte dejaría /motos con su encabezado y un hueco
 * hasta que llegara la segunda petición. Por eso tampoco depende de la
 * dirección del visitante: esta respuesta se guarda un minuto y la comparten
 * todos.
 *
 * `ahora` VA SIEMPRE Y FUERA DE LA CACHÉ. Es la hora del SERVIDOR, y la usa la
 * cuenta regresiva de las ofertas: si se tomara la del navegador, cualquiera
 * con el reloj mal vería la promoción abierta o cerrada cuando no toca.
 *
 * CADA CUERPO TIENE SU CLAVE DE CACHÉ, y `limpiar` las borra todas: pregunta
 * por las direcciones que hay en vez de llevar una lista aparte, porque una
 * lista aparte es la que se olvida de la página nueva y deja un cambio sin
 * verse hasta el minuto siguiente.
 */
class InicioPublicoController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ArchivosDeLaTienda;
    use \App\Http\Controllers\Concerns\ImagenesDelEcommerce;

    public const CACHE_CLAVE = 'ecommerce.inicio.publico';
    /** La de cada cuerpo secundario, con su dirección detrás. */
    private const CACHE_CUERPO = 'ecommerce.cuerpo.publico.';
    /** Corta, como las galerías: las secciones y sus imágenes llevan vigencia. */
    private const MINUTOS = 1;

    public static function limpiar(): void
    {
        Cache::forget(self::CACHE_CLAVE);

        try {
            $rutas = DB::select('SELECT ruta FROM ecommerce.cuerpos WHERE deleted_at IS NULL');
            foreach ($rutas as $fila) {
                Cache::forget(self::CACHE_CUERPO . $fila->ruta);
            }
        } catch (Exception $e) {
            // Si la consulta falla, lo peor que pasa es que un cambio tarde un
            // minuto en verse. No vale reventar la pantalla que estaba guardando.
            Log::warning('No se pudieron limpiar las cachés de los cuerpos', ['error' => $e->getMessage()]);
        }
    }

    /** La portada: el cuerpo que esté marcado como principal. */
    public function inicio()
    {
        return $this->responder(null);
    }

    /** Un cuerpo por su dirección. */
    public function cuerpo(string $ruta)
    {
        return $this->responder($ruta);
    }

    private function responder(?string $ruta)
    {
        $clave = $ruta === null ? self::CACHE_CLAVE : self::CACHE_CUERPO . strtolower($ruta);

        try {
            $data = Cache::remember($clave, now()->addMinutes(self::MINUTOS), function () use ($ruta) {
                $fila = DB::selectOne('SELECT ecommerce.fn_cuerpo_publico(?) as result', [$ruta]);
                $datos = json_decode($fila->result ?? '', true);

                // Sin página, nada: se guarda el `false` para no preguntar a la
                // base por la misma dirección inventada en cada visita
                return is_array($datos) ? $this->conUrls($datos) : false;
            });

            if ($data === false) {
                return $this->errorResponse('Esa página no existe', 404)
                            ->header('Cache-Control', 'no-cache');
            }

            // Fuera de la caché a propósito: dentro se quedaría congelada un
            // minuto y la cuenta regresiva daría saltos.
            $data['ahora'] = now()->format('c');

            return $this->successResponse($data, $data['cuerpo']['titulo'] ?? 'Inicio')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar la página de la tienda',
                       ['ruta' => $ruta, 'error' => $e->getMessage()]);
            return $this->errorResponse('No se pudo cargar la página', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }

    /**
     * La base guarda el nombre del fichero; la dirección se arma aquí.
     *
     * Las de las galerías, las de las categorías y las del catálogo están en
     * carpetas distintas, así que cada una con la suya.
     */
    private function conUrls(array $datos): array
    {
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
            // del fichero de cada foto, y la carpeta es la del
            // catálogo.
            if (isset($s['productos']) && is_array($s['productos'])) {
                $s['productos'] = array_map(fn ($p) => $this->conUrlDeProducto($p), $s['productos']);
            }
            // La imagen de AL LADO de una sección de productos. La
            // base ya resolvió si va o no —sin fichero, `lado` sale
            // 'sola'—, así que aquí sólo se le pone la dirección.
            if (isset($s['imagen']) && is_array($s['imagen'])) {
                $s['imagen']['url'] = $this->urlImagenEcommerce($s['imagen']['archivo'] ?? null);
                // `archivo` y `elegido` son del CRM: el nombre del
                // fichero en el disco y el lado que se eligió aunque
                // todavía no haya imagen. La tienda pinta por `lado`
                unset($s['imagen']['archivo'], $s['imagen']['elegido']);
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
    }

    /**
     * Las fotos de una tarjeta de producto.
     *
     * ES LA MISMA TARJETA QUE MANDA EL CATÁLOGO, venga de un escaparate de fila
     * (fn_producto_seccion_publica) o de la primera página de uno paginado
     * (fn_tienda_productos): las mismas claves y la misma conversión en la
     * tienda. Lo único que cambia es cuántas fotos trae —el de fila manda las
     * dos que pinta la tarjeta; el catálogo, la galería entera, que de ahí sale
     * también la ficha—, y eso no cambia nada aquí.
     *
     * EL LOGO DE LA MARCA ESTÁ EN OTRA CARPETA (img/marcas): es del catálogo de
     * Inventarios, no de la tienda. Sin logo queda null y la tarjeta escribe el
     * nombre.
     */
    private function conUrlDeProducto(array $p): array
    {
        $p['imagenes'] = array_values(array_filter(array_map(
            fn ($archivo) => $this->urlImagenDeProducto($archivo),
            is_array($p['imagenes'] ?? null) ? $p['imagenes'] : []
        )));
        $p['marca_logo'] = $this->urlLogoDeMarca($p['marca_logo'] ?? null);

        return $p;
    }
}
