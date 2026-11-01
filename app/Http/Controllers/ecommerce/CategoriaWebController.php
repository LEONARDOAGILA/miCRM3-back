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
 * LAS CATEGORÍAS DE LA TIENDA (ecommerce.categorias_web).
 *
 * El árbol es el del catálogo (inventarios.categorias). Lo que se administra
 * aquí es sólo lo que la tienda hace DISTINTO con él: qué ramas no salen, con
 * qué nombre se enseñan y QUÉ IMAGEN LES TOCA HOY.
 *
 * AQUÍ NO SE CREA, NI SE BORRA, NI SE REORDENA una categoría: eso es de
 * Inventarios. Mezclarlo daría dos sitios para cambiar el árbol y dos formas
 * de dejarlo inconsistente.
 *
 * LA LISTA TRAE EL PORQUÉ DE CADA ESTADO, que es lo que la hace útil: no es lo
 * mismo «la apagaste» que «no tiene ninguna categoría de producto debajo»,
 * porque la primera se arregla aquí y la segunda en el catálogo.
 *
 * LAS IMÁGENES SE PROGRAMAN POR FECHAS. Una categoría puede tener varias
 * preparadas —la de siempre, la de navidad, la del día de la madre— y la
 * tienda enseña la que toque hoy sin que nadie se acuerde de cambiarla. Y
 * programar una imagen es además lo que mete la categoría en el mosaico de la
 * portada: una sola decisión, no dos.
 *
 *   GET    ecommerce/categoriaWeb/allCategoriasWeb
 *   POST   ecommerce/categoriaWeb/editCategoriaWeb/{id}      { oculta?, nombre_web? }
 *
 *   GET    ecommerce/categoriaWeb/imagenesCuentas
 *   GET    ecommerce/categoriaWeb/imagenes/{categoria}
 *   POST   ecommerce/categoriaWeb/addImagen/{categoria}      multipart: imagen + nombre?, desde?, hasta?, activo?
 *   POST   ecommerce/categoriaWeb/editImagen/{categoria}/{id}  multipart; sin fichero, se queda el que tenía
 *   POST   ecommerce/categoriaWeb/activarImagen/{id}         { activo? }; sin ella, alterna
 *   POST   ecommerce/categoriaWeb/ordenarImagenes            { ids: [...] }
 *   DELETE ecommerce/categoriaWeb/deleteImagen/{id}
 *   GET    ecommerce/categoriaWeb/papeleraImagenes/{categoria}
 *   POST   ecommerce/categoriaWeb/restaurarImagenes          { ids: [...] }
 *   POST   ecommerce/categoriaWeb/vaciarImagenes/{categoria}
 */
class CategoriaWebController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ImagenesDelEcommerce;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,
        'P0013' => 404,
        'P0015' => 422,
        'P0016' => 422,
        'P0019' => 404,
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

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

    /** El árbol entero con su estado. Son treinta y tres: no hay que paginar. */
    public function allCategoriasWeb()
    {
        try {
            $r = json_decode(DB::selectOne('SELECT ecommerce.fn_categorias_web_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allCategoriasWeb', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function editCategoriaWeb(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);

            // Las dos marcas van al final y SÓLO SI VIENEN: sin ellas la
            // función se queda con lo que ya había, para que quien sólo
            // cambia el nombre no desmarque la categoría sin querer.
            $marca = function (array $d, string $campo) {
                return array_key_exists($campo, $d) && $d[$campo] !== null
                    ? filter_var($d[$campo], FILTER_VALIDATE_BOOLEAN) : null;
            };

            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_web_guardar(?::BIGINT, ?::BOOLEAN, ?::VARCHAR, '
                . self::CASTS_AUDIT . ', ?::BOOLEAN, ?::BOOLEAN) as result',
                array_merge([
                    (int) $id,
                    array_key_exists('oculta', $d) ? (bool) $d['oculta'] : false,
                    isset($d['nombre_web']) && trim((string) $d['nombre_web']) !== ''
                        ? trim((string) $d['nombre_web']) : null,
                ], $this->auditoria($request), [
                    $marca($d, 'destacada'),
                    $marca($d, 'promocion'),
                ])
            );
            $r = json_decode($result->result, true);

            // Lo que ve la tienda cambia: si no se tira la caché, el cambio
            // tarda hasta diez minutos en salir y parece que no se guardó. La
            // portada también, que es donde salen las destacadas.
            CategoriaWebPublicoController::limpiar();
            InicioPublicoController::limpiar();

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editCategoriaWeb', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * El orden de los círculos de la portada.
     *
     * LLEGA ENTERO: tienen que venir todas las destacadas. Mandar «ésta ahora
     * es la primera» obligaría a recalcular aquí lo que en la pantalla ya
     * está resuelto, y deja huecos en cuanto dos personas tocan a la vez.
     */
    public function ordenarDestacadas(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, ['ids' => 'required|array|min:1', 'ids.*' => 'integer']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_destacadas_ordenar(?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($d['ids']))], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            CategoriaWebPublicoController::limpiar();
            InicioPublicoController::limpiar();

            return $this->successResponse($r['data'], $r['message']);
        });
    }

    /**
     * El orden de las tarjetas de «Categorías en promoción».
     *
     * LLEGA ENTERO: tienen que venir todas las que están en promoción.
     */
    public function ordenarPromocion(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, ['ids' => 'required|array|min:1', 'ids.*' => 'integer']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_promocion_ordenar(?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($d['ids']))], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            CategoriaWebPublicoController::limpiar();
            InicioPublicoController::limpiar();

            return $this->successResponse($r['data'], $r['message']);
        });
    }

    /**
     * El orden de las categorías en el MENÚ de la tienda, dentro de UNA rama.
     *
     * No hacen falta todas las hermanas: las que no salen en la tienda no
     * están en la pantalla, y exigirlas haría imposible ordenar las que sí.
     * Lo que sí se exige es que todas sean del mismo padre, porque un orden
     * que mezcle ramas no significa nada.
     */
    public function ordenarCategorias(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, ['ids' => 'required|array|min:1', 'ids.*' => 'integer']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_web_ordenar(?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($d['ids']))], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            CategoriaWebPublicoController::limpiar();
            InicioPublicoController::limpiar();

            return $this->successResponse($r['data'], $r['message']);
        });
    }

    // ================================================================
    // LAS IMÁGENES DE UNA CATEGORÍA
    // ================================================================

    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en las imágenes de categoría', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** La base guarda el nombre del fichero; la dirección se arma aquí. */
    private function conUrl(?array $data): ?array
    {
        if ($data === null) {
            return null;
        }
        $data['imagenes'] = array_map(function ($i) {
            $i['imagen_url'] = $this->urlImagenEcommerce($i['imagen'] ?? null);
            return $i;
        }, $data['imagenes'] ?? []);

        return $data;
    }

    /**
     * Responde y tira la caché de la portada.
     *
     * LA DE LA PORTADA TAMBIÉN, y no sólo la de las categorías: el mosaico
     * del inicio se arma con estas imágenes, así que cambiar una sin tirar
     * esa caché deja el cambio sin salir y pareciendo que no se guardó.
     */
    private function responderImagenes($result)
    {
        $r = json_decode($result->result, true);

        CategoriaWebPublicoController::limpiar();
        InicioPublicoController::limpiar();

        return $this->successResponse($this->conUrl($r['data'] ?? null), $r['message'] ?? 'Imágenes');
    }

    /** Cuántas imágenes tiene cada categoría: es la chapita del árbol. */
    public function imagenesCuentas()
    {
        return $this->ejecutar(function () {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_categorias_imagenes_cuentas() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function imagenes($categoria)
    {
        return $this->ejecutar(function () use ($categoria) {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_categorias_imagenes_listar(?::BIGINT) as result',
                [(int) $categoria])->result, true);

            return $this->successResponse($this->conUrl($r['data'] ?? null), $r['message']);
        });
    }

    public function addImagen(Request $request, $categoria)
    {
        return $this->guardarImagen($request, (int) $categoria, null);
    }

    public function editImagen(Request $request, $categoria, $id)
    {
        return $this->guardarImagen($request, (int) $categoria, (int) $id);
    }

    /**
     * Crea o modifica una imagen programada.
     *
     * EL FICHERO SÓLO HACE FALTA AL CREAR. Al modificar, cambiar las fechas o
     * el nombre no debería obligar a volver a subir la misma foto, así que
     * sin fichero se queda el que ya tenía.
     *
     * EL FICHERO VIEJO SE BORRA al reemplazarlo, pero sólo si ninguna otra
     * fila lo usa: la misma imagen puede estar programada en dos categorías.
     */
    private function guardarImagen(Request $request, int $categoria, ?int $id)
    {
        return $this->ejecutar(function () use ($request, $categoria, $id) {
            $validator = Validator::make($request->all(), [
                'nombre' => 'nullable|string|max:100',
                'desde'  => 'nullable|string|max:30',
                'hasta'  => 'nullable|string|max:30',
                'activo' => 'nullable|boolean',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $anterior = $id
                ? DB::selectOne('SELECT imagen FROM ecommerce.categorias_imagenes
                                  WHERE id = ? AND categoria_id = ? AND deleted_at IS NULL',
                                [$id, $categoria])
                : null;

            if ($id && !$anterior) {
                return $this->errorResponse('La imagen no existe en esta categoría', 404);
            }

            $fichero = $anterior->imagen ?? null;

            if ($request->hasFile('imagen')) {
                [$nuevo, $error] = $this->guardarImagenEcommerce($request->file('imagen'));
                if ($error !== null) {
                    return $this->errorResponse($error, 422);
                }
                $fichero = $nuevo;
            } elseif ($fichero === null) {
                return $this->errorResponse('Hace falta la imagen', 422);
            }

            $datos = [
                'imagen' => $fichero,
                'nombre' => $request->input('nombre'),
                'desde'  => $request->input('desde'),
                'hasta'  => $request->input('hasta'),
                'activo' => filter_var($request->input('activo', true), FILTER_VALIDATE_BOOLEAN),
            ];

            try {
                $result = DB::selectOne(
                    'SELECT ecommerce.fn_categorias_imagenes_guardar(?::BIGINT, ?::BIGINT, ?::JSONB, '
                    . self::CASTS_AUDIT . ') as result',
                    array_merge([$id, $categoria, json_encode($datos)], $this->auditoria($request))
                );
            } catch (QueryException $e) {
                // El fichero que se acababa de subir se queda huérfano si la
                // fila no llegó a guardarse: fuera.
                if ($request->hasFile('imagen')) {
                    $this->borrarImagenEcommerce($fichero);
                }
                throw $e;
            }

            // El de antes, si lo reemplazaron y no lo usa nadie más
            if ($anterior && $request->hasFile('imagen') && $anterior->imagen !== $fichero) {
                $enUso = DB::selectOne('SELECT count(*) as n FROM ecommerce.categorias_imagenes
                                         WHERE imagen = ?', [$anterior->imagen]);
                if ((int) ($enUso->n ?? 0) === 0) {
                    $this->borrarImagenEcommerce($anterior->imagen);
                }
            }

            sistemaLog('info', 'Imagen de categoría guardada', ['categoria' => $categoria, 'id' => $id]);
            return $this->responderImagenes($result);
        });
    }

    public function activarImagen(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            // Sin `activo`, alterna. Es lo que hace el interruptor de la lista.
            $activo = $request->exists('activo') && $request->input('activo') !== null
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN) : null;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_imagenes_activar(?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            return $this->responderImagenes($result);
        });
    }

    public function ordenarImagenes(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $validator = Validator::make($request->all(),
                ['ids' => 'required|array|min:1', 'ids.*' => 'integer']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_imagenes_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($request->input('ids')))], $this->auditoria($request))
            );
            return $this->responderImagenes($result);
        });
    }

    public function deleteImagen(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_imagenes_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Imagen de categoría a la papelera', ['id' => (int) $id]);
            return $this->responderImagenes($result);
        });
    }

    public function papeleraImagenes($categoria)
    {
        return $this->ejecutar(function () use ($categoria) {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_categorias_imagenes_papelera(?::BIGINT) as result',
                [(int) $categoria])->result, true);

            $data = array_map(function ($i) {
                $i['imagen_url'] = $this->urlImagenEcommerce($i['imagen'] ?? null);
                return $i;
            }, $r['data'] ?? []);

            return $this->successResponse($data, $r['message']);
        });
    }

    public function restaurarImagenes(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $validator = Validator::make($request->all(),
                ['ids' => 'required|array|min:1', 'ids.*' => 'integer']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_imagenes_restaurar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($request->input('ids')))], $this->auditoria($request))
            );
            return $this->responderImagenes($result);
        });
    }

    /**
     * Vacía la papelera DE ESTA CATEGORÍA y borra sus ficheros.
     *
     * ES EL ÚNICO SITIO DONDE SE BORRA UN FICHERO. Mientras la fila se pueda
     * restaurar, su imagen tiene que seguir ahí; aquí ya no se vuelve. La
     * función devuelve sólo los ficheros que no usa ninguna otra fila.
     */
    public function vaciarImagenes(Request $request, $categoria)
    {
        return $this->ejecutar(function () use ($request, $categoria) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_imagenes_vaciar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $categoria], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            foreach (($r['data']['ficheros'] ?? []) as $f) {
                $this->borrarImagenEcommerce($f);
            }

            CategoriaWebPublicoController::limpiar();
            InicioPublicoController::limpiar();

            sistemaLog('info', 'Papelera de imágenes vaciada', ['categoria' => (int) $categoria]);
            return $this->successResponse($this->conUrl($r['data']['categoria'] ?? null), $r['message']);
        });
    }
}
