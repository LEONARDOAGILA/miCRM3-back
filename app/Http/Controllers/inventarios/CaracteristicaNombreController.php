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
 * CRUD del DICCIONARIO de nombres de característica
 * (inventarios.caracteristicas_nombres).
 *
 * Antes el nombre se escribía a mano en cada categoría: 98 filas para 19
 * categorías pero sólo 64 nombres distintos, y «Color» escrito cuatro veces.
 * Cada reescritura era una oportunidad de poner «pezo» en vez de «peso», y
 * con eso la reportería de logística no sale.
 *
 * Ahora el nombre vive aquí una sola vez, con su UNIDAD y su TIPO DE DATO
 * aparte —«Potencia» + «W» + numérico, no «Potencia (W)» como texto—, y la
 * categoría lo escoge de un combo. Esta pantalla es de SISTEMAS: si cualquiera
 * puede añadir al diccionario, el combo acaba teniendo «pezo» como opción y no
 * se ha ganado nada.
 *
 * Mismo esquema que MarcaController: la lógica vive en las funciones
 * inventarios.fn_caracteristicas_nombres_* (validaciones, auditoría,
 * transacción) y aquí sólo se valida la entrada, se llama con el contexto del
 * usuario y se traduce la respuesta.
 *
 *   GET    inventarios/caracteristicaNombre/allCaracteristicasNombres?page&per_page&search&filtros
 *   GET    inventarios/caracteristicaNombre/listCaracteristicasNombres?activos=1   (el combo)
 *   GET    inventarios/caracteristicaNombre/findByIdCaracteristicaNombre/{id}
 *   POST   inventarios/caracteristicaNombre/addCaracteristicaNombre
 *   POST   inventarios/caracteristicaNombre/editCaracteristicaNombre/{id}
 *   POST   inventarios/caracteristicaNombre/activarCaracteristicaNombre/{id}  { activo? }; sin ella, alterna
 *   DELETE inventarios/caracteristicaNombre/deleteCaracteristicaNombre/{id}   a la papelera
 *   GET    inventarios/caracteristicaNombre/papelera
 *   POST   inventarios/caracteristicaNombre/restaurar           { ids: [...] }
 *   POST   inventarios/caracteristicaNombre/eliminarDefinitivo  { ids: [...] }  (permiso «vaciar»)
 *   DELETE inventarios/caracteristicaNombre/vaciarPapelera                     (permiso «vaciar»)
 */
class CaracteristicaNombreController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;
    use \App\Http\Controllers\Concerns\FiltrosDeColumna;

    /**
     * Por qué columnas deja filtrar la rejilla, y de qué tipo.
     *
     * Lista blanca, no comprobación: el nombre de la columna acaba dentro de
     * una consulta y lo que no esté aquí se tira.
     */
    private const COLUMNAS_FILTRABLES = [
        'id'             => 'numero',
        'nombre'         => 'texto',
        'unidad'         => 'texto',
        'tipo'           => 'texto',
        'descripcion'    => 'texto',
        'num_categorias' => 'numero',
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
        'P0006' => 409,   // ese nombre ya está en el diccionario
        'P0013' => 404,   // el nombre no existe
        'P0014' => 409,   // algo sigue apuntándolo
        'P0015' => 422,   // valor inválido
        'P0019' => 404,   // no está en la papelera
        'P0021' => 409,   // en uso: lo usan N categorías
    ];

    /** Los tipos de dato que acepta el diccionario. */
    private const TIPOS = ['TEXTO', 'NUMERO', 'SI_NO', 'LISTA'];

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
            'nombre'      => 'required|string|min:2|max:100',
            'unidad'      => 'nullable|string|max:20',
            'tipo'        => 'nullable|string|in:' . implode(',', self::TIPOS),
            'descripcion' => 'nullable|string|max:1000',
            'activo'      => 'nullable|boolean',
        ];
    }

    private function mensajes(): array
    {
        return [
            'nombre.required' => 'El nombre es obligatorio',
            'nombre.min'      => 'El nombre debe tener al menos 2 caracteres',
            'nombre.max'      => 'El nombre no puede superar los 100 caracteres',
            'unidad.max'      => 'La unidad no puede superar los 20 caracteres',
            'tipo.in'         => 'El tipo debe ser texto, número, sí/no o lista',
        ];
    }

    // ================================================================
    // LISTAR
    // ================================================================

    /** El listado de la pantalla: paginado, con buscador y filtros de columna. */
    public function allCaracteristicasNombres(Request $request)
    {
        try {
            // Los filtros se aplican en el SERVIDOR porque la pantalla pagina:
            // ag-Grid sólo tiene las filas de la página y filtrar ahí buscaría
            // dentro de quince.
            $filtros = $this->filtrosDeColumna($request->input('filtros'), self::COLUMNAS_FILTRABLES);

            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_nombres_listar_paginado(?::INTEGER, ?::INTEGER, ?::TEXT, ?::JSONB) as result',
                [(int) $request->input('page', 1),
                 (int) $request->input('per_page', 15),
                 (string) $request->input('search', ''),
                 json_encode((object) $filtros)]
            );
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'], 500);
            }
            return $this->successResponse($r, 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allCaracteristicasNombres', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * El diccionario entero para el combo. Con ?activos=1 (lo normal) sólo
     * los vigentes: un nombre inactivo no se puede volver a escoger, pero
     * donde ya está puesto se queda.
     */
    public function listCaracteristicasNombres(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_nombres_listar(?::BOOLEAN) as result',
                [$request->input('activos', '1') === '1']
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listCaracteristicasNombres', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdCaracteristicaNombre($id)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_nombres_obtener(?::BIGINT) as result',
                [(int) $id]
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdCaracteristicaNombre', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addCaracteristicaNombre(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_nombres_crear(?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::TEXT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $d['nombre'],
                    isset($d['unidad']) && $d['unidad'] !== '' ? $d['unidad'] : null,
                    strtoupper($d['tipo'] ?? 'TEXTO'),
                    isset($d['descripcion']) && $d['descripcion'] !== '' ? $d['descripcion'] : null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Nombre de característica creado', ['nombre' => $d['nombre']]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addCaracteristicaNombre', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function editCaracteristicaNombre(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_nombres_modificar(?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::TEXT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    $d['nombre'],
                    isset($d['unidad']) && $d['unidad'] !== '' ? $d['unidad'] : null,
                    strtoupper($d['tipo'] ?? 'TEXTO'),
                    isset($d['descripcion']) && $d['descripcion'] !== '' ? $d['descripcion'] : null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Nombre de característica actualizado', ['id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editCaracteristicaNombre', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Enciende o apaga; sin `activo` en el cuerpo, alterna. */
    public function activarCaracteristicaNombre(Request $request, $id)
    {
        try {
            $datos = $this->datosDe($request);
            $activo = array_key_exists('activo', $datos) ? (bool) $datos['activo'] : null;

            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_nombres_activar(?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarCaracteristicaNombre', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * A la papelera (borrado lógico).
     *
     * La función se niega si el nombre está EN USO y dice cuántas categorías
     * lo usan: si se dejara borrar, esas categorías se quedarían enseñando un
     * nombre que está en la papelera.
     */
    public function deleteCaracteristicaNombre(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_caracteristicas_nombres_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Nombre de característica enviado a la papelera', ['id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteCaracteristicaNombre', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================

    public function papelera(Request $request)
    {
        try {
            $result = DB::selectOne('SELECT inventarios.fn_caracteristicas_nombres_papelera_listar() as result');
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de nombres de característica', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function restaurar(Request $request)
    {
        return $this->accionPapelera($request, 'inventarios.fn_caracteristicas_nombres_restaurar', 'restaurar');
    }

    public function eliminarDefinitivo(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar», que es
        // otro distinto de «papelera». Se comprueba AQUÍ y no sólo en el
        // front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allCaracteristicasNombres', 'vaciar',
                'No tiene permiso para eliminar definitivamente nombres de característica')) {
            return $no;
        }

        return $this->accionPapelera($request, 'inventarios.fn_caracteristicas_nombres_eliminar_definitivo', 'eliminarDefinitivo');
    }

    public function vaciarPapelera(Request $request)
    {
        if ($no = $this->exigirPermiso('allCaracteristicasNombres', 'vaciar',
                'No tiene permiso para vaciar la papelera de nombres de característica')) {
            return $no;
        }

        return $this->accionPapelera($request, 'inventarios.fn_caracteristicas_nombres_papelera_vaciar', 'vaciarPapelera', false);
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
                    return $this->errorResponse('No se indicó ningún nombre', 422);
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
            sistemaLog('info', "Papelera de nombres de característica: $nombre", ['data' => $r['data'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', "Error en $nombre de nombres de característica", ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
