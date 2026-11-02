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
 * LA PORTADA DE LA TIENDA (administración).
 *
 * La portada no es una página: es una LISTA DE SECCIONES que se encienden, se
 * apagan y se reordenan —banner, categorías destacadas, ofertas, mosaico,
 * marcas—. Cada una saca sus datos de otro sitio; aquí se guarda cuáles hay,
 * en qué orden van, qué se lee encima y entre qué fechas se ven.
 *
 * POR ESTA PUERTA NO SE CREAN NI SE BORRAN SECCIONES, y hay dos clases:
 *
 *   · Las OCHO DE FÁBRICA existen porque la tienda sabe pintarlas. Una clave
 *     nueva sin código que la pinte sería un hueco invisible, y una borrada
 *     dejaría a la tienda pidiendo algo que ya no está.
 *   · Las de PRODUCTOS son los escaparates de «Productos por sección»: se
 *     crean y se borran allí —ProductoSeccionController—, y su fila en la
 *     portada va y viene con ellas. Aquí se administran como las otras.
 *
 * `allInicio` las devuelve juntas, en su orden, con `fija` diciendo de cuál
 * de las dos clases es cada una.
 *
 * EL RÓTULO ES LO QUE LEE EL CLIENTE encima de la sección, y se escribe aquí:
 * el texto y su pinta —tamaño, color y letra—. La pinta viaja en CLAVES
 * («grande», «deportiva»), nunca en CSS: la base sólo admite las de su lista,
 * así que por esta puerta no entra nada a la hoja de estilos de la tienda.
 *
 * CADA SECCIÓN DICE DE DÓNDE COME: las de banner, de su galería; las de
 * categorías y marcas, de sus pantallas. Las que todavía esperan a que se
 * traslade la suya lo enseñan tal cual, en vez de fingir que se pueden
 * configurar, y la portada pública ya se salta la sección que no tenga nada
 * que enseñar.
 *
 *   GET  ecommerce/inicio/allInicio
 * EL ALTO ES EL AIRE QUE OCUPA la sección, no el tamaño de lo que hay dentro:
 * las fotos y las tarjetas siguen midiendo lo que miden. Forzarles un alto
 * desde aquí las sacaría deformadas, y eso no se arregla luego desde una
 * pantalla de administración.
 *
 *   POST ecommerce/inicio/editSeccion/{clave}       { titulo?, subtitulo?, rotulo_tamano?,
 *                                                     rotulo_color?, rotulo_fuente?, alto?,
 *                                                     activo?, desde?, hasta? }
 *   POST ecommerce/inicio/activarSeccion/{clave}    { activo? }; sin ella, alterna
 *   POST ecommerce/inicio/altoSeccion/{clave}       { alto }; sólo el alto
 *   POST ecommerce/inicio/ordenarSecciones          { claves: [...] }
 */
class InicioController extends Controller
{
    use ApiResponder;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0013' => 404,   // la sección no existe
        'P0015' => 422,   // valor inválido
        'P0016' => 422,   // el orden no trae todas las secciones
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

    private function responder($result)
    {
        $r = json_decode($result->result, true);

        // Lo que ve la tienda cambia con cualquiera de estas acciones
        InicioPublicoController::limpiar();

        return $this->successResponse($r['data'] ?? null, $r['message'] ?? 'Portada de la tienda');
    }

    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en la portada de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function allInicio()
    {
        return $this->ejecutar(function () {
            $r = json_decode(DB::selectOne('SELECT ecommerce.fn_inicio_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function editSeccion(Request $request, $clave)
    {
        return $this->ejecutar(function () use ($request, $clave) {
            $d = $this->datosDe($request);

            // La lista de tamaños y letras no se repite aquí: la tiene la base,
            // en la columna y en la función que guarda. Copiarla sería tener dos
            // listas que un día dejan de decir lo mismo, y la de aquí no es la
            // que manda. Lo que sí se mira es el largo, para que un campo
            // absurdo no llegue a la base como una consulta enorme.
            $validator = Validator::make($d, [
                'titulo'        => 'nullable|string|max:80',
                'subtitulo'     => 'nullable|string|max:80',
                'rotulo_tamano' => 'nullable|string|max:10',
                'rotulo_color'  => 'nullable|string|max:7',
                'rotulo_fuente' => 'nullable|string|max:10',
                'alto'          => 'nullable|string|max:10',
                'activo'        => 'nullable|boolean',
                'desde'         => 'nullable|string|max:30',
                'hasta'         => 'nullable|string|max:30',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_seccion_guardar(?::TEXT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(string) $clave, json_encode($d)], $this->auditoria($request))
            );

            sistemaLog('info', 'Sección de la portada guardada', ['seccion' => (string) $clave]);
            return $this->responder($result);
        });
    }

    public function activarSeccion(Request $request, $clave)
    {
        return $this->ejecutar(function () use ($request, $clave) {
            $d = $this->datosDe($request);

            // Sin `activo`, alterna. Es lo que hace el interruptor de la lista.
            $activo = array_key_exists('activo', $d) && $d['activo'] !== null
                ? filter_var($d['activo'], FILTER_VALIDATE_BOOLEAN) : null;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_seccion_activar(?::TEXT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(string) $clave, $activo], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    /**
     * Sólo el alto, sin tocar lo demás.
     *
     * `editSeccion` guarda la sección entera —lo que no llegue se queda en
     * NULL—, así que estirar una sección con el ratón desde el modelado por
     * esa puerta le borraría el rótulo. Ésta cambia una cosa sola, como
     * `activarSeccion`.
     */
    public function altoSeccion(Request $request, $clave)
    {
        return $this->ejecutar(function () use ($request, $clave) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, ['alto' => 'required|string|max:10']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_seccion_alto(?::TEXT, ?::TEXT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(string) $clave, (string) $d['alto']], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    public function ordenarSecciones(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, [
                'claves'   => 'required|array|min:1',
                'claves.*' => 'string|max:50',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values($d['claves']))], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }
}
