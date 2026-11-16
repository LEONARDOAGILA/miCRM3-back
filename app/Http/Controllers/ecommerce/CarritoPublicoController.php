<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use App\Http\Controllers\Controller;
use App\Http\Controllers\Concerns\ImagenesDelEcommerce;
use App\Http\Resources\ApiResponder;

/**
 * EL CARRITO DE LA TIENDA. SIN TOKEN DE SESIÓN.
 *
 *   GET    ecommerce/publico/carrito?token=…           lo que hay dentro
 *   POST   ecommerce/publico/carrito/agregar           { token?, producto_id, cantidad? }
 *   POST   ecommerce/publico/carrito/cantidad          { token, producto_id, cantidad }
 *   POST   ecommerce/publico/carrito/quitar            { token, producto_id }
 *   POST   ecommerce/publico/carrito/vaciar            { token }
 *
 * EL `token` NO ES UNA SESIÓN: es el identificador del carrito, y lo da el
 * servidor en el primer «agregar». La tienda lo guarda y lo manda en cada
 * llamada. Quien tenga ese token ve ese carrito y nada más: no abre ninguna
 * otra puerta, no identifica a nadie y no sirve para ninguna otra llamada.
 *
 * TODO VA POR POST, hasta quitar y vaciar. No es capricho: un DELETE con
 * cuerpo es terreno pantanoso —hay proxies y clientes que lo vacían— y aquí
 * el cuerpo lleva el token. Con POST no hay sorpresas.
 *
 * LOS PRECIOS NO VIAJAN HACIA ACÁ, sólo hacia allá: la tienda manda qué
 * producto y cuántos, y los importes los calcula la base con el catálogo de
 * ese momento (`fn_carrito_publico`). Un cliente no puede pedir un precio.
 *
 * SIN CACHÉ, al revés que el resto de lo público: el carrito es de UNA
 * persona y cambia en cada clic. Cachearlo sería enseñarle a alguien el
 * carrito de otro.
 */
class CarritoPublicoController extends Controller
{
    use ApiResponder;
    use ImagenesDelEcommerce;

    /** Lo que se le deja meter de una vez; la base vuelve a mirarlo. */
    private const MAX_CANTIDAD = 99;

    /**
     * Ver el carrito.
     *
     * Sin token —o con uno que ya no existe— se contesta un carrito vacío y
     * no se crea nada: quien abre la tienda y no agrega nada no deja fila.
     */
    public function ver(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $token = $this->token($request);
            if ($token === null) {
                return $this->successResponse($this->vacio(), 'Carrito vacío');
            }

            $result = DB::selectOne('SELECT ecommerce.fn_carrito_publico(?::UUID) as result', [$token]);
            return $this->successResponse($this->conImagenes(json_decode($result->result, true)), 'Carrito');
        });
    }

    /** Agregar un producto (suma a lo que ya hubiera de ése). */
    public function agregar(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $request->all();

            $producto = $this->entero($d['producto_id'] ?? null);
            if ($producto === null) {
                return $this->errorResponse('No se dijo qué producto agregar', 422);
            }

            $cantidad = $this->entero($d['cantidad'] ?? 1) ?? 1;
            $cantidad = max(1, min($cantidad, self::MAX_CANTIDAD));

            $result = DB::selectOne(
                'SELECT ecommerce.fn_carrito_agregar(?::UUID, ?::BIGINT, ?::INTEGER) as result',
                [$this->token($request), $producto, $cantidad]
            );
            return $this->responder($result);
        });
    }

    /** Fijar la cantidad de una línea. Con 0 se quita. */
    public function cantidad(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $request->all();

            $token = $this->token($request);
            $producto = $this->entero($d['producto_id'] ?? null);
            $cantidad = $this->entero($d['cantidad'] ?? null);

            if ($token === null || $producto === null || $cantidad === null) {
                return $this->errorResponse('Falta el carrito, el producto o la cantidad', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_carrito_cantidad(?::UUID, ?::BIGINT, ?::INTEGER) as result',
                [$token, $producto, min($cantidad, self::MAX_CANTIDAD)]
            );
            return $this->responder($result);
        });
    }

    /** Quitar una línea entera. */
    public function quitar(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $token = $this->token($request);
            $producto = $this->entero($request->all()['producto_id'] ?? null);

            if ($token === null || $producto === null) {
                return $this->errorResponse('Falta el carrito o el producto', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_carrito_quitar(?::UUID, ?::BIGINT) as result',
                [$token, $producto]
            );
            return $this->responder($result);
        });
    }

    /** Dejarlo vacío, sin borrar el carrito: el token sigue sirviendo. */
    public function vaciar(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $token = $this->token($request);
            if ($token === null) {
                return $this->errorResponse('Falta el carrito', 422);
            }

            $result = DB::selectOne('SELECT ecommerce.fn_carrito_vaciar(?::UUID) as result', [$token]);
            return $this->responder($result);
        });
    }

    // ================================================================
    // LO DE DENTRO
    // ================================================================

    /**
     * El token del carrito, si viene y si tiene forma de uuid.
     *
     * SE COMPRUEBA LA FORMA AQUÍ para que un `token=hola` no llegue a la base
     * como un cast que revienta: con algo que no es un uuid, la respuesta es
     * «no hay carrito», que es la verdad.
     */
    private function token(Request $request): ?string
    {
        $valor = trim((string) ($request->input('token') ?? ''));
        if ($valor === '') {
            return null;
        }
        return preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $valor)
            ? strtolower($valor)
            : null;
    }

    private function entero($valor): ?int
    {
        if ($valor === null || $valor === '' || !is_numeric($valor)) {
            return null;
        }
        return (int) $valor;
    }

    /** Un carrito que no existe, con la misma forma que uno de verdad. */
    private function vacio(): array
    {
        return [
            'token'   => null,
            'items'   => [],
            'totales' => ['lineas' => 0, 'unidades' => 0, 'subtotal' => 0,
                          'iva' => 0, 'total' => 0, 'avisos' => 0],
        ];
    }

    /**
     * La dirección de cada foto, armada aquí.
     *
     * En la base va el NOMBRE del fichero, como con el resto de imágenes del
     * catálogo; la tienda recibe la dirección hecha y no tiene que saber
     * dónde viven.
     */
    private function conImagenes(?array $carrito): array
    {
        if (!is_array($carrito)) {
            return $this->vacio();
        }

        // SE RECORRE LA LISTA DE VERDAD, no `$carrito['items'] ?? []`: con el
        // `??` delante, PHP hace una copia temporal y la referencia del
        // foreach escribe en ESA copia. El carrito salía con el nombre del
        // fichero en vez de la dirección y la tienda enseñaba el hueco.
        if (!isset($carrito['items']) || !is_array($carrito['items'])) {
            return $carrito;
        }

        foreach ($carrito['items'] as &$item) {
            $item['imagen'] = $this->urlImagenDeProducto($item['imagen'] ?? null);
        }
        unset($item);

        return $carrito;
    }

    private function responder($result)
    {
        $r = json_decode($result->result, true);
        return $this->successResponse(
            $this->conImagenes($r['data'] ?? null),
            $r['message'] ?? 'Carrito'
        );
    }

    /**
     * Los errores de negocio de la base salen con su mensaje.
     *
     * Son mensajes escritos para que los lea un cliente de la tienda («Ese
     * producto ya no está a la venta»), así que se enseñan tal cual. Lo que
     * no se reconoce se contesta en genérico y se apunta en el registro: el
     * visitante no tiene por qué leer un error de PostgreSQL.
     */
    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            $sqlState = $e->errorInfo[0] ?? null;
            if (in_array($sqlState, ['P0013', 'P0015'], true)) {
                $mensaje = preg_replace('/^.*?ERROR:\s*/s', '', $e->errorInfo[2] ?? '');
                $mensaje = preg_split('/\R\s*(CONTEXT|CONTEXTO|DETALLE|DETAIL|HINT):/', $mensaje)[0];
                return $this->errorResponse(trim($mensaje), 422);
            }
            sistemaLog('error', 'Error en el carrito de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse('No se pudo actualizar el carrito', 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en el carrito de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse('No se pudo actualizar el carrito', 500);
        }
    }
}
