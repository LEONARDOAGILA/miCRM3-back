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
 * CRUD de clientes (ventas.clientes), con foto, contactos y la dirección que
 * trae Google Maps.
 *
 * Mismo esquema que rh\EmpleadoController: toda la lógica vive en las
 * funciones PL/pgSQL ventas.fn_clientes_* (validaciones, auditoría,
 * transacción); aquí se valida la entrada, se llama a la función con el
 * contexto del usuario autenticado y se traduce la respuesta. Las imágenes van
 * a storage/app/public/img/clientes/{id}_cliimg.{ext}.
 *
 *   GET    ventas/cliente/allClientes?page&per_page&search   listado paginado (grilla)
 *   GET    ventas/cliente/listClientes[?activos=0]           lista simple (selector)
 *   GET    ventas/cliente/findByIdCliente/{id}
 *   POST   ventas/cliente/addCliente
 *   POST   ventas/cliente/editCliente/{id}
 *   DELETE ventas/cliente/deleteCliente/{id}
 *   POST   ventas/cliente/addImagen                { ClienteId, imagen_file }
 *   GET    ventas/cliente/getImagenCliente/{id}    (pública, la usa <img src>)
 *   GET    ventas/cliente/listContactos/{id}
 *   POST   ventas/cliente/guardarContactos/{id}    { contactos: [...] }
 *   POST   ventas/cliente/guardarUbicacion/{id}
 *   POST   ventas/cliente/addFotoUbicacion         { ClienteId, campo, imagen_file }
 *   GET    ventas/cliente/getFotoUbicacion/{id}/{campo}  (pública)
 *
 *   GET    ventas/cliente/papelera                 lo que hay en la papelera
 *   POST   ventas/cliente/restaurarClientes        { ids: [...] }
 *   POST   ventas/cliente/eliminarDefinitivo       { ids: [...] }
 *   DELETE ventas/cliente/vaciarPapelera
 */
class ClienteController extends Controller
{
    use ApiResponder;

    private const CARPETA_FOTOS = 'img/clientes';

    /** SQLSTATE de las reglas de negocio de ventas.fn_clientes_* → código HTTP. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio (también: contactos)
        'P0002' => 422,   // prioridad de contacto inválida
        'P0003' => 422,   // correo con formato inválido
        'P0006' => 409,   // identificación duplicada
        'P0010' => 422,   // campo de foto inválido
        'P0013' => 404,   // el cliente no existe
        'P0014' => 409,   // tiene registros asociados
        'P0015' => 422,   // crédito o descuento inválido
        'P0016' => 422,   // el vendedor no existe
        'P0019' => 404,   // el cliente no está en la papelera
    ];

    public function __construct() {
        $this->middleware('auth:api', ['except' => ['getImagenCliente', 'getFotoUbicacion']]);
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

    /** Reglas de validación comunes a crear y modificar. */
    private function reglas(): array
    {
        return [
            'tipo_cliente'          => 'required|string|in:PERSONA,EMPRESA',
            'numero_identificacion' => 'required|string|max:20',
            'tipo_identificacion'   => 'nullable|string|in:CC,RUC,PAS',
            'razon_social'          => 'nullable|string|max:200',
            'nombre_comercial'      => 'nullable|string|max:200',
            'nombres'               => 'nullable|string|max:100',
            'apellidos'             => 'nullable|string|max:100',
            'email'                 => 'nullable|email|max:150',
            'email_alterno'         => 'nullable|email|max:150',
            'telefono'              => 'nullable|string|max:20',
            'celular'               => 'nullable|string|max:20',
            'sitio_web'             => 'nullable|string|max:200',
            'fecha_nacimiento'      => 'nullable|date_format:Y-m-d',
            'genero'                => 'nullable|string|in:M,F,O',
            'direccion'             => 'nullable|string|max:1000',
            'vendedor_id'           => 'nullable|integer',
            'forma_pago'            => 'nullable|string|in:EFECTIVO,TRANSFERENCIA,TARJETA,CHEQUE,CREDITO',
            'limite_credito'        => 'nullable|numeric|min:0|max:9999999999',
            'dias_credito'          => 'nullable|integer|min:0|max:365',
            'descuento'             => 'nullable|numeric|min:0|max:100',
            'estado'                => 'nullable|string|in:ACTIVO,INACTIVO,SUSPENDIDO,MOROSO',
            'observaciones'         => 'nullable|string|max:2000',
            'activo'                => 'nullable|boolean',
        ];
    }

    /** Mensajes en español (el locale de la app es 'en'). */
    private function mensajes(): array
    {
        return [
            'tipo_cliente.required'          => 'Debe indicar si el cliente es una persona o una empresa',
            'tipo_cliente.in'                => 'El tipo de cliente debe ser PERSONA o EMPRESA',
            'numero_identificacion.required' => 'El número de identificación es obligatorio',
            'tipo_identificacion.in'         => 'El tipo de identificación debe ser CC, RUC o PAS',
            'email.email'                    => 'El correo electrónico no es válido',
            'email_alterno.email'            => 'El correo alterno no es válido',
            'genero.in'                      => 'El género debe ser M, F u O',
            'fecha_nacimiento.date_format'   => 'La fecha de nacimiento debe tener formato AAAA-MM-DD',
            'forma_pago.in'                  => 'La forma de pago no es válida',
            'limite_credito.numeric'         => 'El límite de crédito debe ser un número',
            'limite_credito.min'             => 'El límite de crédito no puede ser negativo',
            'dias_credito.integer'           => 'Los días de crédito deben ser un número entero',
            'dias_credito.max'               => 'Los días de crédito no pueden superar 365',
            'descuento.max'                  => 'El descuento no puede superar el 100%',
            'estado.in'                      => 'El estado del cliente no es válido',
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
            $d['tipo_cliente'],
            $d['numero_identificacion'],
            $d['tipo_identificacion'] ?? 'CC',
            $vacioANull($d['razon_social'] ?? null),
            $vacioANull($d['nombre_comercial'] ?? null),
            $vacioANull($d['nombres'] ?? null),
            $vacioANull($d['apellidos'] ?? null),
            $vacioANull($d['email'] ?? null),
            $vacioANull($d['email_alterno'] ?? null),
            $vacioANull($d['telefono'] ?? null),
            $vacioANull($d['celular'] ?? null),
            $vacioANull($d['sitio_web'] ?? null),
            $vacioANull($d['fecha_nacimiento'] ?? null),
            $vacioANull($d['genero'] ?? null),
            $vacioANull($d['direccion'] ?? null),
            !empty($d['vendedor_id']) ? (int) $d['vendedor_id'] : null,
            $d['forma_pago'] ?? 'EFECTIVO',
            isset($d['limite_credito']) && $d['limite_credito'] !== '' ? $d['limite_credito'] : 0,
            isset($d['dias_credito']) && $d['dias_credito'] !== '' ? (int) $d['dias_credito'] : 0,
            isset($d['descuento']) && $d['descuento'] !== '' ? $d['descuento'] : 0,
            $d['estado'] ?? 'ACTIVO',
            $vacioANull($d['observaciones'] ?? null),
            array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
        ];
    }

    private const CASTS_DATOS = '
                    ?::VARCHAR,   -- p_tipo_cliente
                    ?::VARCHAR,   -- p_numero_identificacion
                    ?::VARCHAR,   -- p_tipo_identificacion
                    ?::VARCHAR,   -- p_razon_social
                    ?::VARCHAR,   -- p_nombre_comercial
                    ?::VARCHAR,   -- p_nombres
                    ?::VARCHAR,   -- p_apellidos
                    ?::VARCHAR,   -- p_email
                    ?::VARCHAR,   -- p_email_alterno
                    ?::VARCHAR,   -- p_telefono
                    ?::VARCHAR,   -- p_celular
                    ?::VARCHAR,   -- p_sitio_web
                    ?::DATE,      -- p_fecha_nacimiento
                    ?::CHAR,      -- p_genero
                    ?::TEXT,      -- p_direccion
                    ?::BIGINT,    -- p_vendedor_id
                    ?::VARCHAR,   -- p_forma_pago
                    ?::NUMERIC,   -- p_limite_credito
                    ?::INTEGER,   -- p_dias_credito
                    ?::NUMERIC,   -- p_descuento
                    ?::VARCHAR,   -- p_estado
                    ?::TEXT,      -- p_observaciones
                    ?::BOOLEAN,   -- p_activo
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
    ';

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

    // ================================================================
    // LISTAR
    // ================================================================

    public function allClientes(Request $request)
    {
        try {
            $page    = (int) $request->input('page', 1);
            $perPage = (int) $request->input('per_page', 15);
            $search  = (string) $request->input('search', '');

            $result = DB::selectOne('SELECT ventas.fn_clientes_listar_paginado(?, ?, ?) as result', [$page, $perPage, $search]);
            $resultado = json_decode($result->result, true);
            if (isset($resultado['success']) && $resultado['success'] === false) {
                return $this->errorResponse($resultado['message'], 500);
            }
            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allClientes', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function listClientes(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $result = DB::selectOne('SELECT ventas.fn_clientes_listar(?::BOOLEAN) as result', [$soloActivos]);
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en listClientes', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdCliente($id)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_clientes_obtener(?::BIGINT) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);
            if (!$resultado['success']) {
                return $this->errorResponse($resultado['message'], $resultado['data'] === null ? 404 : 400);
            }
            return $this->successResponse($resultado['data'], $resultado['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdCliente', ['message' => $e->getMessage(), 'cliente_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // CREAR / MODIFICAR / ELIMINAR
    // ================================================================

    public function addCliente(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_clientes_crear(' . self::CASTS_DATOS . ') as result',
                array_merge($this->parametros($d), $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Cliente creado', ['cliente_id' => $resultado['data']['id'] ?? null]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addCliente rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addCliente', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear el cliente', 500);
        }
    }

    public function editCliente(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_clientes_modificar(?::BIGINT, ' . self::CASTS_DATOS . ') as result',
                array_merge([(int) $id], $this->parametros($d), $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Cliente actualizado', ['cliente_id' => $id]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editCliente rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'cliente_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editCliente', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cliente_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar el cliente', 500);
        }
    }

    public function deleteCliente(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_clientes_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);

            // Las imágenes se quedan: el cliente va a la papelera y puede volver.
            // Se borran en eliminarDefinitivo / vaciarPapelera.
            sistemaLog('info', 'Cliente enviado a la papelera', ['cliente_id' => $id]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteCliente rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'cliente_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteCliente', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cliente_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar el cliente', 500);
        }
    }

    // ================================================================
    // CONTACTOS DEL CLIENTE (grilla del formulario)
    // ================================================================

    public function listContactos($id)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_contactos_clientes_listar(?::BIGINT) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);
            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en listContactos (cliente)', ['message' => $e->getMessage(), 'cliente_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Sincroniza la lista completa: { contactos: [{id?, nombres, cargo?,
     * telefono, telefono_alterno?, email?, prioridad?, activo?}] }. Los que no
     * vienen se eliminan (lo hace ventas.fn_contactos_clientes_guardar).
     */
    public function guardarContactos(Request $request, $id)
    {
        try {
            $datos = $this->datosDe($request);
            $validator = Validator::make($datos, [
                'contactos'                    => 'present|array|max:20',
                'contactos.*.id'               => 'nullable|integer',
                'contactos.*.nombres'          => 'required|string|max:100',
                'contactos.*.cargo'            => 'nullable|string|max:100',
                'contactos.*.telefono'         => 'required|string|max:20',
                'contactos.*.telefono_alterno' => 'nullable|string|max:20',
                'contactos.*.email'            => 'nullable|email|max:150',
                'contactos.*.prioridad'        => 'nullable|integer|min:1|max:99',
                'contactos.*.activo'           => 'nullable|boolean',
            ], [
                'contactos.*.nombres.required'  => 'Cada contacto necesita nombres',
                'contactos.*.telefono.required' => 'Cada contacto necesita teléfono',
                'contactos.*.email.email'       => 'El correo de un contacto no es válido',
                'contactos.*.prioridad.min'     => 'La prioridad debe ser 1 o mayor',
                'contactos.max'                 => 'Máximo 20 contactos por cliente',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $contactos = $validator->validated()['contactos'] ?? [];

            $result = DB::selectOne(
                'SELECT ventas.fn_contactos_clientes_guardar(?::BIGINT, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, json_encode(array_values($contactos))], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Contactos de cliente guardados', ['cliente_id' => $id, 'n' => count($contactos)]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en guardarContactos (cliente)', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cliente_id' => $id]);
            return $this->errorResponse('Ocurrió un error al guardar los contactos', 500);
        }
    }

    // ================================================================
    // FOTO DEL CLIENTE
    // ================================================================

    public function getImagenCliente($id)
    {
        try {
            $result = DB::selectOne('SELECT foto FROM ventas.clientes WHERE id = ?', [(int) $id]);
            if (!$result || !$result->foto) {
                return $this->errorResponse('El cliente no tiene foto', 404);
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
                'ClienteId'   => 'required|integer',
                'imagen_file' => 'required|file|image|max:10240',
            ], [
                'ClienteId.required'   => 'Falta el cliente',
                'imagen_file.required' => 'No se encontró la imagen para guardar',
                'imagen_file.image'    => 'El archivo debe ser una imagen',
                'imagen_file.max'      => 'La imagen no puede superar los 10 MB',
            ]);
            if ($validator->fails()) {
                DB::rollBack();
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $clienteId = (int) $request->ClienteId;
            $existe = DB::selectOne('SELECT id, foto FROM ventas.clientes WHERE id = ?', [$clienteId]);
            if (!$existe) {
                DB::rollBack();
                return $this->errorResponse('Cliente no encontrado', 404);
            }
            $fotoAnterior = $existe->foto;

            $file = $request->file('imagen_file');
            $extension = strtolower($file->getClientOriginalExtension() ?: 'jpg');
            $filename  = $clienteId . '_cliimg.' . $extension;

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
                'SELECT ventas.fn_clientes_imagen(?::BIGINT, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$clienteId, $filename], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);

            // Foto anterior con otro nombre (otra extensión): fuera, sólo tras confirmar la BD
            if ($fotoAnterior && $fotoAnterior !== $filename) {
                $this->eliminarFotoPorNombre($fotoAnterior);
            }
            DB::commit();

            sistemaLog('info', 'Foto de cliente guardada', ['cliente_id' => $clienteId, 'foto' => $filename]);
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
            sistemaLog('error', 'Error en addImagen (cliente)', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cliente_id' => $request->ClienteId ?? null]);
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
    // PAPELERA DE RECICLAJE (borrado lógico), como la de usuarios
    // ================================================================

    /** Clientes que están en la papelera (más reciente primero). */
    public function papelera()
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_clientes_papelera_listar() as result');
            $resultado = json_decode($result->result, true);
            return $this->successResponse($resultado['data'] ?? [], 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de clientes', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar la papelera', 500);
        }
    }

    /** Saca de la papelera uno o varios clientes. Body: { ids: [..] } */
    public function restaurarClientes(Request $request)
    {
        return $this->accionPapelera($request, 'ventas.fn_clientes_restaurar', 'restaurarClientes');
    }

    /** Borra de verdad uno o varios clientes de la papelera (y sus imágenes). Body: { ids: [..] } */
    public function eliminarDefinitivo(Request $request)
    {
        return $this->accionPapelera($request, 'ventas.fn_clientes_eliminar_definitivo', 'eliminarDefinitivo');
    }

    /** Borra de verdad todo lo que hay en la papelera (y sus imágenes). */
    public function vaciarPapelera(Request $request)
    {
        return $this->accionPapelera($request, 'ventas.fn_clientes_papelera_vaciar', 'vaciarPapelera', false);
    }

    /**
     * Llama a una función de la papelera con el contexto del usuario autenticado.
     * Las de borrado real devuelven los ficheros de los clientes borrados (foto
     * y capturas del mapa) para quitarlos del disco una vez confirmada la
     * transacción; si fallara la BD, las imágenes siguen ahí.
     */
    private function accionPapelera(Request $request, string $funcion, string $nombre, bool $conIds = true)
    {
        [$usuarioId, $usuarioLogin, $usuarioNombre] = $this->contextoUsuario();
        try {
            $auditoria = $this->auditoria($request);

            if ($conIds) {
                $validator = Validator::make($request->all(), [
                    'ids'   => 'required|array|min:1|max:500',
                    'ids.*' => 'integer',
                ], [
                    'ids.required' => 'No se indicó ningún cliente',
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
            $resultado = json_decode($result->result, true);

            // Ya borrados en la BD: fuera sus imágenes
            foreach ($resultado['data']['ficheros'] ?? [] as $fichero) {
                $this->eliminarFotoPorNombre($fichero);
            }

            sistemaLog('info', "Papelera de clientes: {$nombre}", ['data' => $resultado['data'] ?? null, 'usuario' => $usuarioLogin ?? 'desconocido']);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', "{$nombre} rechazado", ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', "Error en {$nombre}", ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error en la papelera de clientes', 500);
        }
    }

    // ================================================================
    // UBICACIÓN (la dirección que viene de Google Maps)
    // ================================================================

    /**
     * Guarda el bloque de dirección del mapa.
     *
     * Va aparte del alta y la modificación a propósito: son diez campos que
     * llegan juntos del mapa y se pueden volver a tomar sin tocar el resto de
     * la ficha del cliente.
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
                'SELECT ventas.fn_clientes_ubicacion(?::BIGINT, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
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
            sistemaLog('error', 'Error al guardar la ubicación del cliente', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
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
                'ClienteId'   => 'required|integer',
                'campo'       => 'required|in:mapa,casa',
                'imagen_file' => 'required|file|image|max:10240',
            ], [
                'ClienteId.required'   => 'Falta el cliente',
                'campo.in'             => 'La foto debe ser «mapa» o «casa»',
                'imagen_file.required' => 'No se encontró la imagen para guardar',
                'imagen_file.image'    => 'El archivo debe ser una imagen',
                'imagen_file.max'      => 'La imagen no puede superar los 10 MB',
            ]);
            if ($validator->fails()) {
                DB::rollBack();
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $clienteId = (int) $request->ClienteId;
            $campo = $request->campo;

            $existe = DB::selectOne('SELECT id, url_foto_mapa, url_foto_casa FROM ventas.clientes WHERE id = ?', [$clienteId]);
            if (!$existe) {
                DB::rollBack();
                return $this->errorResponse('Cliente no encontrado', 404);
            }
            $anterior = $campo === 'mapa' ? $existe->url_foto_mapa : $existe->url_foto_casa;

            $file = $request->file('imagen_file');
            $extension = strtolower($file->getClientOriginalExtension() ?: 'png');
            $filename  = $clienteId . '_cli' . $campo . '.' . $extension;

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
                'SELECT ventas.fn_clientes_foto_ubicacion(?::BIGINT, ?::TEXT, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$clienteId, $campo, $filename], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);

            // La anterior con otra extensión ya no la referencia nadie
            if ($anterior && $anterior !== $filename) {
                $this->eliminarFotoPorNombre($anterior);
            }
            DB::commit();

            sistemaLog('info', 'Foto de ubicación de cliente guardada', ['cliente_id' => $clienteId, 'campo' => $campo, 'archivo' => $filename]);
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
            sistemaLog('error', 'Error en addFotoUbicacion (cliente)', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
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
            $result = DB::selectOne("SELECT $columna AS archivo FROM ventas.clientes WHERE id = ?", [(int) $id]);
            if (!$result || !$result->archivo) {
                return $this->errorResponse('El cliente no tiene esa foto', 404);
            }

            $path = storage_path('app/public/' . self::CARPETA_FOTOS . '/' . $result->archivo);
            if (!file_exists($path)) {
                return $this->errorResponse('La foto no existe en el servidor', 404);
            }
            return response()->file($path);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en getFotoUbicacion (cliente)', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener la foto', 500);
        }
    }
}
