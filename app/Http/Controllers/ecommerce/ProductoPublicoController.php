<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Controllers\Concerns\ImagenesDelEcommerce;
use App\Http\Resources\ApiResponder;

/**
 * EL CATÁLOGO QUE LEE LA TIENDA Y SU BUSCADOR. SIN TOKEN.
 *
 *   GET ecommerce/publico/productos            una página de productos
 *   GET ecommerce/publico/productos/{id}       la ficha de uno
 *   GET ecommerce/publico/buscador?q=…         lo que sale mientras se escribe
 *
 * `productos` es lo que piden /shop, las páginas de marca y España Motos:
 * una página de fichas MÁS las opciones del panel de la izquierda con cuántos
 * productos habría con cada una. El contrato —`pro_id`, `tpr_id`, `opciones`,
 * `ultima_pagina`…— lo escribió el CRM anterior y la tienda ya lo habla, así
 * que se respeta tal cual: cambiarlo aquí sería tener que tocar la tienda.
 *
 * `buscador` es el desplegable del encabezado: unas pocas fichas, cuántas hay
 * en total y las sugerencias (cómo sigue la palabra, en qué categoría buscar,
 * de qué marca). Por dentro es la MISMA búsqueda, así que lo que se ve en el
 * desplegable y lo que sale al pulsar «Ver todos los N productos» no se
 * pueden contradecir.
 *
 * LOS FILTROS NO SE VALIDAN AQUÍ: se pasan tal cual a la base, que es quien
 * sabe qué hacer con cada uno. Un `page=hola` o un `marca=;DROP` no son un
 * problema —van como parámetro de una función, no pegados a la consulta— y
 * acaban en null, que es «sin filtro». Devolver 422 por una dirección mal
 * escrita dejaría la tienda en blanco por nada.
 *
 * SÓLO EL BUSCADOR LLEVA CACHÉ, y de un minuto. Se pide en cada tecla que se
 * escribe, y las mismas cuatro o cinco búsquedas se repiten todo el día. El
 * catálogo no: cada combinación de filtros sería una entrada distinta y se
 * llenaría de entradas que no se vuelven a pedir.
 */
class ProductoPublicoController extends Controller
{
    use ApiResponder;
    use ImagenesDelEcommerce;

    /** Los parámetros que entiende el catálogo. Lo demás se ignora. */
    private const FILTROS = [
        'search', 'categoria', 'marca', 'sort', 'price_min', 'price_max',
        'page', 'per_page', 'motos',
    ];

    public const CACHE_PREFIJO = 'ecommerce.buscador.';
    private const MINUTOS = 1;

    /** Cuántas fichas van en el desplegable. */
    private const EN_EL_DESPLEGABLE = 6;

    /** A partir de cuántas letras se busca: con una sola casa medio catálogo. */
    private const LETRAS_MINIMAS = 2;

    /**
     * Una página del catálogo.
     *
     * GET ecommerce/publico/productos?search=&categoria=&marca=&sort=&page=…
     */
    public function listar(Request $request)
    {
        try {
            $data = $this->buscar($this->filtrosDe($request));

            return $this->successResponse($data, 'Productos')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo buscar en el catálogo', [
                'filtros' => $this->filtrosDe($request), 'error' => $e->getMessage(),
            ]);
            return $this->errorResponse('No se pudieron cargar los productos', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }

    /**
     * La ficha de un producto.
     *
     * GET ecommerce/publico/productos/{id}
     *
     * LO QUE NO SE PUEDE VER DA 404 —no existe, está apagado o su categoría
     * está oculta—, que es lo que la tienda espera para enseñar su pantalla de
     * «no encontrado». Una ficha a medias sería peor.
     */
    public function ficha($id)
    {
        try {
            $fila = DB::selectOne('SELECT ecommerce.fn_tienda_producto(?::bigint) as result', [$id]);
            $data = $fila && $fila->result ? json_decode($fila->result, true) : null;

            if (!$data) {
                return $this->errorResponse('Ese producto no existe', 404)
                            ->header('Cache-Control', 'no-cache');
            }

            $data['producto']['imagenes'] = array_values(array_filter(array_map(
                fn ($archivo) => $this->urlImagenDeProducto($archivo),
                is_array($data['producto']['imagenes'] ?? null) ? $data['producto']['imagenes'] : []
            )));
            // Sólo si hay marca: tocarlo cuando es null lo convertiría en un
            // objeto con un logo vacío, y la tienda distingue «sin marca» de
            // «marca sin logo»
            if (!empty($data['producto']['marca'])) {
                $data['producto']['marca']['logo'] =
                    $this->urlLogoDeMarca($data['producto']['marca']['logo'] ?? null);
            }
            $data['relacionados'] = $this->conUrls($data['relacionados'] ?? []);

            return $this->successResponse($data, $data['producto']['nombre'] ?? 'Producto')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar la ficha del producto', ['id' => $id, 'error' => $e->getMessage()]);
            return $this->errorResponse('No se pudo cargar el producto', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }

    /**
     * El desplegable del encabezado.
     *
     * GET ecommerce/publico/buscador?q=barra+son
     *
     * CON MENOS DE DOS LETRAS NO SE BUSCA: se contesta vacío y con 200. No es
     * un error —todavía no se ha escrito nada que valga— y un 422 aquí haría
     * que la tienda pintara un fallo en la primera tecla.
     */
    public function buscador(Request $request)
    {
        $texto = trim((string) $request->query('q', ''));

        if (mb_strlen($texto) < self::LETRAS_MINIMAS) {
            return $this->successResponse([
                'texto'       => $texto,
                'total'       => 0,
                'productos'   => [],
                'sugerencias' => [],
            ], 'Buscador')->header('Cache-Control', 'no-cache');
        }

        try {
            // La clave es el texto ya normalizado: «Barra  SONIDO» y «barra
            // sonido» son la misma búsqueda y no merecen dos entradas.
            $clave = self::CACHE_PREFIJO . md5(mb_strtolower($texto));

            $data = Cache::remember($clave, now()->addMinutes(self::MINUTOS), function () use ($texto) {
                $fila = DB::selectOne(
                    'SELECT ecommerce.fn_tienda_buscador(?, ?) as result',
                    [$texto, self::EN_EL_DESPLEGABLE]
                );
                $data = json_decode($fila->result, true) ?: [];
                $data['productos'] = $this->conUrls($data['productos'] ?? []);
                return $data;
            });

            return $this->successResponse($data, 'Buscador')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo buscar', ['texto' => $texto, 'error' => $e->getMessage()]);
            return $this->errorResponse('No se pudo buscar', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }

    // ========================================================================

    /** Lo que llegó por la dirección, sin lo que no es de aquí. */
    private function filtrosDe(Request $request): array
    {
        $filtros = [];
        foreach (self::FILTROS as $clave) {
            $valor = $request->query($clave);
            if ($valor !== null && $valor !== '' && !is_array($valor)) {
                $filtros[$clave] = (string) $valor;
            }
        }
        return $filtros;
    }

    /** La búsqueda, con las direcciones de las fotos ya puestas. */
    private function buscar(array $filtros): array
    {
        $fila = DB::selectOne(
            'SELECT ecommerce.fn_tienda_productos(?::jsonb) as result',
            [json_encode($filtros, JSON_UNESCAPED_UNICODE)]
        );
        $data = json_decode($fila->result, true) ?: [];
        $data['productos'] = $this->conUrls($data['productos'] ?? []);
        return $data;
    }

    /**
     * La base guarda el nombre del fichero; la dirección se arma aquí.
     *
     * Las fotos de los productos están en `img/productos`, que es del catálogo
     * de Inventarios: las sube quien da de alta el producto, no quien arma la
     * tienda.
     */
    private function conUrls(array $productos): array
    {
        return array_map(function ($p) {
            $p['imagenes'] = array_values(array_filter(array_map(
                fn ($archivo) => $this->urlImagenDeProducto($archivo),
                is_array($p['imagenes'] ?? null) ? $p['imagenes'] : []
            )));
            return $p;
        }, $productos);
    }
}
