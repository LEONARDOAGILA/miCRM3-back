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
 * CRUD de la PLANTILLA de características (inventarios.caracteristicas_categorias).
 *
 * Cada categoría lleva su lista de lo que hay que rellenar en un producto:
 * un portátil pide procesador, memoria y almacenamiento; un televisor,
 * pulgadas y resolución. Esta pantalla mantiene esas listas; quien rellena
 * los valores es el formulario del producto.
 *
 * Mismo esquema que MarcaController: la lógica vive en las funciones
 * inventarios.fn_caracteristicas_* (validaciones, auditoría, transacción) y
 * aquí sólo se valida la entrada, se llama con el contexto del usuario y se
 * traduce la respuesta.
 *
 *   GET    inventarios/caracteristica/allCaracteristicas?page&per_page&search&categoria_id&filtros
 *   GET    inventarios/caracteristica/listCaracteristicas?categoria_id&activos=1   (la plantilla)
 *   GET    inventarios/caracteristica/findByIdCaracteristica/{id}
 *   POST   inventarios/caracteristica/addCaracteristica
 *   POST   inventarios/caracteristica/editCaracteristica/{id}
 *   POST   inventarios/caracteristica/activarCaracteristica/{id}   { activo? }; sin ella, alterna
 *   POST   inventarios/caracteristica/ordenarCaracteristicas      { ids: [...] } en el orden nuevo
 *   DELETE inventarios/caracteristica/deleteCaracteristica/{id}    a la papelera
 *   GET    inventarios/caracteristica/papelera
 *   POST   inventarios/caracteristica/restaurar           { ids: [...] }
 *   POST   inventarios/caracteristica/eliminarDefinitivo  { ids: [...] }  (permiso «vaciar»)
 *   POST   inventarios/caracteristica/vaciarPapelera                      (permiso «vaciar»)
 */
class CaracteristicaController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;
    use \App\Http\Controllers\Concerns\FiltrosDeColumna;

    /**
     * Por qué columnas deja filtrar la rejilla, y de qué tipo.
     *
     * Lista blanca, no comprobación: el nombre de la columna acaba dentro de
     * una consulta y lo que no esté aquí se tira. `categoria_ruta` y `estado`
     * son lo que SE VE en la celda, no columnas de la tabla: la primera es la
     * ruta entera de la categoría y la segunda la palabra «Activa»/«Inactiva».
     */
    private const COLUMNAS_FILTRABLES = [
        'id'             => 'numero',
        'nombre'         => 'texto',
        'categoria_ruta' => 'texto',
        'orden'          => 'numero',
        'estado'         => 'texto',
        'num_productos'  => 'numero',
        'created_by'     => 'texto',
        'updated_by'     => 'texto',
        // Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
        'created_at'     => 'texto',
        'updated_at'     => 'texto',
    ];

    /**
     * SQLSTATE que usan las funciones del módulo para las reglas de negocio.
     * Son errores del usuario, no fallos del servidor: se responden como 4xx.
     */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0006' => 409,   // nombre repetido dentro de la categoría
        'P0013' => 404,   // la característica no existe
        'P0015' => 422,   // valor inválido
        'P0016' => 422,   // la categoría no existe
        'P0019' => 404,   // no está en la papelera
        'P0021' => 409,   // en uso
    ];

    public function __construct()
    {
        $this->middleware('auth:api');
    }

    // ================================================================
    // AYUDANTES
    // ================================================================

    /** Convierte el error de una función PL/pgSQL en [mensaje, código HTTP]. */
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

    /** Los seis argumentos de auditoría que esperan todas las funciones. */
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

    /** JSON plano, o el envoltorio { json: "…" } de los formularios FormData. */
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
            'categoria_id' => 'required|integer',
            'nombre'       => 'required|string|min:2|max:100',
            'orden'        => 'nullable|integer|min:1|max:9999',
            'activo'       => 'nullable|boolean',
        ];
    }

    private function mensajes(): array
    {
        return [
            'categoria_id.required' => 'Hay que decir a qué categoría pertenece',
            'nombre.required'       => 'El nombre de la característica es obligatorio',
            'nombre.min'            => 'El nombre debe tener al menos 2 caracteres',
            'nombre.max'            => 'El nombre no puede superar los 100 caracteres',
            'orden.min'             => 'El orden empieza en 1',
        ];
    }

    // ================================================================
    // LISTAR
    // ================================================================

    /** El listado de la pantalla: paginado, con buscador y filtros de columna. */
    public function allCaracteristicas(Request $request)
    {
        try {
            // Los filtros se aplican en el SERVIDOR porque la pantalla pagina:
            // ag-Grid sólo tiene las filas de la página y filtrar ahí buscaría
            // dentro de quince.
            $filtros = $this->filtrosDeColumna($request->input('filtros'), self::COLUMNAS_FILTRABLES);
            $categoria = $request->input('categoria_id');

            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_listar_paginado(?::INTEGER, ?::INTEGER, ?::TEXT, ?::BIGINT, ?::JSONB) as result',
                [(int) $request->input('page', 1),
                 (int) $request->input('per_page', 15),
                 (string) $request->input('search', ''),
                 ($categoria === null || $categoria === '') ? null : (int) $categoria,
                 json_encode((object) $filtros)]
            );
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'], 500);
            }
            return $this->successResponse($r, 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allCaracteristicas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * La PLANTILLA de una categoría: lo que el formulario del producto tiene
     * que pedir. Con ?activos=1 (lo normal) sólo las vigentes.
     */
    public function listCaracteristicas(Request $request)
    {
        try {
            $categoria = $request->input('categoria_id');
            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_listar(?::BIGINT, ?::BOOLEAN) as result',
                [($categoria === null || $categoria === '') ? null : (int) $categoria,
                 $request->input('activos', '1') === '1']
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listCaracteristicas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdCaracteristica($id)
    {
        try {
            $result = DB::selectOne('SELECT inventarios.fn_caracteristicas_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdCaracteristica', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addCaracteristica(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_crear(?::BIGINT, ?::VARCHAR, ?::INTEGER, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $d['categoria_id'],
                    $d['nombre'],
                    isset($d['orden']) && $d['orden'] !== '' ? (int) $d['orden'] : null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Característica creada', ['nombre' => $d['nombre'], 'categoria_id' => $d['categoria_id']]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addCaracteristica', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function editCaracteristica(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_modificar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::INTEGER, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    (int) $d['categoria_id'],
                    $d['nombre'],
                    isset($d['orden']) && $d['orden'] !== '' ? (int) $d['orden'] : null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Característica actualizada', ['id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editCaracteristica', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * El orden nuevo, el que se deja al arrastrar las filas de la rejilla.
     *
     * { ids: [12, 10, 11] } = ésas tres, en ese orden. Tienen que ser de la
     * MISMA categoría: el orden es dentro de su lista, y mover una
     * característica de categoría es modificarla, no reordenarla.
     *
     * Sólo se mandan las filas QUE SE VEN (la página), y la función reparte
     * entre ellas los números de orden que ya ocupaban: así reordenar una
     * página no se mete en el sitio de las de otra.
     */
    public function ordenarCaracteristicas(Request $request)
    {
        // Cambiar el orden es modificar. Se comprueba AQUÍ y no sólo
        // escondiendo el asa de arrastrar: esconder un botón no es un permiso.
        if ($no = $this->exigirPermiso('allCaracteristicas', 'editar',
                'No tiene permiso para cambiar el orden de las características')) {
            return $no;
        }

        try {
            $datos = $this->datosDe($request);
            $ids = array_values(array_filter(array_map('intval', (array) ($datos['ids'] ?? []))));

            if (count($ids) < 2) {
                return $this->errorResponse('Hacen falta al menos dos características para cambiar el orden', 422);
            }

            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode($ids)], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Orden de características cambiado', [
                'ids'       => $ids,
                'cambiadas' => $r['data']['cambiadas'] ?? null,
            ]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en ordenarCaracteristicas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Enciende o apaga; sin `activo` en el cuerpo, alterna. */
    public function activarCaracteristica(Request $request, $id)
    {
        try {
            $datos = $this->datosDe($request);
            $activo = array_key_exists('activo', $datos) ? (bool) $datos['activo'] : null;

            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_activar(?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarCaracteristica', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** A la papelera (borrado lógico). */
    public function deleteCaracteristica(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Característica enviada a la papelera', ['id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteCaracteristica', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================

    public function papelera(Request $request)
    {
        try {
            $result = DB::selectOne('SELECT inventarios.fn_caracteristicas_papelera_listar() as result');
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de características', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function restaurar(Request $request)
    {
        return $this->accionPapelera($request, 'inventarios.fn_caracteristicas_restaurar', 'restaurar');
    }

    public function eliminarDefinitivo(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar», que es
        // otro distinto de «papelera». Se comprueba AQUÍ y no sólo en el
        // front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allCaracteristicas', 'vaciar',
                'No tiene permiso para eliminar definitivamente características')) {
            return $no;
        }

        return $this->accionPapelera($request, 'inventarios.fn_caracteristicas_eliminar_definitivo', 'eliminarDefinitivo');
    }

    public function vaciarPapelera(Request $request)
    {
        if ($no = $this->exigirPermiso('allCaracteristicas', 'vaciar',
                'No tiene permiso para vaciar la papelera de características')) {
            return $no;
        }

        return $this->accionPapelera($request, 'inventarios.fn_caracteristicas_papelera_vaciar', 'vaciarPapelera', false);
    }

    /** El tronco común de restaurar / eliminar definitivo / vaciar. */
    private function accionPapelera(Request $request, string $funcion, string $nombre, bool $conIds = true)
    {
        try {
            $auditoria = $this->auditoria($request);

            if ($conIds) {
                $datos = $this->datosDe($request);
                $ids = array_values(array_filter(array_map('intval', (array) ($datos['ids'] ?? []))));
                if (empty($ids)) {
                    return $this->errorResponse('No se indicó ninguna característica', 422);
                }
                $result = DB::selectOne(
                    "SELECT $funcion(?::JSONB, " . self::CASTS_AUDIT . ') as result',
                    array_merge([json_encode($ids)], $auditoria)
                );
            } else {
                $result = DB::selectOne(
                    "SELECT $funcion(" . self::CASTS_AUDIT . ') as result',
                    $auditoria
                );
            }

            $r = json_decode($result->result, true);
            sistemaLog('info', "Papelera de características: $nombre", ['data' => $r['data'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', "Error en $nombre de características", ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
