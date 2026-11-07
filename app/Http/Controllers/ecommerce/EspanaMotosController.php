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
 * ESPAÑA MOTOS: un micro-sitio dentro de la tienda.
 *
 * Tiene su propia portada y su propio catálogo, que es la misma pantalla de
 * /shop limitada a unas categorías. Cuatro piezas que se encienden por
 * separado —banner, fondo, tarjetas y marcas— más las PESTAÑAS del catálogo.
 *
 * SE PUBLICA APARTE. Mientras `publicada` esté apagada, la tienda responde 404
 * en /espana-motos: así se prepara entera —banner, fondo, pestañas— y se
 * enciende cuando está lista, en vez de montarla a la vista de todos.
 *
 * TODO DEVUELVE LA CONFIGURACIÓN ENTERA, como en el encabezado y el pie:
 * añadir una pestaña cambia el orden de las demás, y recomponerlo en el front
 * es como se acaban viendo dos cosas distintas.
 *
 *   GET    ecommerce/espanaMotos/getEspanaMotos
 *   POST   ecommerce/espanaMotos/editEspanaMotos          { publicada, banner_visible, fondo_*, … }
 *   POST   ecommerce/espanaMotos/addPestana               { nombre, categorias: [...], activo? }
 *   POST   ecommerce/espanaMotos/editPestana/{id}
 *   DELETE ecommerce/espanaMotos/deletePestana/{id}
 *   POST   ecommerce/espanaMotos/addMarca                 { marca_id }
 *   DELETE ecommerce/espanaMotos/deleteMarca/{id}
 *   POST   ecommerce/espanaMotos/ordenarPestanas          { ids: [...] }
 *   POST   ecommerce/espanaMotos/ordenarMarcas            { ids: [...] }
 */
class EspanaMotosController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ArchivosDeLaTienda;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0006' => 409,   // esa marca ya está
        'P0013' => 404,   // no existe
        'P0015' => 422,   // valor inválido
        'P0016' => 422,   // apunta a algo del catálogo que no existe
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
        if ($data === null) { return null; }
        $data['fondo_imagen_url'] = $this->urlArchivo($data['fondo_imagen'] ?? null, 'imagenes');
        return $data;
    }

    private function responder($result)
    {
        $r = json_decode($result->result, true);

        // Lo que ve la tienda cambia con cualquiera de estas acciones
        EspanaMotosPublicoController::limpiar();

        return $this->successResponse($this->conUrl($r['data'] ?? null), $r['message'] ?? 'España Motos');
    }

    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en España Motos', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // CONFIGURACIÓN
    // ================================================================

    public function getEspanaMotos()
    {
        return $this->ejecutar(function () {
            $r = json_decode(DB::selectOne('SELECT ecommerce.fn_espana_motos_obtener() as result')->result, true);
            return $this->successResponse($this->conUrl($r['data'] ?? null), $r['message']);
        });
    }

    public function editEspanaMotos(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            // La imagen puede llegar como dirección completa (la que devolvió
            // una lectura anterior) o como nombre suelto: se queda el nombre.
            if (isset($d['fondo_imagen'])) {
                $d['fondo_imagen'] = $this->nombreDeArchivo($d['fondo_imagen']);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_espana_motos_modificar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode($d)], $this->auditoria($request))
            );

            sistemaLog('info', 'España Motos modificada', ['publicada' => $d['publicada'] ?? null]);
            return $this->responder($result);
        });
    }

    // ================================================================
    // PESTAÑAS DEL CATÁLOGO
    // ================================================================

    public function addPestana(Request $request)  { return $this->guardarPestana($request, null); }
    public function editPestana(Request $request, $id) { return $this->guardarPestana($request, (int) $id); }

    private function guardarPestana(Request $request, ?int $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $validator = Validator::make($this->datosDe($request), [
                'nombre'       => 'required|string|max:30',
                'categorias'   => 'required|array|min:1',
                'categorias.*' => 'integer',
                'activo'       => 'nullable|boolean',
            ], [
                'nombre.required'     => 'El nombre de la pestaña es obligatorio',
                'nombre.max'          => 'El nombre no puede superar los 30 caracteres',
                'categorias.required' => 'La pestaña necesita al menos una categoría',
                'categorias.min'      => 'La pestaña necesita al menos una categoría',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ecommerce.fn_espana_motos_pestanas_guardar(?::BIGINT, ?::VARCHAR, ?::JSONB, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id,
                    $d['nombre'],
                    json_encode(array_values(array_map('intval', $d['categorias']))),
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    public function deletePestana(Request $request, $id)
    {
        return $this->ejecutar(fn () => $this->responder(DB::selectOne(
            'SELECT ecommerce.fn_espana_motos_quitar(?::TEXT, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
            array_merge(['pestana', (int) $id], $this->auditoria($request)))));
    }

    // ================================================================
    // MARCAS
    // ================================================================

    public function addMarca(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);
            if (empty($d['marca_id'])) {
                return $this->errorResponse('Falta decir qué marca añadir', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_espana_motos_marcas_guardar(?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $d['marca_id'],
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    public function deleteMarca(Request $request, $id)
    {
        return $this->ejecutar(fn () => $this->responder(DB::selectOne(
            'SELECT ecommerce.fn_espana_motos_quitar(?::TEXT, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
            array_merge(['marca', (int) $id], $this->auditoria($request)))));
    }

    // ================================================================
    // ORDEN
    // ================================================================

    public function ordenarPestanas(Request $request) { return $this->ordenar($request, 'pestanas'); }
    public function ordenarMarcas(Request $request)   { return $this->ordenar($request, 'marcas'); }

    private function ordenar(Request $request, string $que)
    {
        return $this->ejecutar(function () use ($request, $que) {
            $ids = $this->datosDe($request)['ids'] ?? null;
            if (!is_array($ids) || !$ids) {
                return $this->errorResponse('No se indicó el orden nuevo', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_espana_motos_ordenar(?::TEXT, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$que, json_encode(array_values(array_map('intval', $ids)))],
                            $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }
}
