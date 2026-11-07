<?php

namespace App\Http\Controllers\auth;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use Illuminate\Http\Request;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use Exception;

class HorarioController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;
    use \App\Http\Controllers\Concerns\FiltrosDeColumna;

    /**
     * Por qué columnas deja filtrar la rejilla de horarios, y de qué tipo.
     *
     * Es una lista blanca, no una comprobación: lo que mande el navegador se
     * compara contra esto y lo que no esté se tira. El nombre de la columna
     * acaba dentro de una consulta, y de las dos formas de evitar que eso sea
     * un agujero —escapar o no aceptar nombres libres— ésta es la que no
     * depende de acordarse de escapar.
     *
     * `activo` se queda fuera a propósito: en la rejilla es una casilla, y
     * escribir texto para filtrarla no se entiende.
     */
    private const COLUMNAS_FILTRABLES = [
        'id'           => 'numero',
        // Los contadores de la rejilla: dias con acceso, franjas y gente
        'num_dias'     => 'numero',
        'num_jornadas' => 'numero',
        'num_usuarios' => 'numero',
        'nombre'       => 'texto',
        'descripcion'  => 'texto',
        // Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
        'created_at' => 'texto',
        'updated_at' => 'texto',
    ];

    // ****** LISTAR HORARIOS PAGINADOS ****** //
    public function allHorarios(Request $request)
    {
        try {
            $page     = (int) $request->input('page', 1);
            $perPage  = (int) $request->input('per_page', 15);
            $search   = $request->input('search', '');
            
            // Los filtros de la cabecera de la rejilla. Se aplican EN LA BASE
            // y no en el navegador: la pantalla pagina, así que ag-Grid sólo
            // tiene las filas de la página y filtrar ahí buscaría dentro de diez.
            $filtros = $this->filtrosDeColumna($request->input('filtros'), self::COLUMNAS_FILTRABLES);

            $result = DB::selectOne('SELECT seguridad.fn_horarios_listar_paginado(?, ?, ?, ?::JSONB) as result', [
                $page,
                $perPage,
                $search,
                json_encode((object) $filtros),
            ]);
            
            $resultado = json_decode($result->result, true);
            
            sistemaLog('info', 'allHorarios ejecutado correctamente', [
                'total_registros' => $resultado['meta']['total'] ?? 0,
                'pagina'          => $page,
                'busqueda'        => $search,
                'usuario'         => auth('api')->user()->login_user ?? 'desconocido',
                'ip'              => request()->ip()
            ]);
            
            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allHorarios', [
                'code'    => $e->getCode(),
                'message' => $e->getMessage(),
                'line'    => $e->getLine()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
    

    public function listHorarios(Request $request)
    {
    try{
        $page     = (int) $request->input('page', 1);
        $perPage  = (int) $request->input('per_page', 15);
        $search   = $request->input('search', '');
        
        $result = DB::selectOne('SELECT seguridad.fn_horarios_listar_paginado_activos(?, ?, ?) as result', [
            $page,
            $perPage,
            $search
        ]);
        
        $resultado = json_decode($result->result, true);
        
        sistemaLog('info', 'listHorarios ejecutado correctamente', [
            'total_registros' => $resultado['meta']['total'] ?? 0,
            'pagina'          => $page,
            'busqueda'        => $search,
            'usuario'         => auth('api')->user()->login_user ?? 'desconocido',
            'ip'              => request()->ip()
        ]);
        
        return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        
    } catch (Exception $e) {
        sistemaLog('error', 'Error en listHorarios', [
            'code'    => $e->getCode(),
            'message' => $e->getMessage(),
            'line'    => $e->getLine()
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
    }


public function findByIdProfile($id)
{
    try {
        // SQL directo: buscar perfil activo por ID
        $data = DB::selectOne("
            SELECT 
                id,
                nombre,
                inactividad,
                activo,
                TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at_formateado,
                TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI:SS') as updated_at_formateado
            FROM seguridad.perfiles
            WHERE id = ? AND activo = true
        ", [$id]);

        if ($data === null) {
            sistemaLog('warning', 'Perfil no encontrado o inactivo', [
                'perfil_id' => $id,
                'usuario' => auth('api')->user()->login_user ?? 'desconocido',
                'ip' => request()->ip()
            ]);
            return $this->errorResponse('Perfil no encontrado o inactivo', 404);
        }

        sistemaLog('info', 'findByIdProfile ejecutado correctamente', [
            'perfil_id' => $data->id,
            'nombre' => $data->nombre,
            'usuario' => auth('api')->user()->login_user ?? 'desconocido',
            'ip' => request()->ip()
        ]);

        return $this->successResponse($data, 'La solicitud ha tenido éxito');

    } catch (Exception $e) {
        sistemaLog('error', 'Error en findByIdProfile', [
            'code' => $e->getCode(),
            'message' => $e->getMessage(),
            'line' => $e->getLine(),
            'perfil_id' => $id,
            'ip' => request()->ip()
        ]);

        return $this->errorResponse($e->getMessage(), 500);
    }
}    


    /**
     * ¿Con este horario se podría entrar en tal momento?
     *
     * Es la misma pregunta que responde el middleware en cada petición, pero
     * para una fecha y hora cualquiera: sirve para probar un horario antes de
     * ponérselo a cincuenta personas. De sólo lectura.
     */
    public function puedeEntrar(Request $request, $id)
    {
        try {
            $cuando = (string) $request->input('fecha_hora', '');

            $result = DB::selectOne(
                'SELECT seguridad.fn_horarios_puede_entrar(?::BIGINT, ?::TIMESTAMPTZ) as result',
                [(int) $id, $cuando !== '' ? $cuando : null]
            );
            return $this->successResponse(json_decode($result->result, true), 'La solicitud ha tenido éxito');

        } catch (QueryException $e) {
            // Una fecha que PostgreSQL no entiende es culpa de quien la manda
            return $this->errorResponse('No se entiende la fecha y hora indicada', 422);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en puedeEntrar', ['message' => $e->getMessage(), 'horario_id' => $id]);
            return $this->errorResponse('Ocurrió un error al comprobar el horario', 500);
        }
    }

    public function getHorario($id)
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_horarios_obtener(?) as result', [$id]);
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 404, $resultado['error_code'] ?? null);
            }
            
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }


    public function addHorario(Request $request)
    {
        try {
            // 1. Validar los datos de entrada
            $validatedData = $this->validate($request, [
                'nombre'  => 'required|string|max:100',
                // Para que sirve este horario y a quien se le pone
                'descripcion' => 'nullable|string|max:250',
                'activo'  => 'nullable|boolean',
                // Hasta cuatro jornadas por dia: siete dias por cuatro, 28
                'dhorario'               => 'nullable|array|max:28',
                'dhorario.*.dia'         => 'required|integer|min:1|max:7',
                'dhorario.*.jornada'     => 'nullable|integer|min:1|max:4',
                // `HH:MM` o `HH:MM:SS`, que es lo que da <input type="time">
                'dhorario.*.hora_inicio' => ['required', 'string', 'regex:/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/'],
                'dhorario.*.hora_fin'    => ['required', 'string', 'regex:/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/'],
                'dhorario.*.activo'      => 'nullable|boolean'
            ]);

            // 2. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

            // 3. Preparar el JSON de dhorario
            $dhorarioJson = null;
            if (isset($validatedData['dhorario']) && !empty($validatedData['dhorario'])) {
                $dhorarioArray = array_map(function($item) {
                    return [
                        'dia' => (int)$item['dia'],
                        // Sin jornada se entiende que es la 1, que es lo que
                        // habia cuando solo cabia una franja por dia
                        'jornada' => (int)($item['jornada'] ?? 1),
                        'hora_inicio' => $item['hora_inicio'],
                        'hora_fin' => $item['hora_fin'],
                        'activo' => (bool)($item['activo'] ?? true)
                    ];
                }, $validatedData['dhorario']);
                $dhorarioJson = json_encode($dhorarioArray);
            }

            // 4. Convertir booleano para PostgreSQL. `activo` es opcional:
            //    sin el, un horario nuevo nace encendido.
            $activoPostgres = ($validatedData['activo'] ?? true) ? 'true' : 'false';

            // 5. Llamar a la función de PostgreSQL
            $result = DB::selectOne('
                SELECT seguridad.fn_horarios_crear(
                    ?::VARCHAR,   -- p_nombre
                    ?::VARCHAR,   -- p_descripcion
                    ?::BOOLEAN,
                    ?::JSONB,
                    ?::BIGINT,
                    ?::VARCHAR,
                    ?::VARCHAR,
                    ?::INET,
                    ?::TEXT,
                    ?::UUID
                ) as result
            ', [
                $validatedData['nombre'],
                $validatedData['descripcion'] ?? null,
                $activoPostgres,
                $dhorarioJson,
                $usuarioId ? (int)$usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);

            $resultado = json_decode($result->result, true);

            if ($resultado['success']) {
                sistemaLog('info', 'Horario creado exitosamente', [
                    'horario_id' => $resultado['data']['id'],
                    'nombre'     => $resultado['data']['nombre'],
                    'usuario'    => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
            }

        } catch (\Illuminate\Validation\ValidationException $e) {
            // Un dato mal puesto es culpa de quien llama, no del servidor:
            // sin esto caia en el catch de abajo y salia como un 500.
            return $this->errorResponse($e->validator->errors()->first(), 422);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addHorario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'data'    => $request->all()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }


    /**
     * Pone `activo` y nada mas.
     *
     * Existe aparte de editHorario porque bajar la casilla de la rejilla no
     * tiene por que revalidar el horario entero: fn_horarios_modificar
     * reescribe tambien los dias (seguridad.dhorarios), y para apagar un
     * horario eso es mucho ruido y mucho riesgo.
     *
     * `activo` es opcional: sin el, la funcion alterna. La pantalla si lo manda
     * para que dos personas pulsando a la vez no acaben peleando por «lo
     * contrario de lo que habia».
     *
     * NADIE PUEDE APAGAR SU PROPIO HORARIO. El middleware
     * VerificarUsuarioActivo contesta 401 cuando el horario asignado esta
     * inactivo: quien apague el suyo se queda fuera del CRM y ya no puede
     * entrar a deshacerlo. El cerrojo esta en la funcion de la base.
     */
    public function activarHorario(Request $request, $id)
    {
        $usuario = auth('api')->user();
        try {
            // El booleano con filter_var: "false" en texto es true a secas
            $activo = $request->exists('activo') && $request->input('activo') !== null && $request->input('activo') !== ''
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE)
                : null;

            $result = DB::selectOne(
                'SELECT seguridad.fn_horarios_activar(?::BIGINT, ?::BOOLEAN, ?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID) as result',
                [
                    (int) $id,
                    $activo,
                    $usuario->id ?? null,
                    $usuario->login_user ?? null,
                    trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null,
                    $request->ip(),
                    $request->userAgent(),
                    (string) Str::uuid(),
                ]
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                $codigo = match ($r['error_code'] ?? '') {
                    'NO_EXISTE'  => 404,
                    'MI_HORARIO' => 409,
                    default      => 500,
                };
                sistemaLog('warning', 'activarHorario rechazado', ['horario_id' => $id, 'error_code' => $r['error_code'] ?? null]);
                return $this->errorResponse($r['message'], $codigo);
            }

            sistemaLog('info', 'Horario activado/desactivado', ['horario_id' => $id, 'activo' => $r['data']['activo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarHorario', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'horario_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cambiar el estado del horario', 500);
        }
    }

    public function editHorario(Request $request, $id)
    {
        try {
            $jsonData = $request->input('json');
            
            if (!$jsonData) {
                return $this->errorResponse('No se enviaron datos válidos', 400);
            }
            
            $data = json_decode($jsonData, true);
            
            if (json_last_error() !== JSON_ERROR_NONE) {
                return $this->errorResponse('Formato JSON inválido', 400);
            }
            
            $validator = Validator::make($data, [
                'nombre'  => 'required|string|max:100',
                // Para que sirve este horario y a quien se le pone
                'descripcion' => 'nullable|string|max:250',
                'activo'  => 'nullable|boolean',
                // Hasta cuatro jornadas por dia: siete dias por cuatro, 28
                'dhorario'               => 'nullable|array|max:28',
                'dhorario.*.dia'         => 'required|integer|min:1|max:7',
                'dhorario.*.jornada'     => 'nullable|integer|min:1|max:4',
                // `HH:MM` o `HH:MM:SS`, que es lo que da <input type="time">
                'dhorario.*.hora_inicio' => ['required', 'string', 'regex:/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/'],
                'dhorario.*.hora_fin'    => ['required', 'string', 'regex:/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/'],
                'dhorario.*.activo'      => 'nullable|boolean'
            ]);
            
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 400);
            }
            
            $validatedData = $validator->validated();
            
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            $dhorarioJson = $validatedData['dhorario'] ? json_encode($validatedData['dhorario']) : null;
            
            $result = DB::selectOne('SELECT seguridad.fn_horarios_modificar(?, ?, ?, ?, ?, ?, ?, ?, ?::inet, ?, ?::uuid) as result', [
                $id,
                $validatedData['nombre'],
                $validatedData['descripcion'] ?? null,
                $validatedData['activo'] ?? true,
                $dhorarioJson,
                $usuarioId,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);
            
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                sistemaLog('info', 'Horario actualizado exitosamente', [
                    'horario_id' => $id,
                    'nombre'     => $resultado['data']['nombre'],
                    'usuario'    => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editHorario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'horario_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function deleteHorario(Request $request, $id)
    {
        try {
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            $result = DB::selectOne('SELECT seguridad.fn_horarios_eliminar(?, ?, ?, ?, ?::inet, ?, ?::uuid) as result', [
                $id,
                $usuarioId,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);
            
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                sistemaLog('info', 'Horario eliminado exitosamente', [
                    'horario_id' => $id,
                    'usuario'    => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteHorario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'horario_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================
    //
    // «Eliminar» un horario ya no lo borra: lo manda a la papelera CON SUS
    // DÍAS, y desde allí se restaura tal cual o se borra de verdad. Un
    // horario son siete franjas con sus horas, y rehacerlas a mano es un rato.
    //
    // Un horario en uso (usuarios o grupos) no llega ni a la papelera: la
    // función lo rechaza con P0021 y dice cuántos lo usan.

    /** Horarios que están en la papelera (más reciente primero). */
    public function papeleraHorarios()
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_horarios_papelera_listar() as result');
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar la papelera', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papeleraHorarios', [
                'message' => $e->getMessage(), 'line' => $e->getLine(),
            ]);
            return $this->errorResponse('Ocurrió un error al listar la papelera', 500);
        }
    }

    /** Saca de la papelera uno o varios horarios. Body: { ids: [..] } */
    public function restaurarHorarios(Request $request)
    {
        return $this->accionPapeleraHorarios($request, 'seguridad.fn_horarios_restaurar', 'restaurarHorarios');
    }

    /** Borrado real de lo que está en la papelera. Body: { ids: [..] } */
    public function eliminarDefinitivoHorarios(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar», que es
        // otro distinto de «papelera». Se comprueba AQUÍ y no sólo en el
        // front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allHorarios', 'vaciar',
                'No tiene permiso para eliminar definitivamente horarios')) {
            return $no;
        }

        return $this->accionPapeleraHorarios($request, 'seguridad.fn_horarios_eliminar_definitivo', 'eliminarDefinitivoHorarios');
    }

    /** Borrado real de TODO lo que hay en la papelera. */
    public function vaciarPapeleraHorarios(Request $request)
    {
        if ($no = $this->exigirPermiso('allHorarios', 'vaciar',
                'No tiene permiso para vaciar la papelera de horarios')) {
            return $no;
        }

        return $this->accionPapeleraHorarios($request, 'seguridad.fn_horarios_papelera_vaciar', 'vaciarPapeleraHorarios', false);
    }

    /**
     * El tronco común de restaurar / eliminar definitivo / vaciar: validar,
     * llamar con el contexto de auditoría y traducir el error de negocio.
     *
     *   P0021  el horario está en uso   -> 409
     *   P0022  no está en la papelera   -> 404
     */
    private function accionPapeleraHorarios(Request $request, string $funcion, string $nombre, bool $conIds = true)
    {
        try {
            $usuario = auth('api')->user();
            $auditoria = [
                $usuario->id ?? null,
                $usuario->login_user ?? null,
                trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid(),
            ];
            $casts = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

            if ($conIds) {
                $ids = $request->input('ids');
                if (!is_array($ids) || count($ids) === 0) {
                    return $this->errorResponse('No se indicó ningún horario', 422);
                }
                $result = DB::selectOne(
                    "SELECT {$funcion}(?::JSONB, {$casts}) as result",
                    array_merge([json_encode(array_map('intval', $ids))], $auditoria)
                );
            } else {
                $result = DB::selectOne("SELECT {$funcion}({$casts}) as result", $auditoria);
            }

            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo completar la acción', 400);
            }

            sistemaLog('info', "Papelera de horarios: {$nombre}", ['data' => $r['data'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            $sqlstate = $e->errorInfo[0] ?? null;
            $codigo = $sqlstate === 'P0021' ? 409 : ($sqlstate === 'P0022' ? 404 : 500);
            $mensaje = $e->errorInfo[2] ?? 'No se pudo completar la acción';
            $mensaje = trim(preg_replace('/^ERROR:\s*/', '', explode("\n", $mensaje)[0]));

            sistemaLog($codigo >= 500 ? 'error' : 'warning', "{$nombre} rechazado", [
                'sqlstate' => $sqlstate, 'message' => $e->getMessage(),
            ]);
            return $this->errorResponse($mensaje, $codigo);

        } catch (Exception $e) {
            sistemaLog('error', "Error en {$nombre}", ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error en la papelera de horarios', 500);
        }
    }
}







