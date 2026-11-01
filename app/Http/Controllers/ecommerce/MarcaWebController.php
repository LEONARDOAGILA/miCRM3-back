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
 * LAS MARCAS DE LA TIENDA (ecommerce.marcas_web).
 *
 * Lo mismo que las categorías, para las marcas: cuáles salen en la tienda,
 * con qué nombre, en qué orden y QUÉ IMAGEN LES TOCA HOY.
 *
 * EL CATÁLOGO ES DE INVENTARIOS: aquí no se crea, ni se borra, ni se renombra
 * una marca. Mezclarlo daría dos sitios para cambiar lo mismo y dos formas de
 * dejarlo inconsistente.
 *
 * LA IMAGEN PROGRAMADA MANDA SOBRE EL LOGO DEL CATÁLOGO. Una marca ya tiene
 * su logo y con eso sale; la imagen de aquí es para la campaña —el logo de
 * navidad, el del aniversario— y sólo mientras esté en fecha. Sin ninguna
 * programada se usa el de siempre, así que nadie tiene que volver a subir lo
 * que ya está.
 *
 * SON DOS CARPETAS: el logo del catálogo está en `img/marcas` y las imágenes
 * programadas en `img/ecommerce`. Por eso la dirección se arma aquí sabiendo
 * de cuál viene cada una.
 *
 *   GET    ecommerce/marcaWeb/allMarcasWeb
 *   POST   ecommerce/marcaWeb/editMarcaWeb/{id}        { oculta?, nombre_web? }
 *   POST   ecommerce/marcaWeb/ordenarMarcas            { ids: [...] }
 *
 *   GET    ecommerce/marcaWeb/imagenesCuentas
 *   GET    ecommerce/marcaWeb/imagenes/{marca}
 *   POST   ecommerce/marcaWeb/addImagen/{marca}        multipart: imagen + nombre?, desde?, hasta?, activo?
 *   POST   ecommerce/marcaWeb/editImagen/{marca}/{id}  multipart; sin fichero, se queda el que tenía
 *   POST   ecommerce/marcaWeb/activarImagen/{id}       { activo? }; sin ella, alterna
 *   POST   ecommerce/marcaWeb/ordenarImagenes          { ids: [...] }
 *   DELETE ecommerce/marcaWeb/deleteImagen/{id}
 *   GET    ecommerce/marcaWeb/papeleraImagenes/{marca}
 *   POST   ecommerce/marcaWeb/restaurarImagenes        { ids: [...] }
 *   POST   ecommerce/marcaWeb/vaciarImagenes/{marca}
 */
class MarcaWebController extends Controller
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

    // ================================================================
    // AYUDANTES
    // ================================================================

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

    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en las marcas de la tienda', ['message' => $e->getMessage()]);
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

    private function responderImagenes($result)
    {
        $r = json_decode($result->result, true);

        // La portada enseña estas marcas: sin tirar su caché el cambio tarda
        // un minuto en salir y parece que no se guardó.
        InicioPublicoController::limpiar();

        return $this->successResponse($this->conUrl($r['data'] ?? null), $r['message'] ?? 'Imágenes');
    }

    // ================================================================
    // LAS MARCAS
    // ================================================================

    public function allMarcasWeb()
    {
        return $this->ejecutar(function () {
            $r = json_decode(DB::selectOne('SELECT ecommerce.fn_marcas_web_listar() as result')->result, true);

            $data = array_map(function ($m) {
                $m['logo_url'] = $this->urlLogoDeMarca($m['logo'] ?? null);
                return $m;
            }, $r['data'] ?? []);

            return $this->successResponse($data, $r['message']);
        });
    }

    public function editMarcaWeb(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            $result = DB::selectOne(
                'SELECT ecommerce.fn_marcas_web_guardar(?::BIGINT, ?::BOOLEAN, ?::VARCHAR, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    array_key_exists('oculta', $d) ? (bool) $d['oculta'] : false,
                    isset($d['nombre_web']) && trim((string) $d['nombre_web']) !== ''
                        ? trim((string) $d['nombre_web']) : null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            InicioPublicoController::limpiar();

            $data = array_map(function ($m) {
                $m['logo_url'] = $this->urlLogoDeMarca($m['logo'] ?? null);
                return $m;
            }, $r['data'] ?? []);

            return $this->successResponse($data, $r['message']);
        });
    }

    /**
     * El orden de «Nuestras marcas».
     *
     * LLEGA ENTERO: tienen que venir todas las que salen en la tienda.
     */
    public function ordenarMarcas(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, ['ids' => 'required|array|min:1', 'ids.*' => 'integer']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_marcas_web_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($d['ids']))], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            InicioPublicoController::limpiar();

            $data = array_map(function ($m) {
                $m['logo_url'] = $this->urlLogoDeMarca($m['logo'] ?? null);
                return $m;
            }, $r['data'] ?? []);

            return $this->successResponse($data, $r['message']);
        });
    }

    // ================================================================
    // LAS IMÁGENES DE UNA MARCA
    // ================================================================

    public function imagenesCuentas()
    {
        return $this->ejecutar(function () {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_marcas_imagenes_cuentas() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function imagenes($marca)
    {
        return $this->ejecutar(function () use ($marca) {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_marcas_imagenes_listar(?::BIGINT) as result',
                [(int) $marca])->result, true);

            return $this->successResponse($this->conUrl($r['data'] ?? null), $r['message']);
        });
    }

    public function addImagen(Request $request, $marca)
    {
        return $this->guardarImagen($request, (int) $marca, null);
    }

    public function editImagen(Request $request, $marca, $id)
    {
        return $this->guardarImagen($request, (int) $marca, (int) $id);
    }

    /**
     * Crea o modifica una imagen programada.
     *
     * EL FICHERO SÓLO HACE FALTA AL CREAR: cambiar las fechas o el nombre no
     * debería obligar a volver a subir la misma imagen.
     */
    private function guardarImagen(Request $request, int $marca, ?int $id)
    {
        return $this->ejecutar(function () use ($request, $marca, $id) {
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
                ? DB::selectOne('SELECT imagen FROM ecommerce.marcas_imagenes
                                  WHERE id = ? AND marca_id = ? AND deleted_at IS NULL', [$id, $marca])
                : null;

            if ($id && !$anterior) {
                return $this->errorResponse('La imagen no existe en esta marca', 404);
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
                    'SELECT ecommerce.fn_marcas_imagenes_guardar(?::BIGINT, ?::BIGINT, ?::JSONB, '
                    . self::CASTS_AUDIT . ') as result',
                    array_merge([$id, $marca, json_encode($datos)], $this->auditoria($request))
                );
            } catch (QueryException $e) {
                // El fichero recién subido se queda huérfano si la fila no
                // llegó a guardarse: fuera.
                if ($request->hasFile('imagen')) {
                    $this->borrarImagenEcommerce($fichero);
                }
                throw $e;
            }

            // El de antes, si lo reemplazaron y no lo usa nadie más. Se mira
            // también en las de categorías: la misma imagen puede estar
            // programada en las dos.
            if ($anterior && $request->hasFile('imagen') && $anterior->imagen !== $fichero) {
                $enUso = DB::selectOne(
                    'SELECT (SELECT count(*) FROM ecommerce.marcas_imagenes WHERE imagen = ?)
                          + (SELECT count(*) FROM ecommerce.categorias_imagenes WHERE imagen = ?) as n',
                    [$anterior->imagen, $anterior->imagen]
                );
                if ((int) ($enUso->n ?? 0) === 0) {
                    $this->borrarImagenEcommerce($anterior->imagen);
                }
            }

            sistemaLog('info', 'Imagen de marca guardada', ['marca' => $marca, 'id' => $id]);
            return $this->responderImagenes($result);
        });
    }

    public function activarImagen(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $activo = $request->exists('activo') && $request->input('activo') !== null
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN) : null;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_marcas_imagenes_activar(?::BIGINT, ?::BOOLEAN, '
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
                'SELECT ecommerce.fn_marcas_imagenes_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($request->input('ids')))], $this->auditoria($request))
            );
            return $this->responderImagenes($result);
        });
    }

    public function deleteImagen(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_marcas_imagenes_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Imagen de marca a la papelera', ['id' => (int) $id]);
            return $this->responderImagenes($result);
        });
    }

    public function papeleraImagenes($marca)
    {
        return $this->ejecutar(function () use ($marca) {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_marcas_imagenes_papelera(?::BIGINT) as result',
                [(int) $marca])->result, true);

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
                'SELECT ecommerce.fn_marcas_imagenes_restaurar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($request->input('ids')))], $this->auditoria($request))
            );
            return $this->responderImagenes($result);
        });
    }

    /**
     * Vacía la papelera DE ESTA MARCA y borra sus ficheros.
     *
     * ES EL ÚNICO SITIO DONDE SE BORRA UN FICHERO. La función devuelve sólo
     * los que no usa ninguna otra fila, ni de marcas ni de categorías.
     */
    public function vaciarImagenes(Request $request, $marca)
    {
        return $this->ejecutar(function () use ($request, $marca) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_marcas_imagenes_vaciar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $marca], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            foreach (($r['data']['ficheros'] ?? []) as $f) {
                $this->borrarImagenEcommerce($f);
            }

            InicioPublicoController::limpiar();

            sistemaLog('info', 'Papelera de imágenes de marca vaciada', ['marca' => (int) $marca]);
            return $this->successResponse($this->conUrl($r['data']['marca'] ?? null), $r['message']);
        });
    }
}
