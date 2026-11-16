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
 * LAS GALERÍAS DE LA TIENDA (administración).
 *
 * Una galería es un SITIO del diseño con su clave fija —`inicio_banner`,
 * `pagos_tarjetas`, `beneficios_fotos`— y lo que se administra aquí son
 * las imágenes que van ahí: cuáles, en qué orden, a dónde llevan y entre qué
 * fechas se ven.
 *
 * NO SE CREAN NI SE BORRAN GALERÍAS, igual que las secciones de la portada:
 * cada una existe porque la tienda sabe pintarla, y una clave nueva sin
 * código que la pinte sería un hueco que no aparece en ninguna parte.
 *
 * EL FICHERO NO SE SUBE AQUÍ: se elige de la biblioteca compartida
 * (ecommerce/imagen). En la base va sólo el nombre y la dirección se arma al
 * leer, así que si llega una dirección entera —porque el front devuelve lo
 * que leyó— se le quita el servidor antes de guardar.
 *
 * TODO DEVUELVE LA GALERÍA ENTERA: añadir o quitar una imagen cambia el orden
 * de las demás, y recomponerlo en la pantalla es como se acaban viendo dos
 * cosas distintas.
 *
 *   GET    ecommerce/galeria/allGalerias
 *   GET    ecommerce/galeria/getGaleria/{clave}
 *   POST   ecommerce/galeria/addImagen/{clave}            { imagen, enlace?, … }
 *   POST   ecommerce/galeria/editImagen/{clave}/{id}
 *   POST   ecommerce/galeria/activarImagen/{id}           { activo? }; sin ella, alterna
 *   POST   ecommerce/galeria/ordenarImagenes              { ids: [...] }
 *   DELETE ecommerce/galeria/deleteImagen/{id}
 *   GET    ecommerce/galeria/papelera/{clave}
 *   POST   ecommerce/galeria/restaurar                    { ids: [...] }
 *   POST   ecommerce/galeria/vaciarPapelera/{clave}
 */
class GaleriaController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ArchivosDeLaTienda;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0013' => 404,   // la galería o la imagen no existen
        'P0015' => 422,   // valor inválido
        'P0016' => 422,   // el orden no corresponde a esta galería
        'P0019' => 404,   // no está en la papelera
        'P0021' => 409,   // no caben más
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

    /** La base guarda el nombre del fichero; la dirección se arma aquí. */
    private function conUrl(?array $data): ?array
    {
        if ($data === null) {
            return null;
        }
        $data['imagenes'] = array_map(function ($i) {
            $i['imagen_url']       = $this->urlArchivo($i['imagen'] ?? null, 'imagenes');
            $i['imagen_movil_url'] = $this->urlArchivo($i['imagen_movil'] ?? null, 'imagenes');
            return $i;
        }, $data['imagenes'] ?? []);

        return $data;
    }

    /**
     * Responde y tira las dos cachés que acaban de quedarse viejas.
     *
     * LA DE LA PORTADA TAMBIÉN, y no sólo la de la galería: los dos banners
     * del inicio van dentro de la respuesta de la portada, así que cambiar
     * una imagen sin tirar esa caché deja el cambio sin salir hasta un minuto
     * después y parece que no se guardó.
     */
    private function responder($result, ?string $clave)
    {
        $r = json_decode($result->result, true);
        $data = $r['data'] ?? null;

        $clave = $clave ?: ($data['clave'] ?? null);
        if ($clave) {
            GaleriaPublicoController::limpiar($clave);
        }
        InicioPublicoController::limpiar();

        return $this->successResponse($this->conUrl($data), $r['message'] ?? 'Galería');
    }

    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en las galerías', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // LEER
    // ================================================================

    public function allGalerias()
    {
        return $this->ejecutar(function () {
            $r = json_decode(DB::selectOne('SELECT ecommerce.fn_galerias_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function getGaleria($clave)
    {
        return $this->ejecutar(function () use ($clave) {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_galerias_obtener(?::TEXT) as result', [(string) $clave])->result, true);

            return $this->successResponse($this->conUrl($r['data'] ?? null), $r['message']);
        });
    }

    // ================================================================
    // LAS IMÁGENES
    // ================================================================

    public function addImagen(Request $request, $clave)
    {
        return $this->guardarImagen($request, (string) $clave, null);
    }

    public function editImagen(Request $request, $clave, $id)
    {
        return $this->guardarImagen($request, (string) $clave, (int) $id);
    }

    private function guardarImagen(Request $request, string $clave, ?int $id)
    {
        return $this->ejecutar(function () use ($request, $clave, $id) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, [
                'imagen'        => 'required|string|max:200',
                'imagen_movil'  => 'nullable|string|max:200',
                'nombre'        => 'nullable|string|max:100',
                'enlace'        => 'nullable|string|max:250',
                'nueva_pestana' => 'nullable|boolean',
                'mostrar_en'    => 'nullable|string|in:todos,computadora,celular',
                'titulo'        => 'nullable|string|max:40',
                'subtitulo'     => 'nullable|string|max:80',
                'color'         => 'nullable|string|max:10',
                'boton'         => 'nullable|string|max:20',
                'desde'         => 'nullable|string|max:30',
                'hasta'         => 'nullable|string|max:30',
                'activo'        => 'nullable|boolean',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            // Pueden llegar como dirección completa —la que devolvió una
            // lectura anterior— o como nombre suelto: se queda el nombre.
            $d['imagen'] = $this->nombreDeArchivo($d['imagen'] ?? null);
            $d['imagen_movil'] = $this->nombreDeArchivo($d['imagen_movil'] ?? null);

            $result = DB::selectOne(
                'SELECT ecommerce.fn_galerias_imagenes_guardar(?::BIGINT, ?::TEXT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([$id, $clave, json_encode($d)], $this->auditoria($request))
            );

            sistemaLog('info', 'Imagen de galería guardada', ['galeria' => $clave, 'id' => $id]);
            return $this->responder($result, $clave);
        });
    }

    public function activarImagen(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            // Sin `activo`, alterna. Es lo que hace el interruptor de la lista.
            $activo = array_key_exists('activo', $d) && $d['activo'] !== null
                ? filter_var($d['activo'], FILTER_VALIDATE_BOOLEAN) : null;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_galerias_imagenes_activar(?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            return $this->responder($result, null);
        });
    }

    public function ordenarImagenes(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, ['ids' => 'required|array|min:1', 'ids.*' => 'integer']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_galerias_imagenes_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($d['ids']))], $this->auditoria($request))
            );
            return $this->responder($result, null);
        });
    }

    public function deleteImagen(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_galerias_imagenes_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Imagen quitada de una galería', ['id' => (int) $id]);
            return $this->responder($result, null);
        });
    }

    // ================================================================
    // LA PAPELERA, POR GALERÍA
    // ================================================================

    public function papelera($clave)
    {
        return $this->ejecutar(function () use ($clave) {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_galerias_papelera_listar(?::TEXT) as result', [(string) $clave])->result, true);

            $data = array_map(function ($i) {
                $i['imagen_url'] = $this->urlArchivo($i['imagen'] ?? null, 'imagenes');
                return $i;
            }, $r['data'] ?? []);

            return $this->successResponse($data, $r['message']);
        });
    }

    public function restaurar(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, ['ids' => 'required|array|min:1', 'ids.*' => 'integer']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_galerias_papelera_restaurar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($d['ids']))], $this->auditoria($request))
            );
            return $this->responder($result, null);
        });
    }

    /**
     * Vacía la papelera DE ESTA GALERÍA.
     *
     * Lleva clave a propósito: un «vaciar» que se llevara la papelera de
     * todas las galerías de una vez haría exactamente lo que nadie quería
     * desde un botón que está dentro de una sola.
     */
    public function vaciarPapelera(Request $request, $clave)
    {
        return $this->ejecutar(function () use ($request, $clave) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_galerias_papelera_vaciar(?::TEXT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(string) $clave], $this->auditoria($request))
            );

            sistemaLog('info', 'Papelera de galería vaciada', ['galeria' => (string) $clave]);
            return $this->responder($result, (string) $clave);
        });
    }
}
