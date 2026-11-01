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
 * NO SE CREAN NI SE BORRAN SECCIONES: cada una existe porque la tienda sabe
 * pintarla. Una clave nueva sin código que la pinte sería un hueco invisible,
 * y una borrada dejaría a la tienda pidiendo algo que ya no está.
 *
 * CADA SECCIÓN DICE DE DÓNDE COME, y hoy sólo los dos banners tienen fuente
 * —sus galerías—. Las demás esperan a que se traslade la suya: el catálogo,
 * las marcas de la tienda, el mosaico. La pantalla lo enseña tal cual en vez
 * de fingir que se pueden configurar, y la portada pública ya se salta la
 * sección que no tenga nada que enseñar.
 *
 *   GET  ecommerce/inicio/allInicio
 *   POST ecommerce/inicio/editSeccion/{clave}       { titulo?, subtitulo?, activo?, desde?, hasta? }
 *   POST ecommerce/inicio/activarSeccion/{clave}    { activo? }; sin ella, alterna
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

            $validator = Validator::make($d, [
                'titulo'    => 'nullable|string|max:80',
                'subtitulo' => 'nullable|string|max:80',
                'activo'    => 'nullable|boolean',
                'desde'     => 'nullable|string|max:30',
                'hasta'     => 'nullable|string|max:30',
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
