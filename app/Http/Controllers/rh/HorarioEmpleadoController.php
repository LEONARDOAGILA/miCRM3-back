<?php

namespace App\Http\Controllers\rh;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * CRUD de horarios de trabajo del personal (rh.horarios_empleados).
 *
 * Mismo esquema que rh\CargoController: toda la lógica vive en las funciones
 * PL/pgSQL rh.fn_horarios_empleados_* (validaciones, auditoría, transacción);
 * aquí sólo se valida la entrada, se llama a la función con el contexto del
 * usuario autenticado y se traduce la respuesta.
 *
 * NO ES seguridad\HorarioController. Aquél maneja el horario de ACCESO AL CRM
 * (seguridad.chorarios, una franja por día, lo usa el middleware para cerrar
 * la sesión fuera de hora). Éste maneja el horario de TRABAJO, con hasta
 * cuatro jornadas por día, y es contra el que se miden los atrasos de
 * rh.marcaciones.
 *
 *   GET    rh/horarioEmpleado/allHorariosEmpleados    listado paginado (grilla)
 *   GET    rh/horarioEmpleado/listHorariosEmpleados   los activos (selector)
 *   GET    rh/horarioEmpleado/getHorarioEmpleado/{id} la ficha con sus jornadas
 *   POST   rh/horarioEmpleado/addHorarioEmpleado
 *   POST   rh/horarioEmpleado/editHorarioEmpleado/{id}
 *   POST   rh/horarioEmpleado/activarHorarioEmpleado/{id}   { activo? }; sin ella, alterna
 *   DELETE rh/horarioEmpleado/deleteHorarioEmpleado/{id}    a la papelera
 *   GET    rh/horarioEmpleado/papelera
 *   POST   rh/horarioEmpleado/restaurarHorariosEmpleados    { ids: [...] }
 *   POST   rh/horarioEmpleado/eliminarDefinitivo            { ids: [...] }  (permiso «vaciar»)
 *   DELETE rh/horarioEmpleado/vaciarPapelera                (permiso «vaciar»)
 *   GET    rh/horarioEmpleado/evaluar/{id}?fecha_hora=      el atraso de una marcación
 */
class HorarioEmpleadoController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;
    use \App\Http\Controllers\Concerns\FiltrosDeColumna;

    /**
     * Por qué columnas deja filtrar la rejilla, y de qué tipo.
     *
     * Es una lista blanca, no una comprobación: lo que mande el navegador se
     * compara contra esto y lo que no esté se tira. El nombre de la columna
     * acaba dentro de una consulta, y de las dos formas de evitar que eso sea
     * un agujero —escapar o no aceptar nombres libres— ésta es la que no
     * depende de acordarse de escapar.
     *
     * `activo` se queda fuera a propósito: en la rejilla es una casilla, y
     * escribir texto para filtrarla no se entiende.
     *
     * Tiene que decir lo mismo que COLUMNAS_FILTRABLES de la pantalla y que la
     * lista de rh.fn_horarios_empleados_listar_paginado.
     */
    private const COLUMNAS_FILTRABLES = [
        'id'             => 'numero',
        'tolerancia_min' => 'numero',
        'num_dias'       => 'numero',
        'num_jornadas'   => 'numero',
        'nombre'         => 'texto',
        'descripcion'    => 'texto',
        'created_by'     => 'texto',
        'updated_by'     => 'texto',
        // Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
        'created_at'     => 'texto',
        'updated_at'     => 'texto',
    ];

    /**
     * SQLSTATE que usan las funciones para las reglas de negocio.
     * Son errores del usuario, no fallos del servidor: se responden como 4xx.
     */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio (nombre, jornadas, horas)
        'P0006' => 409,   // nombre duplicado
        'P0013' => 404,   // el horario no existe
        'P0014' => 409,   // no se puede borrar: tiene registros asociados
        'P0015' => 422,   // valor inválido (día, jornada, horas que se pisan)
        'P0019' => 404,   // no está en la papelera (o ya estaba)
        '22007' => 422,   // una hora que PostgreSQL no sabe leer
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

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

    /**
     * Cuerpo de la petición: JSON plano, o el envoltorio { json: "…" } que
     * usan los formularios que mandan FormData. Se admiten los dos.
     */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    /** Reglas comunes a crear y modificar. */
    private function reglas(): array
    {
        return [
            'nombre'                 => 'required|string|min:3|max:100',
            'descripcion'            => 'nullable|string|max:250',
            'tolerancia_min'         => 'nullable|integer|min:0|max:240',
            'activo'                 => 'nullable|boolean',
            'jornadas'               => 'required|array|min:1|max:28',
            'jornadas.*.dia'         => 'required|integer|min:1|max:7',
            'jornadas.*.jornada'     => 'required|integer|min:1|max:4',
            // `HH:MM` o `HH:MM:SS`, que es lo que da <input type="time">.
            // Se valida AQUI: un texto que no es una hora reventaba en el
            // cast de PostgreSQL y salia como un 500, cuando el dato es de
            // quien llama.
            'jornadas.*.hora_inicio' => ['required', 'string', 'regex:/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/'],
            'jornadas.*.hora_fin'    => ['required', 'string', 'regex:/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/'],
            'jornadas.*.activo'      => 'nullable|boolean',
        ];
    }

    /** Mensajes en español (el locale de la app es 'en'). */
    private function mensajes(): array
    {
        return [
            'nombre.required'           => 'El nombre del horario es obligatorio',
            'nombre.min'                => 'El nombre del horario debe tener al menos 3 caracteres',
            'nombre.max'                => 'El nombre del horario no puede superar los 100 caracteres',
            'descripcion.max'           => 'La descripción no puede superar los 250 caracteres',
            'tolerancia_min.integer'    => 'La tolerancia debe ser un número de minutos',
            'tolerancia_min.min'        => 'La tolerancia no puede ser negativa',
            'tolerancia_min.max'        => 'La tolerancia no puede superar los 240 minutos',
            'jornadas.required'         => 'El horario necesita al menos una jornada',
            'jornadas.min'              => 'El horario necesita al menos una jornada',
            'jornadas.max'              => 'Son siete días con cuatro jornadas como mucho: 28 en total',
            'jornadas.*.dia.required'   => 'Hay una jornada sin día',
            'jornadas.*.jornada.max'    => 'Cada día admite hasta 4 jornadas',
            'jornadas.*.hora_inicio.required' => 'Falta una hora de inicio',
            'jornadas.*.hora_fin.required'    => 'Falta una hora de fin',
            'jornadas.*.hora_inicio.regex'    => 'La hora de inicio no tiene el formato HH:MM',
            'jornadas.*.hora_fin.regex'       => 'La hora de fin no tiene el formato HH:MM',
        ];
    }

    /**
     * Las jornadas, listas para la función.
     *
     * Las horas llegan del <input type="time"> como «08:00» o «08:00:00»; se
     * dejan tal cual y las convierte la base, que es la que sabe de `time`.
     */
    private function jornadasJson(array $datos): string
    {
        return json_encode(array_values(array_map(fn($j) => [
            'dia'         => (int) $j['dia'],
            'jornada'     => (int) $j['jornada'],
            'hora_inicio' => $j['hora_inicio'],
            'hora_fin'    => $j['hora_fin'],
            'activo'      => array_key_exists('activo', $j) ? (bool) $j['activo'] : true,
        ], $datos['jornadas'])));
    }

    // ================================================================
    // LISTAR
    // ================================================================

    public function allHorariosEmpleados(Request $request)
    {
        try {
            // Los filtros de la cabecera de la rejilla. Se aplican AQUÍ y no
            // en el navegador: la pantalla pagina, así que ag-Grid sólo tiene
            // las filas de la página y filtrar ahí buscaría dentro de quince.
            $filtros = $this->filtrosDeColumna($request->input('filtros'), self::COLUMNAS_FILTRABLES);

            $result = DB::selectOne(
                'SELECT rh.fn_horarios_empleados_listar_paginado(?::INTEGER, ?::INTEGER, ?::TEXT, ?::JSONB) as result',
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
            sistemaLog('error', 'Error en allHorariosEmpleados', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Los que se pueden elegir (activos y fuera de la papelera), paginados. */
    public function listHorariosEmpleados(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT rh.fn_horarios_empleados_listar_paginado_activos(?::INTEGER, ?::INTEGER, ?::TEXT) as result',
                [(int) $request->input('page', 1),
                 (int) $request->input('per_page', 15),
                 (string) $request->input('search', '')]
            );
            return $this->successResponse(json_decode($result->result, true), 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listHorariosEmpleados', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function getHorarioEmpleado($id)
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_horarios_empleados_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'], 404, $r['error_code'] ?? null);
            }
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en getHorarioEmpleado', ['message' => $e->getMessage(), 'horario_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // CREAR / MODIFICAR / ACTIVAR / ELIMINAR
    // ================================================================

    public function addHorarioEmpleado(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne('
                SELECT rh.fn_horarios_empleados_crear(
                    ?::VARCHAR,   -- p_nombre
                    ?::VARCHAR,   -- p_descripcion
                    ?::INTEGER,   -- p_tolerancia_min
                    ?::BOOLEAN,   -- p_activo
                    ?::JSONB,     -- p_jornadas
                    ' . self::CASTS_AUDIT . '
                ) as result
            ', array_merge([
                $d['nombre'],
                $d['descripcion'] ?? null,
                (int) ($d['tolerancia_min'] ?? 0),
                array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                $this->jornadasJson($d),
            ], $this->auditoria($request)));

            $r = json_decode($result->result, true);
            sistemaLog('info', 'Horario de empleados creado', ['horario_id' => $r['data']['id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addHorarioEmpleado rechazado',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addHorarioEmpleado', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear el horario', 500);
        }
    }

    public function editHorarioEmpleado(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne('
                SELECT rh.fn_horarios_empleados_modificar(
                    ?::BIGINT,    -- p_id
                    ?::VARCHAR,   -- p_nombre
                    ?::VARCHAR,   -- p_descripcion
                    ?::INTEGER,   -- p_tolerancia_min
                    ?::BOOLEAN,   -- p_activo
                    ?::JSONB,     -- p_jornadas
                    ' . self::CASTS_AUDIT . '
                ) as result
            ', array_merge([
                (int) $id,
                $d['nombre'],
                $d['descripcion'] ?? null,
                (int) ($d['tolerancia_min'] ?? 0),
                array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                $this->jornadasJson($d),
            ], $this->auditoria($request)));

            $r = json_decode($result->result, true);
            sistemaLog('info', 'Horario de empleados actualizado', ['horario_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editHorarioEmpleado rechazado',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'horario_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editHorarioEmpleado', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'horario_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar el horario', 500);
        }
    }

    /**
     * Pone `activo` y nada más.
     *
     * Existe aparte de editHorarioEmpleado porque aquélla REESCRIBE LAS
     * JORNADAS, y bajar una casilla desde la rejilla no tiene por qué tocar
     * las veintiocho franjas de un horario.
     *
     * `activo` es opcional: sin él, la función alterna. La pantalla sí manda
     * el valor que quiere para que dos personas pulsando a la vez no acaben
     * peleando por «lo contrario de lo que había».
     */
    public function activarHorarioEmpleado(Request $request, $id)
    {
        try {
            // El booleano con filter_var: "false" en texto es true a secas
            $activo = $request->exists('activo') && $request->input('activo') !== null && $request->input('activo') !== ''
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE)
                : null;

            $result = DB::selectOne(
                'SELECT rh.fn_horarios_empleados_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                sistemaLog('warning', 'activarHorarioEmpleado rechazado', ['horario_id' => $id, 'error_code' => $r['error_code'] ?? null]);
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 500);
            }

            sistemaLog('info', 'Horario de empleados activado/desactivado', ['horario_id' => $id, 'activo' => $r['data']['activo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarHorarioEmpleado', ['message' => $e->getMessage(), 'horario_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cambiar el estado del horario', 500);
        }
    }

    public function deleteHorarioEmpleado(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT rh.fn_horarios_empleados_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            // Las jornadas se quedan: el horario va a la papelera y puede
            // volver con ellas. Se borran en eliminarDefinitivo / vaciar.
            sistemaLog('info', 'Horario de empleados enviado a la papelera', ['horario_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteHorarioEmpleado rechazado',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'horario_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteHorarioEmpleado', ['message' => $e->getMessage(), 'horario_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar el horario', 500);
        }
    }

    // ================================================================
    // EL ATRASO
    // ================================================================

    /**
     * Qué jornada le tocaba y de cuántos minutos fue el atraso.
     *
     * Es de sólo lectura y no escribe nada: la pantalla la usa para que quien
     * configura un horario pueda probarlo con una hora cualquiera antes de
     * asignárselo a nadie.
     */
    public function evaluar(Request $request, $id)
    {
        try {
            $cuando = (string) $request->input('fecha_hora', '');
            if ($cuando === '') {
                return $this->errorResponse('Indique la fecha y hora de la marcación', 422);
            }

            $result = DB::selectOne(
                'SELECT rh.fn_horarios_empleados_evaluar(?::BIGINT, ?::TIMESTAMPTZ) as result',
                [(int) $id, $cuando]
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'], 404);
            }
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            // Una fecha que PostgreSQL no entiende es culpa de quien la manda
            return $this->errorResponse('No se entiende la fecha y hora indicada', 422);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en evaluar horario', ['message' => $e->getMessage(), 'horario_id' => $id]);
            return $this->errorResponse('Ocurrió un error al evaluar el horario', 500);
        }
    }

    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================
    //
    // «Eliminar» un horario es un borrado lógico: sale del listado y del
    // selector PERO CONSERVA SUS JORNADAS. Rehacer veintiocho franjas a mano
    // es un rato, así que desde la papelera vuelve tal cual.

    /** Horarios que están en la papelera (más reciente primero). */
    public function papelera()
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_horarios_empleados_papelera_listar() as result');
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'], 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de horarios', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar la papelera', 500);
        }
    }

    /** Saca de la papelera uno o varios horarios, con sus jornadas. Body: { ids: [..] } */
    public function restaurarHorariosEmpleados(Request $request)
    {
        return $this->accionPapelera($request, 'rh.fn_horarios_empleados_restaurar', 'restaurarHorariosEmpleados');
    }

    /** Borrado real de lo que está en la papelera. Body: { ids: [..] } */
    public function eliminarDefinitivo(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar», que es
        // otro distinto de «papelera». Se comprueba AQUÍ y no sólo en el
        // front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allHorariosEmpleados', 'vaciar',
                'No tiene permiso para eliminar definitivamente horarios')) {
            return $no;
        }

        return $this->accionPapelera($request, 'rh.fn_horarios_empleados_eliminar_definitivo', 'eliminarDefinitivo');
    }

    /** Borrado real de TODO lo que hay en la papelera. */
    public function vaciarPapelera(Request $request)
    {
        if ($no = $this->exigirPermiso('allHorariosEmpleados', 'vaciar',
                'No tiene permiso para vaciar la papelera de horarios')) {
            return $no;
        }

        return $this->accionPapelera($request, 'rh.fn_horarios_empleados_papelera_vaciar', 'vaciarPapelera', false);
    }

    /**
     * El tronco común de restaurar / eliminar definitivo / vaciar: validar,
     * llamar y traducir el error.
     *
     * Un horario no tiene ficheros propios, así que aquí no hay nada que
     * borrar del disco: las jornadas se van con él por la clave foránea.
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
                    'ids.required' => 'No se indicó ningún horario',
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

            sistemaLog('info', "Papelera de horarios: {$nombre}", ['data' => $r['data'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', "{$nombre} rechazado",
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', "Error en {$nombre}", ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error en la papelera de horarios', 500);
        }
    }
}
