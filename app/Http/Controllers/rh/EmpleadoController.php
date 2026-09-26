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
 * CRUD de empleados (rh.empleados), con foto.
 *
 * Mismo esquema que auth\UserController: toda la lógica vive en las funciones
 * PL/pgSQL rh.fn_empleados_* (validaciones, auditoría, transacción); aquí se
 * valida la entrada, se llama a la función con el contexto del usuario
 * autenticado y se traduce la respuesta. La foto se guarda en
 * storage/app/public/img/empleados/{id}_empimg.{ext} (como el avatar de users).
 *
 *   GET    rh/empleado/allEmpleados?page&per_page&search   listado paginado (grilla)
 *   GET    rh/empleado/listEmpleados[?activos=0]           lista simple (selector / jefe)
 *   GET    rh/empleado/findByIdEmpleado/{id}
 *   POST   rh/empleado/addEmpleado
 *   POST   rh/empleado/editEmpleado/{id}
 *   DELETE rh/empleado/deleteEmpleado/{id}
 *   POST   rh/empleado/addImagen            { EmpleadoId, imagen_file }
 *   GET    rh/empleado/getImagenEmpleado/{id}  (pública, como getImagenUsuario)
 */
class EmpleadoController extends Controller
{
    use ApiResponder;

    private const CARPETA_FOTOS = 'img/empleados';

    /** SQLSTATE de las reglas de negocio de rh.fn_empleados_* → código HTTP. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422, 'P0002' => 422, 'P0003' => 422, 'P0004' => 422,   // P0001/P0002 también: contactos (obligatorios / prioridad)
        'P0006' => 409, 'P0007' => 409,
        'P0008' => 422, 'P0009' => 422, 'P0010' => 422, 'P0011' => 422, 'P0012' => 422,
        'P0013' => 404,
        'P0014' => 409,
        'P0015' => 422, 'P0016' => 422, 'P0017' => 422,
    ];

    public function __construct() {
        $this->middleware('auth:api', ['except' => ['getImagenEmpleado', 'getFotoUbicacion']]);
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

    private function contextoUsuario(): array
    {
        $u = auth('api')->user();
        return [
            $u->id ?? null,
            $u->login_user ?? null,
            trim(($u->name ?? '') . ' ' . ($u->surname ?? '')) ?: null,
        ];
    }

    private function reglas(): array
    {
        return [
            'numero_identificacion' => 'required|string|max:20',
            'tipo_identificacion'   => 'nullable|string|max:10',
            'nombres'               => 'required|string|min:2|max:100',
            'apellidos'             => 'required|string|min:2|max:100',
            'email'                 => 'required|email|max:150',
            'email_personal'        => 'nullable|email|max:150',
            'telefono'              => 'nullable|string|max:20',
            'celular'               => 'nullable|string|max:20',
            'fecha_nacimiento'      => 'nullable|date_format:Y-m-d',
            'genero'                => 'nullable|string|in:M,F,O',
            'direccion'             => 'nullable|string|max:1000',
            'cargo_id'              => 'required|integer',
            'departamento_id'       => 'required|integer',
            'jefe_id'               => 'nullable|integer',
            'fecha_ingreso'         => 'required|date_format:Y-m-d',
            'fecha_salida'          => 'nullable|date_format:Y-m-d',
            'estado'                => 'nullable|string|max:20',
            'tipo_contrato'         => 'nullable|string|in:INDEFINIDO,TEMPORAL,PRACTICAS,CONSULTORIA',
            'salario'               => 'nullable|numeric|min:0|max:999999999',
            'activo'                => 'nullable|boolean',
        ];
    }

    private function mensajes(): array
    {
        return [
            'numero_identificacion.required' => 'El número de identificación es obligatorio',
            'nombres.required'   => 'Los nombres son obligatorios',
            'nombres.min'        => 'Los nombres deben tener al menos 2 caracteres',
            'apellidos.required' => 'Los apellidos son obligatorios',
            'apellidos.min'      => 'Los apellidos deben tener al menos 2 caracteres',
            'email.required'     => 'El correo electrónico es obligatorio',
            'email.email'        => 'El correo electrónico no es válido',
            'email_personal.email' => 'El correo personal no es válido',
            'genero.in'          => 'El género debe ser M, F u O',
            'cargo_id.required'  => 'Debe seleccionar un cargo',
            'departamento_id.required' => 'Debe seleccionar un departamento',
            'fecha_ingreso.required'   => 'La fecha de ingreso es obligatoria',
            'fecha_ingreso.date_format' => 'La fecha de ingreso debe tener formato AAAA-MM-DD',
            'fecha_salida.date_format'  => 'La fecha de salida debe tener formato AAAA-MM-DD',
            'fecha_nacimiento.date_format' => 'La fecha de nacimiento debe tener formato AAAA-MM-DD',
            'tipo_contrato.in'   => 'El tipo de contrato no es válido',
            'salario.numeric'    => 'El salario debe ser un número',
            'salario.min'        => 'El salario no puede ser negativo',
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

    /** Parámetros posicionales de crear/modificar (mismo orden que la función SQL, sin id ni auditoría). */
    private function parametros(array $d): array
    {
        $vacioANull = fn ($v) => ($v === '' || $v === null) ? null : $v;
        return [
            $d['numero_identificacion'],
            $d['tipo_identificacion'] ?? 'CC',
            $d['nombres'],
            $d['apellidos'],
            $d['email'],
            $vacioANull($d['email_personal'] ?? null),
            $vacioANull($d['telefono'] ?? null),
            $vacioANull($d['celular'] ?? null),
            $vacioANull($d['fecha_nacimiento'] ?? null),
            $vacioANull($d['genero'] ?? null),
            $vacioANull($d['direccion'] ?? null),
            (int) $d['cargo_id'],
            (int) $d['departamento_id'],
            !empty($d['jefe_id']) ? (int) $d['jefe_id'] : null,
            $d['fecha_ingreso'],
            $vacioANull($d['fecha_salida'] ?? null),
            $d['estado'] ?? 'ACTIVO',
            $d['tipo_contrato'] ?? 'INDEFINIDO',
            isset($d['salario']) && $d['salario'] !== '' ? $d['salario'] : null,
            array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
        ];
    }

    private const CASTS_DATOS = '
                    ?::VARCHAR,   -- p_numero_identificacion
                    ?::VARCHAR,   -- p_tipo_identificacion
                    ?::VARCHAR,   -- p_nombres
                    ?::VARCHAR,   -- p_apellidos
                    ?::VARCHAR,   -- p_email
                    ?::VARCHAR,   -- p_email_personal
                    ?::VARCHAR,   -- p_telefono
                    ?::VARCHAR,   -- p_celular
                    ?::DATE,      -- p_fecha_nacimiento
                    ?::CHAR,      -- p_genero
                    ?::TEXT,      -- p_direccion
                    ?::BIGINT,    -- p_cargo_id
                    ?::BIGINT,    -- p_departamento_id
                    ?::BIGINT,    -- p_jefe_id
                    ?::DATE,      -- p_fecha_ingreso
                    ?::DATE,      -- p_fecha_salida
                    ?::VARCHAR,   -- p_estado
                    ?::VARCHAR,   -- p_tipo_contrato
                    ?::NUMERIC,   -- p_salario
                    ?::BOOLEAN,   -- p_activo
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
    ';

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

    // ================================================================
    // LISTAR
    // ================================================================

    public function allEmpleados(Request $request)
    {
        try {
            $page    = (int) $request->input('page', 1);
            $perPage = (int) $request->input('per_page', 15);
            $search  = (string) $request->input('search', '');

            $result = DB::selectOne('SELECT rh.fn_empleados_listar_paginado(?, ?, ?) as result', [$page, $perPage, $search]);
            $resultado = json_decode($result->result, true);
            if (isset($resultado['success']) && $resultado['success'] === false) {
                return $this->errorResponse($resultado['message'], 500);
            }
            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allEmpleados', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function listEmpleados(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $result = DB::selectOne('SELECT rh.fn_empleados_listar(?::BOOLEAN) as result', [$soloActivos]);
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en listEmpleados', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdEmpleado($id)
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_empleados_obtener(?::BIGINT) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);
            if (!$resultado['success']) {
                return $this->errorResponse($resultado['message'], $resultado['data'] === null ? 404 : 400);
            }
            return $this->successResponse($resultado['data'], $resultado['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdEmpleado', ['message' => $e->getMessage(), 'empleado_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // CREAR / MODIFICAR / ELIMINAR
    // ================================================================

    public function addEmpleado(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT rh.fn_empleados_crear(' . self::CASTS_DATOS . ') as result',
                array_merge($this->parametros($d), $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Empleado creado', ['empleado_id' => $resultado['data']['id'] ?? null]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addEmpleado rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addEmpleado', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear el empleado', 500);
        }
    }

    public function editEmpleado(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT rh.fn_empleados_modificar(?::BIGINT, ' . self::CASTS_DATOS . ') as result',
                array_merge([(int) $id], $this->parametros($d), $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Empleado actualizado', ['empleado_id' => $id]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editEmpleado rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'empleado_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editEmpleado', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'empleado_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar el empleado', 500);
        }
    }

    public function deleteEmpleado(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT rh.fn_empleados_eliminar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID) as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);

            // La foto ya no tiene dueño
            $this->eliminarFotoPorNombre($resultado['data']['foto'] ?? null);

            sistemaLog('info', 'Empleado eliminado', ['empleado_id' => $id]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteEmpleado rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'empleado_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteEmpleado', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'empleado_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar el empleado', 500);
        }
    }

    // ================================================================
    // CONTACTOS DE EMERGENCIA (grilla del formulario de empleado)
    // ================================================================

    public function listContactos($id)
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_contactos_listar(?::BIGINT) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en listContactos', ['message' => $e->getMessage(), 'empleado_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Sincroniza la lista completa: { contactos: [{id?, nombres, parentesco,
     * telefono, telefono_alterno?, email?, prioridad?, activo?}] }. Los que no
     * vienen se eliminan (lo hace rh.fn_contactos_guardar).
     */
    public function guardarContactos(Request $request, $id)
    {
        try {
            $datos = $this->datosDe($request);
            $validator = Validator::make($datos, [
                'contactos'                    => 'present|array|max:20',
                'contactos.*.id'               => 'nullable|integer',
                'contactos.*.nombres'          => 'required|string|max:100',
                'contactos.*.parentesco'       => 'required|string|max:50',
                'contactos.*.telefono'         => 'required|string|max:20',
                'contactos.*.telefono_alterno' => 'nullable|string|max:20',
                'contactos.*.email'            => 'nullable|email|max:150',
                'contactos.*.prioridad'        => 'nullable|integer|min:1|max:99',
                'contactos.*.activo'           => 'nullable|boolean',
            ], [
                'contactos.*.nombres.required'    => 'Cada contacto necesita nombres',
                'contactos.*.parentesco.required' => 'Cada contacto necesita parentesco',
                'contactos.*.telefono.required'   => 'Cada contacto necesita teléfono',
                'contactos.*.email.email'         => 'El correo de un contacto no es válido',
                'contactos.*.prioridad.min'       => 'La prioridad debe ser 1 o mayor',
                'contactos.max'                   => 'Máximo 20 contactos por empleado',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $contactos = $validator->validated()['contactos'] ?? [];

            $result = DB::selectOne(
                'SELECT rh.fn_contactos_guardar(?::BIGINT, ?::JSONB, ?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID) as result',
                array_merge([(int) $id, json_encode(array_values($contactos))], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Contactos de emergencia guardados', ['empleado_id' => $id, 'n' => count($contactos)]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en guardarContactos', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'empleado_id' => $id]);
            return $this->errorResponse('Ocurrió un error al guardar los contactos', 500);
        }
    }

    // ================================================================
    // FOTO (mismo esquema que UserController::addImagen / getImagenUsuario)
    // ================================================================

    public function getImagenEmpleado($id)
    {
        try {
            $result = DB::selectOne('SELECT foto FROM rh.empleados WHERE id = ?', [(int) $id]);
            if (!$result || !$result->foto) {
                return $this->errorResponse('El empleado no tiene foto', 404);
            }
            $path = storage_path('app/public/' . self::CARPETA_FOTOS . '/' . $result->foto);
            if (!file_exists($path)) {
                return $this->errorResponse('La foto no existe en el servidor', 404);
            }
            return response()->file($path, [
                'Content-Type'  => mime_content_type($path),
                'Cache-Control' => 'public, max-age=31536000',
            ]);
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function addImagen(Request $request)
    {
        DB::beginTransaction();
        try {
            $validator = Validator::make($request->all(), [
                'EmpleadoId'  => 'required|integer',
                'imagen_file' => 'required|file|image|max:10240',
            ], [
                'EmpleadoId.required'  => 'Falta el empleado',
                'imagen_file.required' => 'No se encontró la imagen para guardar',
                'imagen_file.image'    => 'El archivo debe ser una imagen',
                'imagen_file.max'      => 'La imagen no puede superar los 10 MB',
            ]);
            if ($validator->fails()) {
                DB::rollBack();
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $empleadoId = (int) $request->EmpleadoId;
            $existe = DB::selectOne('SELECT id, foto FROM rh.empleados WHERE id = ?', [$empleadoId]);
            if (!$existe) {
                DB::rollBack();
                return $this->errorResponse('Empleado no encontrado', 404);
            }
            $fotoAnterior = $existe->foto;

            $file = $request->file('imagen_file');
            $extension = strtolower($file->getClientOriginalExtension() ?: 'jpg');
            $filename  = $empleadoId . '_empimg.' . $extension;

            if (!$file->storeAs('public/' . self::CARPETA_FOTOS, $filename)) {
                DB::rollBack();
                return $this->errorResponse('Error al guardar el archivo', 500);
            }
            $filePath = storage_path('app/public/' . self::CARPETA_FOTOS . '/' . $filename);
            if (!file_exists($filePath) || filesize($filePath) === 0) {
                DB::rollBack();
                return $this->errorResponse('El archivo no se guardó correctamente', 500);
            }

            $result = DB::selectOne(
                'SELECT rh.fn_empleados_imagen(?::BIGINT, ?::VARCHAR, ?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID) as result',
                array_merge([$empleadoId, $filename], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);

            // Foto anterior con otro nombre (otra extensión): fuera, sólo tras confirmar la BD
            if ($fotoAnterior && $fotoAnterior !== $filename) {
                $this->eliminarFotoPorNombre($fotoAnterior);
            }
            DB::commit();

            sistemaLog('info', 'Foto de empleado guardada', ['empleado_id' => $empleadoId, 'foto' => $filename]);
            return $this->successResponse([
                'foto'      => $resultado['data']['foto'],
                'full_path' => asset('storage/' . self::CARPETA_FOTOS . '/' . $resultado['data']['foto']),
            ], $resultado['message']);

        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error en addImagen (empleado)', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'empleado_id' => $request->EmpleadoId ?? null]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    private function eliminarFotoPorNombre(?string $foto): void
    {
        if (!$foto) { return; }
        $path = storage_path('app/public/' . self::CARPETA_FOTOS . '/' . $foto);
        if (file_exists($path)) { @unlink($path); }
    }

    // ================================================================
    // UBICACIÓN (la dirección que viene de Google Maps)
    // ================================================================

    /** Los mismos marcadores de auditoría que usan las demás funciones. */
    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    /**
     * Guarda el bloque de dirección del mapa.
     *
     * Va aparte del alta y la modificación a propósito: son doce campos que
     * llegan juntos del mapa y se pueden volver a tomar sin tocar el resto de
     * la ficha del empleado.
     */
    public function guardarUbicacion(Request $request, $id)
    {
        $datos = $this->datosDe($request);

        $validator = Validator::make($datos, [
            'provincia'        => 'nullable|string|max:100',
            'canton'           => 'nullable|string|max:100',
            'parroquia'        => 'nullable|string|max:100',
            'calle_principal'  => 'nullable|string|max:200',
            'calle_secundaria' => 'nullable|string|max:200',
            'numeracion'       => 'nullable|string|max:50',
            'ubicacion'        => 'nullable|string|max:1000',
            'codigo_postal'    => 'nullable|string|max:20',
            'coordenadas'      => 'nullable|string|max:60',
            'link_coordenadas' => 'nullable|string|max:1000',
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        DB::beginTransaction();
        try {
            $result = DB::selectOne(
                'SELECT rh.fn_empleados_ubicacion(?::BIGINT, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, json_encode($validator->validated())], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            DB::commit();

            return $this->successResponse($resultado['data'], $resultado['message']);
        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error al guardar la ubicación del empleado', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar la ubicación', 500);
        }
    }

    /**
     * Las dos fotos del mapa: la vista de arriba y la de la calle.
     *
     * Llegan ya hechas desde el navegador (el mapa las captura), así que aquí
     * sólo se guardan tal cual — este servidor no tiene GD para tocarlas.
     */
    public function addFotoUbicacion(Request $request)
    {
        DB::beginTransaction();
        try {
            $validator = Validator::make($request->all(), [
                'EmpleadoId'  => 'required|integer',
                'campo'       => 'required|in:mapa,casa',
                'imagen_file' => 'required|file|image|max:10240',
            ], [
                'EmpleadoId.required'  => 'Falta el empleado',
                'campo.in'             => 'La foto debe ser «mapa» o «casa»',
                'imagen_file.required' => 'No se encontró la imagen para guardar',
                'imagen_file.image'    => 'El archivo debe ser una imagen',
                'imagen_file.max'      => 'La imagen no puede superar los 10 MB',
            ]);
            if ($validator->fails()) {
                DB::rollBack();
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $empleadoId = (int) $request->EmpleadoId;
            $campo = $request->campo;

            $existe = DB::selectOne('SELECT id, url_foto_mapa, url_foto_casa FROM rh.empleados WHERE id = ?', [$empleadoId]);
            if (!$existe) {
                DB::rollBack();
                return $this->errorResponse('Empleado no encontrado', 404);
            }
            $anterior = $campo === 'mapa' ? $existe->url_foto_mapa : $existe->url_foto_casa;

            $file = $request->file('imagen_file');
            $extension = strtolower($file->getClientOriginalExtension() ?: 'png');
            $filename  = $empleadoId . '_emp' . $campo . '.' . $extension;

            if (!$file->storeAs('public/' . self::CARPETA_FOTOS, $filename)) {
                DB::rollBack();
                return $this->errorResponse('Error al guardar el archivo', 500);
            }
            $filePath = storage_path('app/public/' . self::CARPETA_FOTOS . '/' . $filename);
            if (!file_exists($filePath) || filesize($filePath) === 0) {
                DB::rollBack();
                return $this->errorResponse('El archivo no se guardó correctamente', 500);
            }

            $result = DB::selectOne(
                'SELECT rh.fn_empleados_foto_ubicacion(?::BIGINT, ?::TEXT, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$empleadoId, $campo, $filename], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);

            // La anterior con otra extensión ya no la referencia nadie
            if ($anterior && $anterior !== $filename) {
                $this->eliminarFotoPorNombre($anterior);
            }
            DB::commit();

            sistemaLog('info', 'Foto de ubicación guardada', ['empleado_id' => $empleadoId, 'campo' => $campo, 'archivo' => $filename]);
            return $this->successResponse([
                'campo'     => $campo,
                'archivo'   => $filename,
                'full_path' => asset('storage/' . self::CARPETA_FOTOS . '/' . $filename),
            ], $resultado['message']);

        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error en addFotoUbicacion', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar la foto', 500);
        }
    }

    /** Devuelve una de las dos fotos del mapa (la usa <img src>). */
    public function getFotoUbicacion($id, $campo)
    {
        try {
            if (!in_array($campo, ['mapa', 'casa'], true)) {
                return $this->errorResponse('La foto debe ser «mapa» o «casa»', 422);
            }

            $columna = $campo === 'mapa' ? 'url_foto_mapa' : 'url_foto_casa';
            $result = DB::selectOne("SELECT $columna AS archivo FROM rh.empleados WHERE id = ?", [(int) $id]);
            if (!$result || !$result->archivo) {
                return $this->errorResponse('El empleado no tiene esa foto', 404);
            }

            $path = storage_path('app/public/' . self::CARPETA_FOTOS . '/' . $result->archivo);
            if (!file_exists($path)) {
                return $this->errorResponse('La foto no existe en el servidor', 404);
            }
            return response()->file($path);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en getFotoUbicacion', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener la foto', 500);
        }
    }
}
