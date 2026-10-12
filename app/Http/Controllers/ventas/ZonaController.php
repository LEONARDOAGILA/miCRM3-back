<?php

namespace App\Http\Controllers\ventas;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;

/**
 * Zonas de clientes: áreas dibujadas en el mapa.
 *
 * Una zona es un polígono —o un círculo con su radio— con el que preguntar
 * «¿qué clientes tengo aquí dentro?». Sirve para repartir carteras por
 * territorio, planear una ruta de visitas o ver dónde no se está llegando.
 *
 * Mismo esquema que el resto del módulo: toda la lógica vive en funciones
 * PL/pgSQL (ventas.fn_zonas_*) y aquí sólo se valida la entrada y se traduce
 * el error. La geometría se comprueba DOS veces a propósito: aquí para dar un
 * mensaje claro, y en la base porque es la que no se puede saltar.
 *
 * Rutas (prefijo /ventas/zona):
 *   GET    allZonas?inactivas=0
 *   GET    findByIdZona/{id}
 *   POST   saveZona           { nombre, tipo, vertices|centro+radio, pais?, provincia?, canton?, color?, … }
 *   POST   saveZona/{id}
 *   DELETE deleteZona/{id}
 *   GET    clientes/{id}?page&per_page&search
 *   GET    clientesUbicados?limite&min_lat&max_lat&min_lng&max_lng
 */
class ZonaController extends Controller
{
    use ApiResponder;

    /** SQLSTATE de las funciones → código HTTP. Los mismos que usa el módulo. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,  // falta un dato obligatorio o está mal
        'P0013' => 404,  // la zona no existe
        'P0020' => 409,  // ya hay una zona con ese nombre
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    /**
     * Tope de vértices.
     *
     * Un área dibujada a mano no pasa de unas decenas de puntos; el tope está
     * para que nadie mande por la API un polígono de cien mil y deje la
     * consulta de clientes dando vueltas.
     */
    private const MAX_VERTICES = 500;

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

    /** Cuerpo de la petición: JSON plano o el envoltorio { json: "…" } (FormData). */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    // ================================================================
    // LEER
    // ================================================================

    public function allZonas(Request $request)
    {
        try {
            $incluirInactivas = filter_var($request->query('inactivas', true), FILTER_VALIDATE_BOOLEAN);
            $result = DB::selectOne('SELECT ventas.fn_zonas_listar(?::BOOLEAN) as result', [$incluirInactivas]);
            $r = json_decode($result->result, true);

            return ($r['success'] ?? false)
                ? $this->successResponse($r['data'], $r['message'])
                : $this->errorResponse($r['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allZonas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener las zonas', 500);
        }
    }

    public function findByIdZona($id)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_zonas_json(?::BIGINT) as result', [(int) $id]);
            $zona = $result->result ? json_decode($result->result, true) : null;

            if (!$zona) {
                return $this->errorResponse('La zona no existe', 404);
            }
            return $this->successResponse($zona, 'Zona obtenida exitosamente');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdZona', ['zona_id' => $id, 'message' => $e->getMessage()]);
            return $this->errorResponse('Ocurrió un error al obtener la zona', 500);
        }
    }

    /**
     * Los clientes que caen dentro de la zona.
     *
     * Es para lo que existe todo esto. Devuelve { data, zona, meta } y cada
     * cliente trae sus coordenadas, para que un mapa pueda pintar un marcador
     * por cliente sin pedir cada ficha.
     */
    public function clientes(Request $request, $id)
    {
        try {
            $page    = (int) $request->input('page', 1);
            $perPage = (int) $request->input('per_page', 50);
            $search  = (string) $request->input('search', '');

            $result = DB::selectOne(
                'SELECT ventas.fn_zonas_clientes(?::BIGINT, ?::INTEGER, ?::INTEGER, ?::TEXT) as result',
                [(int) $id, $page, $perPage, $search]
            );
            $r = json_decode($result->result, true);

            return $this->successResponse(
                ['data' => $r['data'], 'zona' => $r['zona'], 'meta' => $r['meta']],
                $r['message']
            );
        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en clientes de la zona', ['zona_id' => $id, 'message' => $e->getMessage()]);
            return $this->errorResponse('Ocurrió un error al obtener los clientes de la zona', 500);
        }
    }

    /**
     * Todos los clientes que tienen coordenadas, para pintarlos en el mapa.
     *
     * Va aparte de `clientes` porque contesta otra pregunta: aquél dice quién
     * cae dentro de una zona y devuelve la ficha resumida para la tabla; éste
     * dice dónde está todo el mundo y devuelve cuatro campos, porque son mil
     * puntos y mandar la ficha de cada uno sería mover un megabyte para
     * dibujar puntitos.
     *
     * Se puede acotar a lo que se ve en el mapa con min_lat…max_lng.
     */
    public function clientesUbicados(Request $request)
    {
        try {
            $limite = (int) $request->input('limite', 2000);

            // Los cuatro o ninguno: media caja no acota nada
            $caja = ['min_lat', 'max_lat', 'min_lng', 'max_lng'];
            $hayCaja = count(array_filter($caja, fn($k) => $request->filled($k))) === 4;

            $result = DB::selectOne(
                'SELECT ventas.fn_clientes_ubicados(?::INTEGER, ?::NUMERIC, ?::NUMERIC, ?::NUMERIC, ?::NUMERIC) as result',
                [
                    $limite,
                    $hayCaja ? (float) $request->input('min_lat') : null,
                    $hayCaja ? (float) $request->input('max_lat') : null,
                    $hayCaja ? (float) $request->input('min_lng') : null,
                    $hayCaja ? (float) $request->input('max_lng') : null,
                ]
            );
            $r = json_decode($result->result, true);

            return ($r['success'] ?? false)
                ? $this->successResponse(['data' => $r['data'], 'meta' => $r['meta']], $r['message'])
                : $this->errorResponse($r['message'], 500);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en clientesUbicados', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener los clientes ubicados', 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function saveZona(Request $request, $id = null)
    {
        try {
            $datos = $this->datosDe($request);

            // Las reglas van como ARRAY y no como cadena con «|»: una regex con
            // una barra dentro (la del color) parte la cadena por la mitad y
            // Laravel revienta con «No ending delimiter».
            $validator = Validator::make($datos, [
                'nombre'       => ['required', 'string', 'min:3', 'max:120'],
                'descripcion'  => ['nullable', 'string', 'max:2000'],

                // Dónde cae la zona. Texto libre y no un catálogo: en esta
                // base ventas.clientes.provincia también lo es, y traducir
                // entre códigos y nombres para comparar una zona con sus
                // clientes sería trabajo para no ganar nada.
                'pais'         => ['nullable', 'string', 'max:80'],
                'provincia'    => ['nullable', 'string', 'max:100'],
                'canton'       => ['nullable', 'string', 'max:100'],
                'color'        => ['nullable', 'string', 'regex:/^#[0-9A-Fa-f]{6}$/'],
                'tipo'         => ['nullable', Rule::in(['POLIGONO', 'CIRCULO'])],
                'activo'       => ['nullable', 'boolean'],

                'vertices'           => ['nullable', 'array', 'min:3', 'max:' . self::MAX_VERTICES],
                'vertices.*.lat'     => ['required_with:vertices', 'numeric', 'between:-90,90'],
                'vertices.*.lng'     => ['required_with:vertices', 'numeric', 'between:-180,180'],

                'centro_lat'   => ['nullable', 'numeric', 'between:-90,90'],
                'centro_lng'   => ['nullable', 'numeric', 'between:-180,180'],
                // Medio millón de metros son 500 km: más que eso no es una zona
                'radio_metros' => ['nullable', 'numeric', 'min:1', 'max:500000'],
            ], [
                'nombre.required'  => 'El nombre de la zona es obligatorio',
                'nombre.min'       => 'El nombre debe tener al menos 3 caracteres',
                'color.regex'      => 'El color debe ser hexadecimal, como #00ACAC',
                'vertices.min'     => 'Un polígono necesita al menos tres puntos',
                'vertices.max'     => 'El polígono tiene demasiados puntos (máximo ' . self::MAX_VERTICES . ')',
                'vertices.*.lat.between' => 'Hay un punto con una latitud imposible',
                'vertices.*.lng.between' => 'Hay un punto con una longitud imposible',
            ]);

            // Lo que cada tipo necesita. Se comprueba aquí para poder decirlo
            // con palabras; la base lo vuelve a mirar porque es la que manda.
            $validator->after(function ($v) use ($datos) {
                $tipo = strtoupper(trim($datos['tipo'] ?? 'POLIGONO'));
                if ($tipo === 'CIRCULO') {
                    if (!isset($datos['centro_lat'], $datos['centro_lng'], $datos['radio_metros'])) {
                        $v->errors()->add('tipo', 'Un círculo necesita centro y radio');
                    }
                } elseif (empty($datos['vertices'])) {
                    $v->errors()->add('vertices', 'Hay que dibujar el área en el mapa');
                }
            });

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();
            $tipo = strtoupper(trim($d['tipo'] ?? 'POLIGONO'));

            $result = DB::selectOne(
                'SELECT ventas.fn_zonas_guardar('
                . '?::BIGINT, ?::VARCHAR, ?::TEXT, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, '
                . '?::VARCHAR, ?::VARCHAR, ?::JSONB, '
                . '?::NUMERIC, ?::NUMERIC, ?::NUMERIC, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id ? (int) $id : null,
                    $d['nombre'],
                    $d['descripcion'] ?? null,
                    $d['pais'] ?? null,
                    $d['provincia'] ?? null,
                    $d['canton'] ?? null,
                    $d['color'] ?? null,
                    $tipo,
                    // Sólo lo que le toca a cada tipo: así una zona que pasa de
                    // círculo a polígono no se queda con el radio de antes
                    $tipo === 'POLIGONO' && !empty($d['vertices']) ? json_encode(array_values($d['vertices'])) : null,
                    $tipo === 'CIRCULO' ? ($d['centro_lat']   ?? null) : null,
                    $tipo === 'CIRCULO' ? ($d['centro_lng']   ?? null) : null,
                    $tipo === 'CIRCULO' ? ($d['radio_metros'] ?? null) : null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Zona guardada', ['zona_id' => $r['data']['id'] ?? null, 'tipo' => $tipo]);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'saveZona rechazado',
                ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en saveZona', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar la zona', 500);
        }
    }

    public function deleteZona(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_zonas_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Zona eliminada', ['zona_id' => $id]);

            return $this->successResponse(null, $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteZona', ['zona_id' => $id, 'message' => $e->getMessage()]);
            return $this->errorResponse('Ocurrió un error al eliminar la zona', 500);
        }
    }
}
