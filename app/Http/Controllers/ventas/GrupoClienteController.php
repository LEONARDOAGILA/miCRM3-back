<?php

namespace App\Http\Controllers\ventas;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * CRUD del árbol de grupos de clientes (ventas.grupos_clientes).
 *
 * Es el mismo árbol que inventarios.categorias —jerárquico, sin paginar, con
 * su ruta `mover` para el arrastre de la rejilla y su papelera—, pero aquí el
 * árbol CARGA VALORES: forma de pago, cupo de crédito, días de crédito y
 * descuento. Las cuatro son anulables y un nulo no es un cero: es «lo que
 * diga el grupo de arriba». Por eso cada ficha trae `condiciones`, con lo que
 * de verdad se usaría y de dónde sale.
 *
 * Toda la lógica vive en ventas.fn_grupos_clientes_*; aquí sólo se valida la
 * entrada y se traduce la respuesta.
 *
 *   GET    ventas/grupoCliente/allGruposClientes[?activos=1]  el árbol entero, ordenado
 *   GET    ventas/grupoCliente/listGruposClientes[?activos=0] lo mismo, para los combos
 *   GET    ventas/grupoCliente/findByIdGrupoCliente/{id}
 *   POST   ventas/grupoCliente/addGrupoCliente
 *   POST   ventas/grupoCliente/editGrupoCliente/{id}
 *   POST   ventas/grupoCliente/activarGrupoCliente/{id}       { activo? }; sin ella, alterna
 *   POST   ventas/grupoCliente/moverGrupoCliente/{id}         { padre_id, antes_de }
 *   POST   ventas/grupoCliente/predeterminarGrupoCliente/{id} { predeterminado? }
 *   DELETE ventas/grupoCliente/deleteGrupoCliente/{id}
 */
class GrupoClienteController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio o una condición no vale
        'P0006' => 409,   // nombre duplicado entre hermanos
        'P0013' => 404,   // el grupo no existe
        'P0014' => 409,   // no se puede eliminar: tiene subgrupos o clientes
        'P0015' => 422,   // valor inválido (nivel máximo)
        'P0016' => 422,   // el grupo padre no existe
        'P0019' => 404,   // el grupo no está en la papelera
    ];

    /** Lo que admite `forma_pago`, igual que en ventas.clientes */
    private const FORMAS_PAGO = 'EFECTIVO,TRANSFERENCIA,TARJETA,CHEQUE,CREDITO';

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
            // Las cuatro condiciones comerciales. Vacías NO son cero: son
            // «lo que diga el grupo de arriba», así que `nullable` de verdad.
            'forma_pago'     => 'nullable|string|in:' . self::FORMAS_PAGO,
            'limite_credito' => 'nullable|numeric|min:0|max:9999999999',
            'dias_credito'   => 'nullable|integer|min:0|max:3650',
            'descuento'      => 'nullable|numeric|min:0|max:100',
        ];
    }

    private function mensajes(): array
    {
        return [
            'nombre.required'       => 'El nombre del grupo es obligatorio',
            'nombre.min'            => 'El nombre debe tener al menos 2 caracteres',
            'nombre.max'            => 'El nombre no puede superar los 100 caracteres',
            'forma_pago.in'         => 'Esa forma de pago no existe',
            'limite_credito.min'    => 'El cupo de crédito no puede ser negativo',
            'dias_credito.min'      => 'Los días de crédito no pueden ser negativos',
            'descuento.min'         => 'El descuento no puede ser negativo',
            'descuento.max'         => 'El descuento no puede pasar del 100 %',
        ];
    }

    /**
     * Las cuatro condiciones, listas para la función.
     *
     * Vacío ('' o ausente) viaja como NULL: en la tabla eso significa heredar
     * del grupo de arriba, y es justo lo que quiere decir dejar el campo en
     * blanco en la ficha. Un 0 escrito a mano sí llega como 0.
     */
    private function condicionesDe(array $d): array
    {
        $oNulo = fn (string $campo) => (isset($d[$campo]) && $d[$campo] !== '' && $d[$campo] !== null)
            ? $d[$campo] : null;

        return [
            $oNulo('forma_pago'),
            $oNulo('limite_credito') !== null ? (float) $d['limite_credito'] : null,
            $oNulo('dias_credito')   !== null ? (int) $d['dias_credito']     : null,
            $oNulo('descuento')      !== null ? (float) $d['descuento']      : null,
        ];
    }

    // ================================================================
    // LISTAR
    // ================================================================

    /**
     * El árbol entero, ya ordenado para pintarlo.
     *
     * Sin paginar a propósito: las filas vienen en el orden en que se dibujan
     * y cada una trae su `nivel`, que es lo que la rejilla usa para la
     * sangría —el mismo trato que allCategorias—.
     */
    public function allGruposClientes(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '0') === '1';
            $result = DB::selectOne('SELECT ventas.fn_grupos_clientes_listar(?::BOOLEAN) as result', [$soloActivos]);
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar el árbol', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allGruposClientes', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Lo mismo, para el selector de la ficha del cliente (trae la ruta completa). */
    public function listGruposClientes(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $result = DB::selectOne('SELECT ventas.fn_grupos_clientes_listar(?::BOOLEAN) as result', [$soloActivos]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'] ?? [], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listGruposClientes', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdGrupoCliente($id)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_grupos_clientes_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdGrupoCliente', ['message' => $e->getMessage(), 'grupo_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addGrupoCliente(Request $request)
    {
        try {
            $datos = $this->datosDe($request);
            $validator = Validator::make($datos, $this->reglas() + ['padre_id' => 'nullable|integer'], $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_grupos_clientes_crear(?::VARCHAR, ?::BIGINT, ?::TEXT, ?::VARCHAR, ?::BOOLEAN, '
                . '?::VARCHAR, ?::NUMERIC, ?::INTEGER, ?::NUMERIC, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $d['nombre'],
                    isset($d['padre_id']) && $d['padre_id'] !== '' ? (int) $d['padre_id'] : null,
                    $d['descripcion'] ?? null,
                    $d['icono'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->condicionesDe($d), $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Grupo de clientes creado', ['grupo_id' => $r['data']['id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addGrupoCliente rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addGrupoCliente', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear el grupo', 500);
        }
    }

    /**
     * Cambia lo que se ve en el formulario.
     *
     * NO CAMBIA DE PADRE: mover es otra cosa —ciclos, nivel de todo lo que
     * cuelga, renumerar hermanos— y tiene su propia ruta.
     */
    public function editGrupoCliente(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_grupos_clientes_modificar(?::BIGINT, ?::VARCHAR, ?::TEXT, ?::VARCHAR, ?::BOOLEAN, '
                . '?::VARCHAR, ?::NUMERIC, ?::INTEGER, ?::NUMERIC, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    $d['nombre'],
                    $d['descripcion'] ?? null,
                    $d['icono'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->condicionesDe($d), $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Grupo de clientes actualizado', ['grupo_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editGrupoCliente rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'grupo_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editGrupoCliente', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'grupo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar el grupo', 500);
        }
    }

    public function activarGrupoCliente(Request $request, $id)
    {
        try {
            // El booleano con filter_var: "false" en texto es true a secas
            $activo = $request->exists('activo') && $request->input('activo') !== null && $request->input('activo') !== ''
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE)
                : null;

            $result = DB::selectOne(
                'SELECT ventas.fn_grupos_clientes_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 500);
            }

            sistemaLog('info', 'Grupo de clientes activado/desactivado', ['grupo_id' => $id, 'activo' => $r['data']['activo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarGrupoCliente', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'grupo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cambiar el estado del grupo', 500);
        }
    }

    /**
     * El grupo predeterminado: el que la ficha de un cliente nuevo trae
     * puesto.
     *
     * SÓLO HAY UNO: marcar éste baja el que estuviera. Se manda el valor que
     * se quiere y no «lo contrario de lo que hay», igual que en la casilla de
     * activo, para que dos personas pulsando a la vez acaben donde querían.
     *
     * La función contesta success=false con su motivo —inactivo, en la
     * papelera, no existe— y cada uno tiene su código.
     */
    public function predeterminarGrupoCliente(Request $request, $id)
    {
        try {
            // El booleano con filter_var: "false" en texto es true a secas
            $valor = $request->exists('predeterminado') && $request->input('predeterminado') !== null && $request->input('predeterminado') !== ''
                ? filter_var($request->input('predeterminado'), FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE)
                : null;

            $result = DB::selectOne(
                'SELECT ventas.fn_grupos_clientes_predeterminar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $valor], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                $codigo = ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 409;
                sistemaLog('warning', 'predeterminarGrupoCliente rechazada',
                           ['grupo_id' => $id, 'error_code' => $r['error_code'] ?? null]);
                return $this->errorResponse($r['message'], $codigo);
            }

            sistemaLog('info', 'Grupo predeterminado', ['grupo_id' => $id, 'predeterminado' => $r['data']['predeterminado'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en predeterminarGrupoCliente', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'grupo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al marcar el grupo predeterminado', 500);
        }
    }

    /**
     * Mover en el árbol (lo que hace el arrastre de la rejilla).
     *
     * `padre_id` nulo lo sube a la raíz; `antes_de` dice delante de qué
     * hermano queda, y sin él se va al final. Mover cambia las condiciones
     * que HEREDA todo lo que cuelga: las propias no se tocan.
     *
     * La función no levanta excepción: contesta success=false con un
     * error_code (CICLO, NIVEL_MAXIMO, NOMBRE_DUPLICADO…), y cada uno tiene
     * su mensaje para la pantalla. Todos son 409: es un conflicto con la
     * forma que tiene el árbol ahora mismo, no un error del servidor.
     */
    public function moverGrupoCliente(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);

            $result = DB::selectOne(
                'SELECT ventas.fn_grupos_clientes_mover(?::BIGINT, ?::BIGINT, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    isset($d['padre_id']) && $d['padre_id'] !== '' ? (int) $d['padre_id'] : null,
                    isset($d['antes_de']) && $d['antes_de'] !== '' ? (int) $d['antes_de'] : null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                sistemaLog('warning', 'moverGrupoCliente rechazada',
                           ['grupo_id' => $id, 'error_code' => $r['error_code'] ?? null]);
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 409);
            }

            sistemaLog('info', 'Grupo de clientes movido', ['grupo_id' => $id, 'padre_id' => $d['padre_id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en moverGrupoCliente', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'grupo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al mover el grupo', 500);
        }
    }

    public function deleteGrupoCliente(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_grupos_clientes_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Grupo de clientes enviado a la papelera', ['grupo_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteGrupoCliente rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'grupo_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteGrupoCliente', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'grupo_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar el grupo', 500);
        }
    }

    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================
    //
    // «Eliminar» un grupo es un borrado lógico: sale del árbol y del selector
    // de la ficha del cliente, deja de contar como subgrupo de su padre, y
    // desde la papelera se restaura o se borra de verdad. Un grupo con
    // clientes dentro no se puede eliminar: primero hay que cambiarlos de
    // grupo, porque si no se quedarían sin condiciones de las que heredar.
    //
    // Lo propio del árbol lo resuelven las funciones de base: no se restaura
    // lo que cuelga de algo que sigue en la papelera, y el borrado definitivo
    // va de lo más hondo a lo más alto.

    /** Grupos que están en la papelera (más reciente primero). */
    public function papelera()
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_grupos_clientes_papelera_listar() as result');
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'], 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de grupos de clientes', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar la papelera', 500);
        }
    }

    /** Saca de la papelera uno o varios grupos. Body: { ids: [..] } */
    public function restaurarGruposClientes(Request $request)
    {
        return $this->accionPapelera($request, 'ventas.fn_grupos_clientes_restaurar', 'restaurarGruposClientes');
    }

    /** Borrado real de lo que está en la papelera. Body: { ids: [..] } */
    public function eliminarDefinitivo(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar»,
        // que es otro distinto de «papelera». Se comprueba AQUÍ y no
        // sólo en el front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allGruposClientes', 'vaciar',
                'No tiene permiso para eliminar definitivamente grupos de clientes')) {
            return $no;
        }

        return $this->accionPapelera($request, 'ventas.fn_grupos_clientes_eliminar_definitivo', 'eliminarDefinitivo');
    }

    /** Borrado real de TODO lo que hay en la papelera. */
    public function vaciarPapelera(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar»,
        // que es otro distinto de «papelera». Se comprueba AQUÍ y no
        // sólo en el front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allGruposClientes', 'vaciar',
                'No tiene permiso para vaciar la papelera de grupos de clientes')) {
            return $no;
        }

        return $this->accionPapelera($request, 'ventas.fn_grupos_clientes_papelera_vaciar', 'vaciarPapelera', false);
    }

    /**
     * El tronco común de restaurar / eliminar definitivo / vaciar: validar,
     * llamar y traducir el error. No hay ficheros que borrar —un grupo no
     * tiene imágenes—, a diferencia de la papelera de clientes.
     */
    private function accionPapelera(Request $request, string $funcion, string $nombre, bool $conIds = true)
    {
        try {
            $auditoria = $this->auditoria($request);

            if ($conIds) {
                $validator = Validator::make($request->all(), [
                    'ids'   => 'required|array|min:1|max:500',
                    'ids.*' => 'integer',
                ], [
                    'ids.required' => 'No se indicó ningún grupo',
                ]);
                if ($validator->fails()) {
                    return $this->errorResponse($validator->errors()->first(), 422);
                }
                $result = DB::selectOne(
                    "SELECT {$funcion}(?::JSONB, " . self::CASTS_AUDIT . ") as result",
                    array_merge([json_encode(array_map('intval', $validator->validated()['ids']))], $auditoria)
                );
            } else {
                $result = DB::selectOne("SELECT {$funcion}(" . self::CASTS_AUDIT . ") as result", $auditoria);
            }
            $r = json_decode($result->result, true);

            sistemaLog('info', "Papelera de grupos de clientes: {$nombre}", ['data' => $r['data'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', "{$nombre} rechazado",
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', "Error en {$nombre}", ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error en la papelera de grupos de clientes', 500);
        }
    }
}
