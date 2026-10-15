<?php

namespace App\Http\Controllers\inventarios;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * CRUD del árbol de categorías (inventarios.categorias).
 *
 * Es jerárquico, como seguridad.menus: Línea Blanca > Refrigeración >
 * Refrigeradoras. Por eso NO PAGINA —un árbol partido en páginas deja la
 * mitad de los padres fuera— y por eso tiene una ruta `mover`, que es lo que
 * usa el arrastre de la rejilla.
 *
 * Toda la lógica vive en inventarios.fn_categorias_*; aquí sólo se valida la
 * entrada y se traduce la respuesta.
 *
 *   GET    inventarios/categoria/allCategorias[?activos=1]  el árbol entero, ordenado
 *   GET    inventarios/categoria/listCategorias[?activos=0] lo mismo, para los combos
 *   GET    inventarios/categoria/findByIdCategoria/{id}
 *   POST   inventarios/categoria/addCategoria
 *   POST   inventarios/categoria/editCategoria/{id}
 *   POST   inventarios/categoria/activarCategoria/{id}      { activo? }; sin ella, alterna
 *   POST   inventarios/categoria/moverCategoria/{id}        { padre_id, antes_de }
 *   DELETE inventarios/categoria/deleteCategoria/{id}
 */
class CategoriaController extends Controller
{
    use ApiResponder;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0006' => 409,   // nombre duplicado entre hermanos
        'P0013' => 404,   // la categoría no existe
        'P0014' => 409,   // no se puede eliminar: tiene hijos o productos
        'P0015' => 422,   // valor inválido (nivel máximo)
        'P0016' => 422,   // la categoría padre no existe
    ];

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

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

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

    private function reglas(): array
    {
        return [
            'nombre'      => 'required|string|min:2|max:100',
            'descripcion' => 'nullable|string|max:2000',
            'icono'       => 'nullable|string|max:50',
            'activo'      => 'nullable|boolean',
        ];
    }

    private function mensajes(): array
    {
        return [
            'nombre.required' => 'El nombre de la categoría es obligatorio',
            'nombre.min'      => 'El nombre debe tener al menos 2 caracteres',
            'nombre.max'      => 'El nombre no puede superar los 100 caracteres',
        ];
    }

    // ================================================================
    // LISTAR
    // ================================================================

    /**
     * El árbol entero, ya ordenado para pintarlo.
     *
     * Sin paginar a propósito: las filas vienen en el orden en que se dibujan
     * y cada una trae su `nivel`, que es lo que la rejilla usa para la sangría
     * —el mismo trato que allMenus—.
     */
    public function allCategorias(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '0') === '1';
            $result = DB::selectOne('SELECT inventarios.fn_categorias_listar(?::BOOLEAN) as result', [$soloActivos]);
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar el árbol', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allCategorias', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Lo mismo, para los combos del formulario de producto (trae la ruta completa). */
    public function listCategorias(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $result = DB::selectOne('SELECT inventarios.fn_categorias_listar(?::BOOLEAN) as result', [$soloActivos]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'] ?? [], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listCategorias', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdCategoria($id)
    {
        try {
            $result = DB::selectOne('SELECT inventarios.fn_categorias_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdCategoria', ['message' => $e->getMessage(), 'categoria_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addCategoria(Request $request)
    {
        try {
            $datos = $this->datosDe($request);
            $validator = Validator::make($datos, $this->reglas() + ['padre_id' => 'nullable|integer'], $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_categorias_crear(?::VARCHAR, ?::BIGINT, ?::TEXT, ?::VARCHAR, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $d['nombre'],
                    isset($d['padre_id']) && $d['padre_id'] !== '' ? (int) $d['padre_id'] : null,
                    $d['descripcion'] ?? null,
                    $d['icono'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Categoría creada', ['categoria_id' => $r['data']['id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addCategoria rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addCategoria', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear la categoría', 500);
        }
    }

    /**
     * Cambia lo que se ve en el formulario.
     *
     * NO CAMBIA DE PADRE: mover es otra cosa —ciclos, nivel de todo lo que
     * cuelga, renumerar hermanos— y tiene su propia ruta.
     */
    public function editCategoria(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_categorias_modificar(?::BIGINT, ?::VARCHAR, ?::TEXT, ?::VARCHAR, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    $d['nombre'],
                    $d['descripcion'] ?? null,
                    $d['icono'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Categoría actualizada', ['categoria_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editCategoria rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'categoria_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editCategoria', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'categoria_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar la categoría', 500);
        }
    }

    public function activarCategoria(Request $request, $id)
    {
        try {
            // El booleano con filter_var: "false" en texto es true a secas
            $activo = $request->exists('activo') && $request->input('activo') !== null && $request->input('activo') !== ''
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE)
                : null;

            $result = DB::selectOne(
                'SELECT inventarios.fn_categorias_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 500);
            }

            sistemaLog('info', 'Categoría activada/desactivada', ['categoria_id' => $id, 'activo' => $r['data']['activo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarCategoria', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'categoria_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cambiar el estado de la categoría', 500);
        }
    }

    /**
     * Mover en el árbol (lo que hace el arrastre de la rejilla).
     *
     * `padre_id` nulo la sube a la raíz; `antes_de` dice delante de qué
     * hermano queda, y sin él se va al final.
     *
     * La función no levanta excepción: contesta success=false con un
     * error_code (CICLO, NIVEL_MAXIMO, NOMBRE_DUPLICADO…), y cada uno tiene su
     * mensaje para la pantalla. Todos son 409: es un conflicto con la forma
     * que tiene el árbol ahora mismo, no un error del servidor.
     */
    public function moverCategoria(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);

            $result = DB::selectOne(
                'SELECT inventarios.fn_categorias_mover(?::BIGINT, ?::BIGINT, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    isset($d['padre_id']) && $d['padre_id'] !== '' ? (int) $d['padre_id'] : null,
                    isset($d['antes_de']) && $d['antes_de'] !== '' ? (int) $d['antes_de'] : null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                sistemaLog('warning', 'moverCategoria rechazada',
                           ['categoria_id' => $id, 'error_code' => $r['error_code'] ?? null]);
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 409);
            }

            sistemaLog('info', 'Categoría movida', ['categoria_id' => $id, 'padre_id' => $d['padre_id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en moverCategoria', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'categoria_id' => $id]);
            return $this->errorResponse('Ocurrió un error al mover la categoría', 500);
        }
    }

    public function deleteCategoria(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_categorias_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Categoría eliminada', ['categoria_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteCategoria rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'categoria_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteCategoria', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'categoria_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar la categoría', 500);
        }
    }
}
