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
 * Gestión de clientes (ventas.gestiones): llamadas hechas, llamadas
 * programadas y reasignación de cartera. Es lo que consume la pantalla
 * gestion-clientes.
 *
 * Mismo esquema que ventas\ClienteController: la lógica vive en las funciones
 * PL/pgSQL ventas.fn_gestiones_* (validaciones, auditoría, transacción); aquí
 * se valida la entrada, se llama a la función con el contexto del usuario
 * autenticado y se traduce la respuesta.
 *
 *   GET    ventas/gestion/allGestiones?cliente_id&page&per_page&search&tipo&estado&desde&hasta
 *   GET    ventas/gestion/findByIdGestion/{id}
 *   POST   ventas/gestion/addGestion
 *   POST   ventas/gestion/editGestion/{id}
 *   POST   ventas/gestion/cerrarGestion/{id}       { resultado, nota?, duracion_minutos?, siguiente? }
 *   DELETE ventas/gestion/deleteGestion/{id}
 *   GET    ventas/gestion/agenda?usuario_id&mias&desde&hasta&vencidas&limite
 *   GET    ventas/gestion/resumen/{cliente_id}
 *   POST   ventas/gestion/reasignar/{cliente_id}   { usuario_id, motivo?, mover_agenda? }
 *   GET    ventas/gestion/asignaciones/{cliente_id}
 */
class GestionController extends Controller
{
    use ApiResponder;

    /** SQLSTATE de las reglas de negocio de ventas.fn_gestiones_* → código HTTP. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0013' => 404,   // el cliente o la gestión no existe
        'P0016' => 422,   // el usuario no existe
        'P0021' => 409,   // la gestión ya no está pendiente
        'P0022' => 422,   // la fecha no es coherente
    ];

    public function __construct() {
        $this->middleware('auth:api');
    }

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

    /** Usuario autenticado en la forma que esperan las funciones (id, login, nombre). */
    private function contextoUsuario(): array
    {
        $u = auth('api')->user();
        return [
            $u->id ?? null,
            $u->login_user ?? null,
            trim(($u->name ?? '') . ' ' . ($u->surname ?? '')) ?: null,
        ];
    }

    /**
     * Si quien pregunta es administrador.
     *
     * Manda `es_administrador` del GRUPO, que es la misma señal con la que se
     * recortan la lista de clientes, la agenda y el tablero. No se mira
     * users.type_user: ése lo pone quien crea el usuario y puede quedarse
     * atrás si luego se le cambia de grupo. La pantalla sí lo usa, pero para
     * decidir qué enseña, que es otra cosa.
     */
    private function esAdministrador(): bool
    {
        $id = auth('api')->user()->id ?? null;
        if (!$id) { return false; }

        $fila = DB::selectOne(
            'SELECT COALESCE(g.es_administrador, false) AS admin
               FROM seguridad.users u
               LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
              WHERE u.id = ?::BIGINT',
            [(int) $id]
        );
        return (bool) ($fila->admin ?? false);
    }

    /** Los mismos marcadores de auditoría que usan las demás funciones. */
    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    private function auditoria(Request $request): array
    {
        [$usuarioId, $usuarioLogin, $usuarioNombre] = $this->contextoUsuario();
        return [
            $usuarioId ? (int) $usuarioId : null,
            $usuarioLogin,
            $usuarioNombre,
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

    /** Reglas comunes a registrar y modificar una gestión. */
    private function reglas(): array
    {
        return [
            'cliente_id'        => 'required|integer',
            // El tipo sale del catálogo, no de una lista escrita aquí: si no, dar
            // de alta un tipo nuevo exigiría tocar código.
            //
            // El «pgsql.» del principio no sobra: exists: se queda con lo que hay
            // antes del primer punto como NOMBRE DE CONEXIÓN, así que sin él
            // Laravel busca una conexión llamada «ventas» y revienta.
            'tipo'              => 'nullable|string|exists:pgsql.ventas.gestiones_tipos,codigo',
            'estado'            => 'nullable|string|in:PENDIENTE,REALIZADA,CANCELADA',
            'prioridad'         => 'nullable|string|in:ALTA,MEDIA,BAJA',
            // Aquí se decide que el usuario NO escriba el asunto: por esta puerta
            // entra el formulario y se le exige el del catálogo. El texto pasa a
            // ser opcional porque lo rellena la función con el nombre del asunto.
            'asunto_id'         => 'required|integer|exists:pgsql.ventas.gestiones_asuntos,id',
            'asunto'            => 'nullable|string|min:3|max:200',
            'nota'              => 'nullable|string|max:4000',
            'usuario_id'        => 'nullable|integer|exists:pgsql.seguridad.users,id',
            'contacto_id'       => 'nullable|integer',
            'telefono'          => 'nullable|string|max:20',
            'fecha_programada'  => 'nullable|date',
            'fecha_realizada'   => 'nullable|date',
            'duracion_minutos'  => 'nullable|integer|min:0|max:1440',
            'resultado'         => 'nullable|string|in:CONTACTADO,NO_CONTESTA,BUZON,NUMERO_ERRADO,VOLVER_A_LLAMAR,INTERESADO,NO_INTERESADO,COTIZACION,VENTA,RECLAMO,OTRO',
            // Cómo la registró el vendedor; queda guardado para los reportes
            'modo_registro'     => 'nullable|string|in:AHORA,YA_HECHA,PROGRAMADA',
        ];
    }

    /** Mensajes en español (el locale de la app es 'en'). */
    private function mensajes(): array
    {
        return [
            'cliente_id.required'   => 'Debe seleccionar un cliente',
            'asunto.required'       => 'El asunto es obligatorio',
            'asunto.min'            => 'El asunto debe tener al menos 3 caracteres',
            'tipo.exists'           => 'El tipo de gestión no está en el catálogo',
            'asunto_id.required'    => 'Debe elegir el asunto de la lista',
            'asunto_id.exists'      => 'El asunto elegido ya no está en el catálogo',
            'estado.in'             => 'El estado de la gestión no es válido',
            'prioridad.in'          => 'La prioridad no es válida',
            'resultado.in'          => 'El resultado no es válido',
            'modo_registro.in'      => 'El modo de registro no es válido',
            'duracion_minutos.max'  => 'La duración no puede superar los 1440 minutos',
            'fecha_programada.date' => 'La fecha programada no es válida',
            'fecha_realizada.date'  => 'La fecha de realización no es válida',
        ];
    }

    /** Parámetros de la gestión, en el orden de la función SQL (sin id ni auditoría). */
    private function parametros(array $d, bool $conCliente): array
    {
        $vacioANull = fn ($v) => ($v === '' || $v === null) ? null : $v;
        $datos = [
            $d['tipo'] ?? 'LLAMADA',
            $d['estado'] ?? 'REALIZADA',
            $d['asunto'] ?? null,
            !empty($d['asunto_id']) ? (int) $d['asunto_id'] : null,
            $vacioANull($d['nota'] ?? null),
            !empty($d['usuario_id']) ? (int) $d['usuario_id'] : null,
            !empty($d['contacto_id']) ? (int) $d['contacto_id'] : null,
            $vacioANull($d['telefono'] ?? null),
            $d['prioridad'] ?? 'MEDIA',
            $vacioANull($d['fecha_programada'] ?? null),
            $vacioANull($d['fecha_realizada'] ?? null),
            isset($d['duracion_minutos']) && $d['duracion_minutos'] !== '' ? (int) $d['duracion_minutos'] : null,
            $vacioANull($d['resultado'] ?? null),
            $vacioANull($d['modo_registro'] ?? null),
        ];
        return $conCliente ? array_merge([(int) $d['cliente_id']], $datos) : $datos;
    }

    private const CASTS_DATOS = '
                    ?::VARCHAR,       -- p_tipo
                    ?::VARCHAR,       -- p_estado
                    ?::VARCHAR,       -- p_asunto
                    ?::BIGINT,        -- p_asunto_id
                    ?::TEXT,          -- p_nota
                    ?::BIGINT,        -- p_usuario_responsable_id
                    ?::BIGINT,        -- p_contacto_id
                    ?::VARCHAR,       -- p_telefono
                    ?::VARCHAR,       -- p_prioridad
                    ?::TIMESTAMPTZ,   -- p_fecha_programada
                    ?::TIMESTAMPTZ,   -- p_fecha_realizada
                    ?::INTEGER,       -- p_duracion_minutos
                    ?::VARCHAR,       -- p_resultado
                    ?::VARCHAR        -- p_modo_registro
    ';

    // ================================================================
    // LISTAR
    // ================================================================

    /** Historial de gestiones de un cliente (pendientes arriba). */
    public function allGestiones(Request $request)
    {
        try {
            $clienteId = $request->filled('cliente_id') ? (int) $request->input('cliente_id') : null;
            $page      = (int) $request->input('page', 1);
            $perPage   = (int) $request->input('per_page', 15);
            $search    = (string) $request->input('search', '');
            $tipo      = $request->filled('tipo')   ? $request->input('tipo')   : null;
            $estado    = $request->filled('estado') ? $request->input('estado') : null;
            $desde     = $request->filled('desde')  ? $request->input('desde')  : null;
            $hasta     = $request->filled('hasta')  ? $request->input('hasta')  : null;
            // Los dos filtros del historial: cómo terminó y quién la registró
            $resultado  = $request->filled('resultado')  ? $request->input('resultado')  : null;
            $creadoPor  = $request->filled('creado_por') ? $request->input('creado_por') : null;

            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_listar_paginado(?::BIGINT, ?::INTEGER, ?::INTEGER, ?::TEXT, ?::VARCHAR, ?::VARCHAR, ?::DATE, ?::DATE, ?::VARCHAR, ?::VARCHAR) as result',
                [$clienteId, $page, $perPage, $search, $tipo, $estado, $desde, $hasta, $resultado, $creadoPor]
            );
            $resultado = json_decode($result->result, true);

            if (isset($resultado['success']) && $resultado['success'] === false) {
                return $this->errorResponse($resultado['message'], 500);
            }
            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allGestiones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdGestion($id)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_gestiones_obtener(?::BIGINT) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);
            if (!$resultado['success']) {
                return $this->errorResponse($resultado['message'], 404);
            }
            return $this->successResponse($resultado['data'], $resultado['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdGestion', ['message' => $e->getMessage(), 'gestion_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Contadores del cliente, con su última y su próxima gestión. */
    /**
     * La agenda en grilla: una página de lo pendiente, con buscador.
     *
     * Va aparte de agenda() a propósito: aquella devuelve la lista entera
     * hasta un límite y la usa el servicio del recordatorio, que no pagina ni
     * busca. Los contadores (total, vencidas, hoy) siguen siendo de todo el
     * filtro, no de la página.
     *
     * Ni «mias» ni «usuario_id» son permisos: sólo recortan dentro de lo que
     * el solicitante ya puede ver. Pedir la agenda de alguien de fuera de su
     * jerarquía no devuelve nada.
     *
     * ?usuario_id | ?mias=1 | ?desde | ?hasta | ?vencidas=1 | ?search
     * ?page | ?per_page
     */
    public function agendaPaginada(Request $request)
    {
        try {
            $usuarioId = $request->filled('usuario_id') ? (int) $request->input('usuario_id') : null;
            $login      = filter_var($request->query('mias', false), FILTER_VALIDATE_BOOLEAN)
                ? ($request->user()->login_user ?? null)
                : null;
            $desde      = $request->filled('desde') ? $request->input('desde') : null;
            $hasta      = $request->filled('hasta') ? $request->input('hasta') : null;
            $vencidas   = filter_var($request->query('vencidas', false), FILTER_VALIDATE_BOOLEAN);
            $search     = (string) $request->input('search', '');
            $page       = (int) $request->input('page', 1);
            $perPage    = (int) $request->input('per_page', 15);

            // Quién pregunta, que es lo que pone el techo. No se negocia desde
            // la petición: ni «mias» ni «usuario_id» pueden sacar a nadie de su
            // jerarquía.
            [$solicitante] = $this->contextoUsuario();

            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_agenda_paginado(?::BIGINT, ?::VARCHAR, ?::DATE, ?::DATE, ?::BOOLEAN, ?::TEXT, ?::INTEGER, ?::INTEGER, ?::BIGINT) as result',
                [$usuarioId, $login, $desde, $hasta, $vencidas, $search, $page, $perPage, $solicitante]
            );
            $resultado = json_decode($result->result, true);

            return $resultado['success']
                ? $this->successResponse(['data' => $resultado['data'], 'meta' => $resultado['meta']], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en la agenda paginada', ['message' => $e->getMessage()]);
            return $this->errorResponse('Ocurrió un error al obtener la agenda', 500);
        }
    }

    /**
     * El tablero de ventas: cómo va la cartera y cómo va el día.
     *
     * Lo pinta «Gestión de clientes» mientras no hay un cliente elegido. Todo
     * sale de una sola función para no encadenar ocho peticiones: en este
     * servidor cada llamada cuesta más que las consultas que hace.
     *
     * Las cifras son las del ámbito de quien mira —su equipo, o sólo lo suyo
     * si no manda sobre nadie—, nunca las de toda la empresa. El bloque «mias»
     * es aparte y siempre personal, y «alcance» dice hasta dónde llega lo que
     * se está contando.
     *
     * ?dias=14  cuántos días trae la serie del gráfico (entre 7 y 90)
     */
    public function estadisticas(Request $request)
    {
        try {
            $dias = (int) $request->query('dias', 14);

            // Quién pregunta: recorta el tablero a su ámbito. El login sólo se
            // usa para rotular el bloque de «lo mío».
            [$solicitante, $login] = $this->contextoUsuario();

            $result = DB::selectOne(
                'SELECT ventas.fn_estadisticas_generales(?::VARCHAR, ?::INTEGER, ?::BIGINT) as result',
                [$login, $dias, $solicitante]
            );
            $resultado = json_decode($result->result, true);

            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en las estadísticas de ventas', ['message' => $e->getMessage()]);
            return $this->errorResponse('Ocurrió un error al obtener las estadísticas', 500);
        }
    }

    public function resumen($clienteId)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_gestiones_resumen(?::BIGINT) as result', [(int) $clienteId]);
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en resumen de gestiones', ['message' => $e->getMessage(), 'cliente_id' => $clienteId]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Lo pendiente: «Lo que toca hacer».
     *
     * Con mias=1, sólo lo que le toca al usuario autenticado (que es lo que
     * pide la pestaña de la agenda y lo que dispara el recordatorio). Sin
     * «mias» devuelve lo de la gente de la que responde —no lo de todos—, y a
     * los administradores sí lo de todos; ese techo lo pone la función a
     * partir del solicitante. La respuesta lleva la lista y los contadores:
     * { data: [...], meta: { total, vencidas, hoy, mostradas, ve_de_otros } }.
     *
     * Aquí había un accidente que tapaba a medias el agujero: $usuario_id se
     * leía de la petición y acto seguido lo machacaba el destructuring de
     * contextoUsuario(), así que este endpoint filtraba siempre por uno mismo.
     * Ya no se machaca, porque el límite lo pone el solicitante y no un
     * descuido.
     *
     * ?usuario_id&mias=1&desde&hasta&vencidas=1&limite
     */
    public function agenda(Request $request)
    {
        try {
            $usuarioId = $request->filled('usuario_id') ? (int) $request->input('usuario_id') : null;
            $desde      = $request->filled('desde') ? $request->input('desde') : null;
            $hasta      = $request->filled('hasta') ? $request->input('hasta') : null;
            $limite     = (int) $request->input('limite', 200);
            $vencidas   = filter_var($request->input('vencidas', false), FILTER_VALIDATE_BOOLEAN);

            // «Lo mío» es lo que me toca a mí; apagarlo NO abre la agenda de la
            // empresa, sólo la de la gente de la que respondo. El techo lo pone
            // el solicitante dentro de la función.
            [$solicitante, $usuarioLogin] = $this->contextoUsuario();
            $soloMias = filter_var($request->input('mias', false), FILTER_VALIDATE_BOOLEAN);
            $login    = $soloMias ? $usuarioLogin : null;

            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_agenda(?::BIGINT, ?::VARCHAR, ?::DATE, ?::DATE, ?::BOOLEAN, ?::INTEGER, ?::BIGINT) as result',
                [$usuarioId, $login, $desde, $hasta, $vencidas, $limite, $solicitante]
            );
            $resultado = json_decode($result->result, true);

            if (!($resultado['success'] ?? false)) {
                return $this->errorResponse($resultado['message'] ?? 'Error al obtener la agenda', 500);
            }
            return $this->successResponse([
                'data' => $resultado['data'] ?? [],
                'meta' => $resultado['meta'] ?? ['total' => 0, 'vencidas' => 0, 'hoy' => 0, 'mostradas' => 0],
            ], $resultado['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en agenda de gestiones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // CREAR / MODIFICAR / CERRAR / ELIMINAR
    // ================================================================

    public function addGestion(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_crear(?::BIGINT, ' . self::CASTS_DATOS . ', ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge($this->parametros($d, true), [null], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Gestión registrada', ['gestion_id' => $resultado['data']['id'] ?? null, 'cliente_id' => $d['cliente_id']]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addGestion rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addGestion', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar la gestión', 500);
        }
    }

    public function editGestion(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_modificar(?::BIGINT, ' . self::CASTS_DATOS . ', ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->parametros($d, false), $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Gestión actualizada', ['gestion_id' => $id]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editGestion rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'gestion_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editGestion', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'gestion_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar la gestión', 500);
        }
    }

    /**
     * Cierra una gestión pendiente: queda realizada con su resultado y, si
     * viene `siguiente`, deja programado el seguimiento.
     * Body: { resultado, nota?, duracion_minutos?, fecha_realizada?,
     *         siguiente?: { fecha, asunto?, tipo?, prioridad?, nota? } }
     */
    public function cerrarGestion(Request $request, $id)
    {
        try {
            $datos = $this->datosDe($request);
            $validator = Validator::make($datos, [
                'resultado'           => 'required|string|in:CONTACTADO,NO_CONTESTA,BUZON,NUMERO_ERRADO,VOLVER_A_LLAMAR,INTERESADO,NO_INTERESADO,COTIZACION,VENTA,RECLAMO,OTRO',
                'nota'                => 'nullable|string|max:4000',
                'duracion_minutos'    => 'nullable|integer|min:0|max:1440',
                'fecha_realizada'     => 'nullable|date',
                'siguiente'           => 'nullable|array',
                'siguiente.fecha'     => 'required_with:siguiente|date',
                'siguiente.asunto'    => 'nullable|string|max:200',
                'siguiente.tipo'      => 'nullable|string|in:LLAMADA,WHATSAPP,CORREO,VISITA,REUNION,OTRO',
                'siguiente.prioridad' => 'nullable|string|in:ALTA,MEDIA,BAJA',
                'siguiente.nota'      => 'nullable|string|max:4000',
            ], [
                'resultado.required'       => 'Debe indicar cómo terminó la gestión',
                'resultado.in'             => 'El resultado no es válido',
                'siguiente.fecha.required_with' => 'El seguimiento necesita fecha y hora',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_cerrar(?::BIGINT, ?::VARCHAR, ?::TEXT, ?::INTEGER, ?::TIMESTAMPTZ, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    $d['resultado'],
                    $d['nota'] ?? null,
                    isset($d['duracion_minutos']) && $d['duracion_minutos'] !== '' ? (int) $d['duracion_minutos'] : null,
                    $d['fecha_realizada'] ?? null,
                    !empty($d['siguiente']) ? json_encode($d['siguiente']) : null,
                ], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Gestión cerrada', ['gestion_id' => $id, 'resultado' => $d['resultado']]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'cerrarGestion rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'gestion_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en cerrarGestion', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'gestion_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cerrar la gestión', 500);
        }
    }

    public function deleteGestion(Request $request, $id)
    {
        try {
            // Los adjuntos se van con la gestión por el cascade de la clave
            // ajena, pero el cascade sólo borra FILAS: los ficheros se
            // quedarían en el disco para siempre, sin nada que los nombre. Se
            // anotan ANTES de borrar, que después ya no hay forma de saber
            // cuáles eran.
            $adjuntos = DB::select(
                'SELECT archivo FROM ventas.archivos_clientes WHERE gestion_id = ?',
                [(int) $id]
            );

            $result = DB::selectOne(
                'SELECT ventas.fn_gestiones_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            // Y se borran después, con la fila ya ida: al revés, si el borrado
            // fallara, la gestión seguiría enseñando adjuntos que ya no están.
            foreach ($adjuntos as $a) {
                $ruta = storage_path('app/public/img/clientes/' . $a->archivo);
                if ($a->archivo && file_exists($ruta)) { @unlink($ruta); }
            }
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Gestión eliminada', ['gestion_id' => $id]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteGestion rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'gestion_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteGestion', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'gestion_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar la gestión', 500);
        }
    }

    // ================================================================
    // CARTERA (reasignar el cliente a otro vendedor)
    // ================================================================

    /**
     * Body: { usuario_id (null = quitar), motivo?, mover_agenda?, rol? }
     *
     * El rol dice con qué papel atiende: VENDEDOR si no se indica, que es como
     * se comportaba antes de que un cliente pudiera tener varios responsables.
     * La lista de roles no está en la base a propósito (ver el .sql), así que
     * se valida aquí.
     */
    public function reasignar(Request $request, $clienteId)
    {
        try {
            // Repartir clientes es cosa de administradores. En la pantalla la
            // pestaña de Asignación ni se enseña al resto, pero eso es lo que
            // se ve: la ruta sigue existiendo y aquí es donde se cierra.
            if (!$this->esAdministrador()) {
                sistemaLog('warning', 'Reasignación rechazada: no es administrador', [
                    'cliente_id' => $clienteId,
                    'usuario'    => $request->user()->login_user ?? null,
                ]);
                return $this->errorResponse('Sólo un administrador puede cambiar quién atiende al cliente', 403);
            }

            $validator = Validator::make($this->datosDe($request), [
                'usuario_id'   => 'present|nullable|integer|exists:pgsql.seguridad.users,id',
                'motivo'       => 'nullable|string|max:1000',
                'mover_agenda' => 'nullable|boolean',
                'rol'          => 'nullable|string|in:VENDEDOR,COBRADOR,ASISTENTE,POSTVENTA',
            ], [
                'usuario_id.present' => 'Debe indicar el usuario',
                'rol.in'              => 'El papel indicado no existe',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_clientes_reasignar(?::BIGINT, ?::BIGINT, ?::TEXT, ?::BOOLEAN, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $clienteId,
                    !empty($d['usuario_id']) ? (int) $d['usuario_id'] : null,
                    $d['motivo'] ?? null,
                    array_key_exists('mover_agenda', $d) ? (bool) $d['mover_agenda'] : true,
                    $d['rol'] ?? 'VENDEDOR',
                ], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Cliente reasignado', ['cliente_id' => $clienteId, 'usuario_id' => $d['usuario_id'] ?? null]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'reasignar rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'cliente_id' => $clienteId]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en reasignar', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cliente_id' => $clienteId]);
            return $this->errorResponse('Ocurrió un error al reasignar el cliente', 500);
        }
    }

    /** Quién atiende al cliente ahora mismo, en cada papel. */
    public function responsables($clienteId)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_clientes_responsables(?::BIGINT) as result', [(int) $clienteId]);
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 404);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en responsables', ['message' => $e->getMessage(), 'cliente_id' => $clienteId]);
            return $this->errorResponse('Ocurrió un error al obtener los responsables', 500);
        }
    }

    /** Por qué manos ha pasado el cliente, en cualquiera de los papeles. */
    public function asignaciones($clienteId)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_asignaciones_listar(?::BIGINT) as result', [(int) $clienteId]);
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en asignaciones', ['message' => $e->getMessage(), 'cliente_id' => $clienteId]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
