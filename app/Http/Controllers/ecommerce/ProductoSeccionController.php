<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * SECCIONES DE PRODUCTOS.
 *
 * Una sección es una lista con nombre —«Los más vendidos», «Ofertas de
 * navidad»— y los productos que marketing mete en ella. No es una categoría
 * ni una marca: ésas las decide quien da de alta el producto, y una sección
 * la decide quien vende, juntando cosas que el catálogo no junta.
 *
 * CREAR UNA SECCIÓN LA PONE EN LA PORTADA. Cada escaparate es también una
 * fila de `inicio_secciones`, al final y encendida, y desde «Inicio de la
 * tienda» se le da su orden, su rótulo, su alto y sus fechas como a las cinco
 * de siempre. Mandarla a la papelera la quita de la portada y restaurarla la
 * devuelve con todo eso puesto; de eso se encargan las funciones de la base,
 * para que no haya que acordarse aquí.
 *
 * EL CATÁLOGO NO SE SIRVE DESDE AQUÍ. La rejilla del medio de la pantalla
 * pide los productos a `inventarios/producto/allProductos`, la misma que usa
 * la pantalla de productos: paginación, buscador, marcas, categorías por rama
 * y los dos rangos ya están resueltos allí, y duplicarlos aquí sería tener
 * dos listados que un día dejan de traer lo mismo.
 *
 * LA ASIGNACIÓN POR FILTRO VA A LA BASE CON EL FILTRO, NO CON LOS IDS. El
 * navegador sólo tiene la página que está viendo; «mete las 340 que cumplen
 * esto» lo resuelve la base llamando a esa misma función de listado. Así
 * «agregar todo lo que se ve» es verdad por construcción, y no hay que
 * mandar trescientos ids por la red.
 *
 *   GET    ecommerce/productoSeccion/allSecciones
 *   POST   ecommerce/productoSeccion/addSeccion            { nombre, desde?, hasta? }
 *   POST   ecommerce/productoSeccion/editSeccion/{id}      { nombre, desde?, hasta? }
 *   POST   ecommerce/productoSeccion/activarSeccion/{id}   { activo? }; sin ella, alterna
 *   POST   ecommerce/productoSeccion/ordenarSecciones      { ids: [...] }
 *   DELETE ecommerce/productoSeccion/deleteSeccion/{id}
 *
 *   GET    ecommerce/productoSeccion/papeleraSecciones
 *   POST   ecommerce/productoSeccion/restaurarSeccion/{id}
 *
 *   GET    ecommerce/productoSeccion/productos/{id}        las fichas completas
 *   GET    ecommerce/productoSeccion/ids/{id}              sólo los ids, para marcar la rejilla
 *   POST   ecommerce/productoSeccion/agregar/{id}          { producto_ids: [...] }
 *   POST   ecommerce/productoSeccion/quitar/{id}           { producto_ids: [...] }
 *   POST   ecommerce/productoSeccion/ordenar/{id}          { producto_ids: [...] }
 *   POST   ecommerce/productoSeccion/agregarFiltro/{id}    { search?, marca_ids?, categoria_ids?,
 *                                                            filtros?, precio_min?… }
 */
class ProductoSeccionController extends Controller
{
    use ApiResponder;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0006' => 409,   // ya existe una sección con ese nombre
        'P0013' => 404,   // la sección o el producto no existe
        'P0015' => 422,   // valor inválido
        'P0019' => 404,   // no está en la papelera
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    /** Los cuatro extremos del panel de filtros, tal como los manda la pantalla. */
    private const RANGOS = ['precio_min', 'precio_max', 'costo_min', 'costo_max'];

    public function __construct()
    {
        $this->middleware('auth:api');
    }

    private function traducirErrorPostgres(QueryException $e): array
    {
        $sqlState = $e->errorInfo[0] ?? null;
        if (!isset(self::ERRORES_NEGOCIO[$sqlState])) {
            return ['Ocurrió un error al procesar la solicitud', 500];
        }
        $mensaje = $e->errorInfo[2] ?? $e->getMessage();
        $mensaje = preg_replace('/^.*?ERROR:\s*/s', '', $mensaje);
        $mensaje = preg_split('/\R\s*(CONTEXT|CONTEXTO|DETALLE|DETAIL|HINT):/', $mensaje)[0];
        return [trim($mensaje), self::ERRORES_NEGOCIO[$sqlState]];
    }

    private function auditoria(Request $request): array
    {
        $u = auth('api')->user();
        return [
            isset($u->id) ? (int) $u->id : null,
            $u->login_user ?? null,
            trim(($u->name ?? '') . ' ' . ($u->surname ?? '')) ?: null,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid(),
        ];
    }

    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    private function responder($result)
    {
        $r = json_decode($result->result, true);

        // Lo que ve la tienda cambia con cualquiera de estas acciones, y no
        // sólo al crear o borrar una sección: meterle un producto cambia lo
        // que se pinta en la portada igual que renombrarla. La portada pública
        // se guarda un minuto, así que sin esto se queda enseñando la lista de
        // antes y parece que el cambio no se guardó.
        InicioPublicoController::limpiar();

        return $this->successResponse($r['data'] ?? null, $r['message'] ?? 'Secciones de productos');
    }

    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en las secciones de productos', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * La lista de ids que llega del navegador, lista para la base.
     *
     * Se valida la FORMA aquí —que sea un array de números y no venga vacío—
     * porque es lo que el navegador puede equivocarse al armar. Que el
     * producto exista o ya esté dentro lo decide la base, que es la única que
     * lo sabe.
     */
    private function idsDe(array $datos, string $campo = 'producto_ids')
    {
        $validator = Validator::make($datos, [
            $campo     => 'required|array|min:1',
            $campo . '.*' => 'required|integer|min:1',
        ]);
        if ($validator->fails()) {
            return [null, $validator->errors()->first()];
        }
        // array_values: con una clave perdida, json_encode sacaría un objeto
        // («{"1":5}») y jsonb_array_elements_text reventaría.
        return [json_encode(array_values(array_map('intval', $datos[$campo]))), null];
    }

    /** Las fechas de vigencia: vacío es NULL, no cadena vacía. */
    private function fecha(array $datos, string $campo): ?string
    {
        $v = $datos[$campo] ?? null;
        return ($v === null || $v === '') ? null : (string) $v;
    }

    // ================================================================
    // LAS SECCIONES
    // ================================================================

    public function allSecciones()
    {
        return $this->ejecutar(function () {
            $r = json_decode(
                DB::selectOne('SELECT ecommerce.fn_producto_secciones_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function addSeccion(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, [
                'nombre' => 'required|string|min:2|max:80',
                'desde'  => 'nullable|string|max:30',
                'hasta'  => 'nullable|string|max:30',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_secciones_crear(?::VARCHAR, ?::TIMESTAMPTZ, ?::TIMESTAMPTZ, '
                . self::CASTS_AUDIT . ') as result',
                array_merge(
                    [(string) $d['nombre'], $this->fecha($d, 'desde'), $this->fecha($d, 'hasta')],
                    $this->auditoria($request))
            );

            sistemaLog('info', 'Sección de productos creada', ['nombre' => (string) $d['nombre']]);
            return $this->responder($result);
        });
    }

    public function editSeccion(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, [
                'nombre' => 'required|string|min:2|max:80',
                'desde'  => 'nullable|string|max:30',
                'hasta'  => 'nullable|string|max:30',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_secciones_modificar(?::BIGINT, ?::VARCHAR, '
                . '?::TIMESTAMPTZ, ?::TIMESTAMPTZ, ' . self::CASTS_AUDIT . ') as result',
                array_merge(
                    [(int) $id, (string) $d['nombre'], $this->fecha($d, 'desde'), $this->fecha($d, 'hasta')],
                    $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    public function activarSeccion(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            // Sin `activo`, alterna. Es lo que hace la palanca de la lista.
            $activo = array_key_exists('activo', $d) && $d['activo'] !== null
                ? filter_var($d['activo'], FILTER_VALIDATE_BOOLEAN) : null;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_secciones_activar(?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    public function ordenarSecciones(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            [$ids, $error] = $this->idsDe($this->datosDe($request), 'ids');
            if ($error) { return $this->errorResponse($error, 422); }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_secciones_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$ids], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    public function deleteSeccion(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_secciones_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Sección de productos a la papelera', ['seccion' => (int) $id]);
            return $this->responder($result);
        });
    }

    public function papeleraSecciones()
    {
        return $this->ejecutar(function () {
            $r = json_decode(
                DB::selectOne('SELECT ecommerce.fn_producto_secciones_papelera_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function restaurarSeccion(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_secciones_restaurar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    // ================================================================
    // LOS PRODUCTOS DE UNA SECCIÓN
    // ================================================================

    public function productos($id)
    {
        return $this->ejecutar(function () use ($id) {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_producto_seccion_productos(?::BIGINT) as result',
                [(int) $id])->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function ids($id)
    {
        return $this->ejecutar(function () use ($id) {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_producto_seccion_ids(?::BIGINT) as result',
                [(int) $id])->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function agregar(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            [$ids, $error] = $this->idsDe($this->datosDe($request));
            if ($error) { return $this->errorResponse($error, 422); }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_seccion_agregar(?::BIGINT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $ids], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    public function quitar(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            [$ids, $error] = $this->idsDe($this->datosDe($request));
            if ($error) { return $this->errorResponse($error, 422); }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_seccion_quitar(?::BIGINT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $ids], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    public function ordenar(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            [$ids, $error] = $this->idsDe($this->datosDe($request));
            if ($error) { return $this->errorResponse($error, 422); }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_seccion_ordenar(?::BIGINT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $ids], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    /**
     * Mete en la sección TODO lo que cumple el filtro del panel.
     *
     * El filtro viaja entero a la base y allí lo resuelve la misma función que
     * llena la rejilla. Aquí sólo se le da forma de jsonb: los cuatro rangos
     * sólo van si traen número —vacío es «sin tope por ese lado», no cero— y
     * las dos listas de ids se limpian a enteros.
     */
    public function agregarFiltro(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, [
                'search'          => 'nullable|string|max:200',
                'marca_ids'       => 'nullable|array',
                'marca_ids.*'     => 'integer|min:1',
                'categoria_ids'   => 'nullable|array',
                'categoria_ids.*' => 'integer|min:1',
                'filtros'         => 'nullable|array',
                'precio_min'      => 'nullable|numeric',
                'precio_max'      => 'nullable|numeric',
                'costo_min'       => 'nullable|numeric',
                'costo_max'       => 'nullable|numeric',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $filtro = [
                'search'        => (string) ($d['search'] ?? ''),
                'marca_ids'     => array_values(array_map('intval', $d['marca_ids'] ?? [])),
                'categoria_ids' => array_values(array_map('intval', $d['categoria_ids'] ?? [])),
                'filtros'       => is_array($d['filtros'] ?? null) ? $d['filtros'] : new \stdClass(),
            ];
            foreach (self::RANGOS as $k) {
                if (isset($d[$k]) && $d[$k] !== '') { $filtro[$k] = (float) $d[$k]; }
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_producto_seccion_agregar_filtro(?::BIGINT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, json_encode($filtro)], $this->auditoria($request))
            );

            sistemaLog('info', 'Asignación masiva a una sección de productos',
                       ['seccion' => (int) $id, 'filtro' => $filtro]);
            return $this->responder($result);
        });
    }
}
