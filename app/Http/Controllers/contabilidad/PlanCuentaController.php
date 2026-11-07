<?php

namespace App\Http\Controllers\contabilidad;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * CRUD del plan de cuentas (contabilidad.plan_cuentas).
 *
 * Es el mismo árbol de inventarios.categorias —no pagina, porque un árbol
 * partido en páginas deja la mitad de los padres fuera, y tiene una ruta
 * `mover`, que es lo que usa el arrastre de la rejilla— con dos diferencias:
 *
 *   · NO TIENE TOPE DE NIVELES. El de categorías admite cuatro.
 *   · Las cuentas llevan código, tipo y naturaleza, y de ellos salen el
 *     balance, el estado de resultados y de qué lado suma cada asiento.
 *
 * Toda la lógica vive en contabilidad.fn_plan_cuentas_*; aquí sólo se valida
 * la entrada y se traduce la respuesta.
 *
 *   GET    contabilidad/planCuenta/allPlanCuentas[?activos=1]   el árbol entero, ordenado
 *   GET    contabilidad/planCuenta/listPlanCuentas[?activos=0]  lo mismo, para los combos
 *   GET    contabilidad/planCuenta/findByIdPlanCuenta/{id}
 *   GET    contabilidad/planCuenta/codigoSugerido[?padre_id=]   el siguiente código libre
 *   POST   contabilidad/planCuenta/addPlanCuenta
 *   POST   contabilidad/planCuenta/editPlanCuenta/{id}
 *   POST   contabilidad/planCuenta/activarPlanCuenta/{id}       { activo? }; sin ella, alterna
 *   POST   contabilidad/planCuenta/moverPlanCuenta/{id}         { padre_id, antes_de }
 *   DELETE contabilidad/planCuenta/deletePlanCuenta/{id}
 */
class PlanCuentaController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio o viene mal
        'P0006' => 409,   // código repetido, o nombre repetido entre hermanas
        'P0013' => 404,   // la cuenta no existe
        'P0014' => 409,   // no se puede eliminar: tiene subcuentas
        'P0016' => 422,   // la cuenta padre no existe
        'P0019' => 404,   // la cuenta no está en la papelera
        'P0021' => 409,   // no se puede marcar «es de movimiento»: tiene subcuentas
        'P0022' => 409,   // el tipo no es el de la rama
    ];

    private const TIPOS       = 'ACTIVO,PASIVO,PATRIMONIO,INGRESO,COSTO,GASTO,ORDEN';
    private const NATURALEZAS = 'DEUDORA,ACREEDORA';

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
            // El código es la espina dorsal del plan: por él se busca, por él
            // se ordena y es lo que se teclea en un asiento
            'codigo'        => 'required|string|max:30|regex:/^[0-9A-Za-z]([0-9A-Za-z._-]*[0-9A-Za-z])?$/',
            'nombre'        => 'required|string|min:2|max:150',
            'descripcion'   => 'nullable|string|max:2000',
            // Sin tipo se hereda el de la cuenta padre; en una raíz es
            // obligatorio y lo exige la función
            'tipo'          => 'nullable|string|in:' . self::TIPOS,
            'naturaleza'    => 'nullable|string|in:' . self::NATURALEZAS,
            'activo'        => 'nullable|boolean',
            // true = recibe asientos; false = sólo agrupa
            'es_movimiento' => 'nullable|boolean',
        ];
    }

    private function mensajes(): array
    {
        return [
            'codigo.required' => 'El código de la cuenta es obligatorio',
            'codigo.max'      => 'El código no puede superar los 30 caracteres',
            'codigo.regex'    => 'El código sólo admite letras, números, puntos, guiones y rayas bajas, y no puede empezar ni acabar en separador',
            'nombre.required' => 'El nombre de la cuenta es obligatorio',
            'nombre.min'      => 'El nombre debe tener al menos 2 caracteres',
            'nombre.max'      => 'El nombre no puede superar los 150 caracteres',
            'tipo.in'         => 'El tipo de cuenta no es válido',
            'naturaleza.in'   => 'La naturaleza debe ser DEUDORA o ACREEDORA',
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
     * —el mismo trato que allCategorias y allMenus—.
     */
    public function allPlanCuentas(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '0') === '1';
            $result = DB::selectOne('SELECT contabilidad.fn_plan_cuentas_listar(?::BOOLEAN) as result', [$soloActivos]);
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar el plan de cuentas', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allPlanCuentas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Lo mismo, para los combos (trae la ruta completa y si es de movimiento). */
    public function listPlanCuentas(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $result = DB::selectOne('SELECT contabilidad.fn_plan_cuentas_listar(?::BOOLEAN) as result', [$soloActivos]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'] ?? [], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listPlanCuentas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdPlanCuenta($id)
    {
        try {
            $result = DB::selectOne('SELECT contabilidad.fn_plan_cuentas_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdPlanCuenta', ['message' => $e->getMessage(), 'cuenta_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * El siguiente código libre bajo una cuenta.
     *
     * En un plan de cuentas el código no se inventa: sigue al del padre y al
     * de la última hermana. Esto es lo que rellena el campo al abrir la ficha,
     * para que nadie tenga que mirar el árbol y contar.
     */
    public function codigoSugerido(Request $request)
    {
        try {
            $padre = $request->input('padre_id');
            $result = DB::selectOne(
                'SELECT contabilidad.fn_plan_cuentas_codigo_sugerido(?::BIGINT) as result',
                [$padre !== null && $padre !== '' ? (int) $padre : null]
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo sugerir un código', 404);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en codigoSugerido', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al sugerir el código', 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addPlanCuenta(Request $request)
    {
        try {
            $datos = $this->datosDe($request);
            $validator = Validator::make($datos, $this->reglas() + ['padre_id' => 'nullable|integer'], $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT contabilidad.fn_plan_cuentas_crear(?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::BIGINT, ?::TEXT, ?::BOOLEAN, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $d['codigo'],
                    $d['nombre'],
                    // Vacíos: la función hereda el tipo del padre y toma la
                    // naturaleza del tipo
                    $d['tipo'] ?? null,
                    $d['naturaleza'] ?? null,
                    isset($d['padre_id']) && $d['padre_id'] !== '' ? (int) $d['padre_id'] : null,
                    $d['descripcion'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                    // Por omisión, de movimiento: la mayoría de las que se
                    // crean son hojas. Si luego se le cuelga una subcuenta,
                    // la función se lo quita sola.
                    array_key_exists('es_movimiento', $d) ? (bool) $d['es_movimiento'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Cuenta creada', ['cuenta_id' => $r['data']['id'] ?? null, 'codigo' => $d['codigo']]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addPlanCuenta rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addPlanCuenta', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear la cuenta', 500);
        }
    }

    /**
     * Cambia lo que se ve en el formulario.
     *
     * NO CAMBIA DE PADRE: mover es otra cosa —ciclos, nivel de todo lo que
     * cuelga, renumerar hermanas— y tiene su propia ruta. El tipo sí cambia
     * aquí, y la función lo baja a toda la rama.
     */
    public function editPlanCuenta(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT contabilidad.fn_plan_cuentas_modificar(?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::TEXT, ?::BOOLEAN, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    $d['codigo'],
                    $d['nombre'],
                    $d['tipo'] ?? null,
                    $d['naturaleza'] ?? null,
                    $d['descripcion'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                    array_key_exists('es_movimiento', $d) ? (bool) $d['es_movimiento'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Cuenta actualizada', ['cuenta_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editPlanCuenta rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'cuenta_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editPlanCuenta', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cuenta_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar la cuenta', 500);
        }
    }

    public function activarPlanCuenta(Request $request, $id)
    {
        try {
            // El booleano con filter_var: "false" en texto es true a secas
            $activo = $request->exists('activo') && $request->input('activo') !== null && $request->input('activo') !== ''
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE)
                : null;

            $result = DB::selectOne(
                'SELECT contabilidad.fn_plan_cuentas_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 500);
            }

            sistemaLog('info', 'Cuenta activada/desactivada', ['cuenta_id' => $id, 'activo' => $r['data']['activo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarPlanCuenta', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cuenta_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cambiar el estado de la cuenta', 500);
        }
    }

    /**
     * Mover en el árbol (lo que hace el arrastre de la rejilla).
     *
     * `padre_id` nulo la sube a la raíz; `antes_de` dice delante de qué
     * hermana queda, y sin él se va al final.
     *
     * La función no levanta excepción: contesta success=false con un
     * error_code (CICLO, TIPO_DISTINTO, NOMBRE_DUPLICADO…), y cada uno tiene
     * su mensaje para la pantalla. Todos son 409: es un conflicto con la forma
     * que tiene el árbol ahora mismo, no un error del servidor.
     */
    public function moverPlanCuenta(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);

            $result = DB::selectOne(
                'SELECT contabilidad.fn_plan_cuentas_mover(?::BIGINT, ?::BIGINT, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    isset($d['padre_id']) && $d['padre_id'] !== '' ? (int) $d['padre_id'] : null,
                    isset($d['antes_de']) && $d['antes_de'] !== '' ? (int) $d['antes_de'] : null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                sistemaLog('warning', 'moverPlanCuenta rechazada',
                           ['cuenta_id' => $id, 'error_code' => $r['error_code'] ?? null]);
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 409);
            }

            sistemaLog('info', 'Cuenta movida', ['cuenta_id' => $id, 'padre_id' => $d['padre_id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en moverPlanCuenta', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cuenta_id' => $id]);
            return $this->errorResponse('Ocurrió un error al mover la cuenta', 500);
        }
    }

    public function deletePlanCuenta(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT contabilidad.fn_plan_cuentas_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Cuenta enviada a la papelera', ['cuenta_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deletePlanCuenta rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'cuenta_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deletePlanCuenta', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cuenta_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar la cuenta', 500);
        }
    }

    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================
    //
    // «Eliminar» una cuenta es un borrado lógico: sale del árbol y de los
    // combos, deja de contar como subcuenta de su madre, y desde la papelera
    // se restaura o se borra de verdad. Su código, en cambio, SIGUE OCUPADO
    // mientras esté ahí, para que al restaurarla lo encuentre libre.
    //
    // Lo propio del árbol lo resuelven las funciones de base: no se restaura
    // lo que cuelga de algo que sigue en la papelera, y el borrado definitivo
    // va de lo más hondo a lo más alto.

    /** Cuentas que están en la papelera (más reciente primero). */
    public function papelera()
    {
        try {
            $result = DB::selectOne('SELECT contabilidad.fn_plan_cuentas_papelera_listar() as result');
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'], 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera del plan de cuentas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar la papelera', 500);
        }
    }

    /** Saca de la papelera una o varias cuentas. Body: { ids: [..] } */
    public function restaurarPlanCuentas(Request $request)
    {
        return $this->accionPapelera($request, 'contabilidad.fn_plan_cuentas_restaurar', 'restaurarPlanCuentas');
    }

    /** Borrado real de lo que está en la papelera. Body: { ids: [..] } */
    public function eliminarDefinitivo(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar»,
        // que es otro distinto de «papelera». Se comprueba AQUÍ y no
        // sólo en el front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allPlanCuentas', 'vaciar',
                'No tiene permiso para eliminar definitivamente cuentas')) {
            return $no;
        }

        return $this->accionPapelera($request, 'contabilidad.fn_plan_cuentas_eliminar_definitivo', 'eliminarDefinitivo');
    }

    /** Borrado real de TODO lo que hay en la papelera. */
    public function vaciarPapelera(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar»,
        // que es otro distinto de «papelera». Se comprueba AQUÍ y no
        // sólo en el front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allPlanCuentas', 'vaciar',
                'No tiene permiso para vaciar la papelera del plan de cuentas')) {
            return $no;
        }

        return $this->accionPapelera($request, 'contabilidad.fn_plan_cuentas_papelera_vaciar', 'vaciarPapelera', false);
    }

    /**
     * El tronco común de restaurar / eliminar definitivo / vaciar: validar,
     * llamar y traducir el error. No hay ficheros que borrar —una cuenta no
     * tiene imágenes—, a diferencia de la papelera de productos.
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
                    'ids.required' => 'No se indicó ninguna cuenta',
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

            sistemaLog('info', "Papelera del plan de cuentas: {$nombre}", ['data' => $r['data'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', "{$nombre} rechazado",
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', "Error en {$nombre}", ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error en la papelera del plan de cuentas', 500);
        }
    }
}
