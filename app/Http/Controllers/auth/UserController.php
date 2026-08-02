<?php

namespace App\Http\Controllers\auth;

use Exception;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use App\Http\Controllers\auth\EmailController;


class UserController extends Controller
{
    use ApiResponder;

    public function __construct() {
        $this->middleware('auth:api', ['except' => [
            'getImagenUsuario',
            'verificarUsuarioRecuperacion',
            'solicitarRecuperacion',      
            'verificarRecuperacion',      
            'cambiarPasswordRecuperacion' 
        ]]);
    }

    public function allUsers(Request $request)
    {
        try {
            $page     = (int) $request->input('page', 1);
            $perPage  = (int) $request->input('per_page', 15);
            $search   = $request->input('search', '');
            
            $result = DB::selectOne('SELECT seguridad.fn_usuarios_listar_paginado(?, ?, ?) as result', [
                $page,
                $perPage,
                $search
            ]);
            
            $resultado = json_decode($result->result, true);
            
            sistemaLog('info', 'allUsers ejecutado correctamente', [
                'total_registros' => $resultado['meta']['total'] ?? 0,
                'pagina'          => $page,
                'busqueda'        => $search,
                'usuario'         => auth('api')->user()->login_user ?? 'desconocido',
                'ip'              => request()->ip()
            ]);
            
            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allUsers', [
                'code'    => $e->getCode(),
                'message' => $e->getMessage(),
                'line'    => $e->getLine()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdUser($id)
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_usuarios_obtener(?::BIGINT) as result', [(int)$id]);
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                if ($resultado['data'] === null) {
                    return $this->errorResponse('Usuario no encontrado', 404);
                }
                sistemaLog('info', 'findByIdUser ejecutado correctamente', [
                    'usuario_id' => $id,
                    'usuario' => auth('api')->user()->login_user ?? 'desconocido',
                    'ip' => request()->ip()
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdUser', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line' => $e->getLine(),
                'usuario_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function addUser(Request $request)
    {
        try {
            // 1. Validar los datos de entrada
            $validator = Validator::make($request->all(), [
                'name' => 'required|string|max:255',
                'surname' => 'required|string|max:255',
                'login_user' => 'required|string|max:100',
                'email' => 'required|email|max:255',
                'password' => 'required|string|min:8',
                'phone' => 'nullable|string|max:20',
                'avatar' => 'nullable|string|max:255',
                'isactive' => 'boolean',
                'perfil_id' => 'nullable|integer',
                'chorario_id' => 'nullable|integer'
            ]);
            
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            
            $validatedData = $validator->validated();
            
            // 2. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            // 3. Llamar a la función de PostgreSQL con CAST explícito
            $result = DB::selectOne('
                SELECT seguridad.fn_usuarios_crear(
                    ?::VARCHAR,   -- p_name
                    ?::VARCHAR,   -- p_surname
                    ?::VARCHAR,   -- p_email
                    ?::VARCHAR,   -- p_phone
                    ?::VARCHAR,   -- p_login_user
                    ?::VARCHAR,   -- p_password
                    ?::VARCHAR,   -- p_avatar
                    ?::BOOLEAN,   -- p_isactive
                    ?::INTEGER,   -- p_perfil_id
                    ?::INTEGER,   -- p_chorario_id
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                $validatedData['name'],
                $validatedData['surname'],
                $validatedData['email'],
                $validatedData['phone'] ?? null,
                $validatedData['login_user'],
                bcrypt($validatedData['password']),
                $validatedData['avatar'] ?? null,
                $validatedData['isactive'] ?? true,
                $validatedData['perfil_id'] ?? 1,
                $validatedData['chorario_id'] ?? null,
                $usuarioId ? (int)$usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);
            
            // 4. Decodificar el resultado
            $resultado = json_decode($result->result, true);
            
            // 5. Evaluar respuesta
            if ($resultado['success']) {
                sistemaLog('info', 'Usuario creado exitosamente', [
                    'usuario_id' => $resultado['data']['id'],
                    'login_user' => $resultado['data']['login_user'],
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addUser', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line' => $e->getLine(),
                'data' => $request->all()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function editUser(Request $request, $id)
    {
        try {
            // 1. Obtener el JSON del campo 'json'
            $jsonData = $request->input('json');
            
            if (!$jsonData) {
                return $this->errorResponse('No se enviaron datos válidos', 400);
            }
            
            // 2. Decodificar el JSON
            $data = json_decode($jsonData, true);
            
            if (json_last_error() !== JSON_ERROR_NONE) {
                return $this->errorResponse('Formato JSON inválido', 400);
            }
            
            // 3. Validar los datos decodificados
            $validator = Validator::make($data, [
                'name' => 'required|string|max:255',
                'surname' => 'required|string|max:255',
                'email' => 'required|email|max:255',
                'phone' => 'nullable|string|max:20',
                'login_user' => 'required|string|max:100',
                'avatar' => 'nullable|string|max:255',
                'isactive' => 'required|boolean',
                'type_user' => 'nullable|integer',
                'perfil_id' => 'nullable|integer',
                'chorario_id' => 'nullable|integer'
            ]);
            
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 400);
            }
            
            $validatedData = $validator->validated();
            
            // 4. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            // 5. Llamar a la función de PostgreSQL con el orden correcto
            $result = DB::selectOne('
                SELECT seguridad.fn_usuarios_modificar(
                    ?::BIGINT,      -- 1. p_id
                    ?::VARCHAR,     -- 2. p_name
                    ?::VARCHAR,     -- 3. p_surname
                    ?::VARCHAR,     -- 4. p_email
                    ?::VARCHAR,     -- 5. p_phone
                    ?::VARCHAR,     -- 6. p_login_user
                    ?::VARCHAR,     -- 7. p_avatar
                    ?::BOOLEAN,     -- 8. p_isactive
                    ?::INTEGER,     -- 9. p_type_user
                    ?::INTEGER,     -- 10. p_perfil_id
                    ?::INTEGER,     -- 11. p_chorario_id
                    ?::BIGINT,      -- 12. p_usuario_id
                    ?::VARCHAR,     -- 13. p_usuario_login
                    ?::VARCHAR,     -- 14. p_usuario_nombre
                    ?::INET,        -- 15. p_ip_address
                    ?::TEXT,        -- 16. p_user_agent
                    ?::UUID         -- 17. p_request_id
                ) as result
            ', [
                (int)$id,                                    // 1. p_id
                $validatedData['name'],                      // 2. p_name
                $validatedData['surname'],                   // 3. p_surname
                $validatedData['email'],                     // 4. p_email
                $validatedData['phone'] ?? null,             // 5. p_phone
                $validatedData['login_user'],                // 6. p_login_user
                $validatedData['avatar'] ?? null,            // 7. p_avatar
                $validatedData['isactive'] ? 'true' : 'false', // 8. p_isactive
                $validatedData['type_user'] ?? null,         // 9. p_type_user (¡AGREGADO!)
                $validatedData['perfil_id'] ?? null,         // 10. p_perfil_id
                $validatedData['chorario_id'] ?? null,       // 11. p_chorario_id
                $usuarioId,                                  // 12. p_usuario_id
                $usuarioLogin,                               // 13. p_usuario_login
                $usuarioNombre,                              // 14. p_usuario_nombre
                $request->ip(),                              // 15. p_ip_address
                $request->userAgent(),                       // 16. p_user_agent
                (string) Str::uuid()                         // 17. p_request_id
            ]);
            
            // 6. Decodificar el resultado
            $resultado = json_decode($result->result, true);
            
            // 7. Evaluar respuesta
            if ($resultado['success']) {
                sistemaLog('info', 'Usuario actualizado exitosamente', [
                    'usuario_id' => $id,
                    'login_user' => $resultado['data']['login_user'],
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editUser', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line' => $e->getLine(),
                'usuario_id' => $id,
                'data' => $request->all()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function deleteUser(Request $request, $id)
    {
        try {
            // 1. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

            // 2. Llamar a la función de PostgreSQL con CAST explícito
            $result = DB::selectOne('
                SELECT seguridad.fn_usuarios_eliminar(
                    ?::BIGINT,    -- p_id
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                (int)$id,
                $usuarioId ? (int)$usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);

            // 3. Decodificar el resultado
            $resultado = json_decode($result->result, true);

            // 4. Evaluar respuesta
            if ($resultado['success']) {
                // Eliminar imagen si existe
                if (!empty($resultado['data']['avatar'])) {
                    $this->eliminarImagenUsuarioPorNombre($resultado['data']['avatar']);
                }
                
                sistemaLog('info', 'Usuario eliminado exitosamente', [
                    'usuario_id' => $id,
                    'login_user' => $resultado['data']['login_user'] ?? 'desconocido',
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400);
            }

        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteUser', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line' => $e->getLine(),
                'usuario_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
        
    public function getImagenUsuario($id)
    {
        try {
            $result = DB::selectOne('SELECT avatar FROM seguridad.users WHERE id = ?', [(int)$id]);
            
            if (!$result || !$result->avatar) {
                return $this->errorResponse('El usuario no tiene imagen asociada', 404);
            }

            // ✅ CORREGIDO: usar la misma ruta que funciona
            $path = storage_path('app/public/img/users/' . $result->avatar);
            
            if (!file_exists($path)) {
                return $this->errorResponse('La imagen no existe en el servidor', 404);
            }

            return response()->file($path, [
                'Content-Type' => mime_content_type($path),
                'Cache-Control' => 'public, max-age=31536000'
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
                'UserId' => 'required|integer',
            ]);

            if ($validator->fails()) {
                DB::rollBack();
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $userId = (int) $request->UserId;
            
            // Verificar que el usuario existe
            $userExists = DB::selectOne('SELECT id FROM seguridad.users WHERE id = ?', [$userId]);
            
            if (!$userExists) {
                DB::rollBack();
                return $this->errorResponse('Usuario no encontrado', 404);
            }

            if (!$request->hasFile('imagen_file')) {
                DB::rollBack();
                return $this->errorResponse('No se encontró la imagen para guardar', 400);
            }

            // Obtener avatar anterior
            $avatarAnterior = DB::selectOne('SELECT avatar FROM seguridad.users WHERE id = ?', [$userId]);

            $file = $request->file('imagen_file');
            $extension = $file->getClientOriginalExtension();
            $filename = $userId . '_userimg.' . $extension;
            
            // Guardar imagen
            $file->storeAs('public/img/users', $filename);
            
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            // ✅ Llamada corregida
            $result = DB::selectOne("
                SELECT seguridad.fn_usuarios_imagen(
                    ?::BIGINT, 
                    ?::VARCHAR, 
                    ?::BIGINT, 
                    ?::VARCHAR, 
                    ?::VARCHAR, 
                    ?::INET, 
                    ?::TEXT, 
                    ?::UUID
                ) as result
            ", [
                $userId,
                $filename,
                $usuarioId,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);
            
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                // Eliminar avatar anterior
                if ($avatarAnterior && $avatarAnterior->avatar) {
                    $oldImagePath = storage_path('app/public/img/users/' . $avatarAnterior->avatar);
                    if (file_exists($oldImagePath)) {
                        unlink($oldImagePath);
                    }
                }
                
                DB::commit();
                
                sistemaLog('info', 'Imagen guardada exitosamente', [
                    'user_id' => $userId,
                    'avatar' => $filename,
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                
                return $this->successResponse([
                    'avatar' => $resultado['data']['avatar'],
                    'full_path' => asset('storage/img/users/' . $resultado['data']['avatar'])
                ], $resultado['message']);
            } else {
                // Eliminar imagen guardada si la BD falló
                $newImagePath = storage_path('app/public/img/users/' . $filename);
                if (file_exists($newImagePath)) {
                    unlink($newImagePath);
                }
                DB::rollBack();
                return $this->errorResponse($resultado['message'], 400);
            }
            
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error en addImagen', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line' => $e->getLine(),
                'user_id' => $request->UserId ?? null
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    private function eliminarImagenUsuarioPorNombre($avatar)
    {
        if ($avatar) {
            $path = storage_path('app/public/img/users/' . $avatar);
            if (file_exists($path)) {
                unlink($path);
            }
        }
    }

    public function changePassword(Request $request, $id)
    {
        try {
            // 1. Validar los datos
            $validator = Validator::make($request->all(), [
                'password' => 'required|string|min:8',
                'email' => 'required|email',
                'isreset' => 'nullable|boolean'
            ]);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $validatedData = $validator->validated();
            
            // 2. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            // 3. Verificar que el usuario existe
            $userExists = DB::selectOne('SELECT id, email, name FROM seguridad.users WHERE id = ?', [$id]);
            if (!$userExists) {
                return $this->errorResponse('Usuario no encontrado', 404);
            }
            
            // 4. Encriptar la contraseña
            $hashedPassword = bcrypt($validatedData['password']);
            
            // 5. Llamar a la función de PostgreSQL
            $result = DB::selectOne('
                SELECT seguridad.fn_usuarios_cambiar_password(
                    ?::BIGINT,    -- p_id
                    ?::VARCHAR,   -- p_password
                    ?::BOOLEAN,   -- p_isreset
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                (int)$id,
                $hashedPassword,
                $validatedData['isreset'] ?? false,
                $usuarioId ? (int)$usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);
            
            // 6. Decodificar el resultado
            $resultado = json_decode($result->result, true);
            
            // 7. Evaluar respuesta
            if ($resultado['success']) {
                // Enviar email de notificación
                try {
                    $emailController = new EmailController();
                    
                    // Crear objeto para la vista (igual que antes)
                    $object = (object) [
                        'email' => $userExists->email,
                        'password' => $validatedData['password']
                    ];
                    
                    // Adjuntos (logo)
                    $attachments = [];
                    $logoPath = public_path('storage/img/mail/mail.png');
                    if (file_exists($logoPath)) {
                        $attachments[] = [
                            'path' => $logoPath,
                            'as' => 'logo.png',
                            'mime' => 'image/png'
                        ];
                    }
                    
                    // Enviar correo con el método parametrizable
                    // para que funione revisa .env y config/mail.php
                    $emailController->send_email(
                        $userExists->email,  // destinatario
                        $object,  //data
                        'Cambio de Contraseña - ' . env('APP_NAME'),  // ASUNTO
                        'mail.password-changed',  // Vista blade actual
                        $attachments
                    );
                    
                    // Ejemplo: Enviar correo de bienvenida
                    // $emailController = new EmailController();
                    // $object = (object) [
                    //     'email' => $user->email,
                    //     'name' => $user->name
                    // ];
                    // $emailController->send_email(
                    //     $user->email,
                    //     $object,
                    //     'Bienvenido a ' . env('APP_NAME'),
                    //     'mail.welcome',
                    //     []  // sin adjuntos
                    // );


                } catch (Exception $e) {
                    sistemaLog('warning', 'Error al enviar email de notificación', [
                        'message' => $e->getMessage(),
                        'usuario_id' => $id
                    ]);
                }
                
                sistemaLog('info', 'Contraseña cambiada exitosamente', [
                    'usuario_id' => $id,
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en changePassword', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line' => $e->getLine(),
                'usuario_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function changePasswordLogin(Request $request, $id)
    {
        try {
            // 1. Validar los datos
            $validator = Validator::make($request->all(), [
                'password' => 'required|string|min:8',
                'isreset' => 'nullable|boolean'
            ]);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $validatedData = $validator->validated();
            
            // 2. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            // 3. Verificar que el usuario existe
            $userExists = DB::selectOne('SELECT id, email, name FROM seguridad.users WHERE id = ?', [$id]);
            if (!$userExists) {
                return $this->errorResponse('Usuario no encontrado', 404);
            }
            
            // 4. Encriptar la contraseña
            $hashedPassword = bcrypt($validatedData['password']);
            
            // 5. Llamar a la función de PostgreSQL
            $result = DB::selectOne('
                SELECT seguridad.fn_usuarios_cambiar_password(
                    ?::BIGINT,    -- p_id
                    ?::VARCHAR,   -- p_password
                    ?::BOOLEAN,   -- p_isreset
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                (int)$id,
                $hashedPassword,
                $validatedData['isreset'] ?? false,
                $usuarioId ? (int)$usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);
            
            // 6. Decodificar el resultado
            $resultado = json_decode($result->result, true);
            
            // 7. Evaluar respuesta
            if ($resultado['success']) {
                // Enviar email de notificación
                try {
                    $emailController = new EmailController();
                    
                    // Crear objeto para la vista (igual que antes)
                    $object = (object) [
                        'email' => $userExists->email,
                        'name' =>  $userExists->name
                    ];
                    
                    // Adjuntos (logo)
                    $attachments = [];
                    $logoPath = public_path('storage/img/mail/mail.png');
                    if (file_exists($logoPath)) {
                        $attachments[] = [
                            'path' => $logoPath,
                            'as' => 'logo.png',
                            'mime' => 'image/png'
                        ];
                    }
                    
                    // Enviar correo con el método parametrizable
                    // para que funione revisa .env y config/mail.php
                    $emailController->send_email(
                        $userExists->email,  // destinatario
                        $object,  //data
                        'Cambio de Contraseña - ' . env('APP_NAME'),  // ASUNTO
                        'mail.password-changed-login',  // Vista blade actual
                        $attachments
                    );
                    
                    // Ejemplo: Enviar correo de bienvenida
                    // $emailController = new EmailController();
                    // $object = (object) [
                    //     'email' => $user->email,
                    //     'name' => $user->name
                    // ];
                    // $emailController->send_email(
                    //     $user->email,
                    //     $object,
                    //     'Bienvenido a ' . env('APP_NAME'),
                    //     'mail.welcome',
                    //     []  // sin adjuntos
                    // );


                } catch (Exception $e) {
                    sistemaLog('warning', 'Error al enviar email de notificación', [
                        'message' => $e->getMessage(),
                        'usuario_id' => $id
                    ]);
                }
                
                sistemaLog('info', 'Contraseña cambiada exitosamente', [
                    'usuario_id' => $id,
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en changePassword', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line' => $e->getLine(),
                'usuario_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }













    public function listUsers()
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_usuarios_listar_activos() as result');
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                sistemaLog('info', 'listUsers ejecutado correctamente', [
                    'total_registros' => count($resultado['data']),
                    'usuario' => auth('api')->user()->login_user ?? 'desconocido',
                    'ip' => request()->ip()
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en listUsers', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line' => $e->getLine()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }






// /**
//  * Verificar si el usuario existe y está activo
//  */
public function verificarUsuarioRecuperacion(Request $request)
{
    try {
        $validator = Validator::make($request->all(), [
            'login_user' => 'required|string|max:100'
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        $login_user = $request->login_user;
        
        // Buscar usuario activo
        $user = DB::selectOne('
            SELECT id, login_user, email 
            FROM seguridad.users 
            WHERE login_user = ? AND isactive = true
        ', [$login_user]);
        
        if (!$user) {
            return $this->errorResponse('Usuario no encontrado o inactivo', 404);
        }
        
        return $this->successResponse([
            'email' => $user->email,
            'login_user' => $user->login_user
        ], 'Usuario verificado correctamente');
        
    } catch (Exception $e) {
        return $this->errorResponse($e->getMessage(), 500);
    }
}

/**
 * Solicitar recuperación - Genera código y lo envía al correo
 */
// public function solicitarRecuperacion(Request $request)
// {
//     try {
//         $validator = Validator::make($request->all(), [
//             'login_user' => 'required|string|max:100'
//         ]);

//         if ($validator->fails()) {
//             return $this->errorResponse($validator->errors()->first(), 422);
//         }

//         $login_user = $request->login_user;
        
//         // Llamar a la función de PostgreSQL
//         $result = DB::selectOne('
//             SELECT seguridad.fn_usuarios_solicitar_recuperacion(
//                 ?::VARCHAR,
//                 ?::INET,
//                 ?::TEXT,
//                 ?::UUID
//             ) as result
//         ', [
//             $login_user,
//             $request->ip(),
//             $request->userAgent(),
//             (string) Str::uuid()
//         ]);
        
//         $resultado = json_decode($result->result, true);
        
//         if (!$resultado['success']) {
//             return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
//         }
        
//         $data = $resultado['data'];
        
//         // Enviar correo con el código
//         try {
//             $emailController = new EmailController();
            
//             $object = (object) [
//                 'name' => $data['name'],
//                 'login_user' => $data['login_user'],
//                 'email' => $data['email'],
//                 'codigo' => $data['codigo'],
//                 'expira' => $data['expira_en'],
//                 'fecha' => now()->format('d/m/Y H:i:s')
//             ];
            
//             $attachments = [];
//             $logoPath = public_path('storage/img/mail/mail.png');
//             if (file_exists($logoPath)) {
//                 $attachments[] = [
//                     'path' => $logoPath,
//                     'as' => 'logo.png',
//                     'mime' => 'image/png'
//                 ];
//             }
            
//             $emailController->send_email(
//                 $data['email'],
//                 $object,
//                 '🔐 Código de Recuperación - ' . env('APP_NAME'),
//                 'mail.password-recovery-code',
//                 $attachments
//             );
            
//             sistemaLog('info', 'Código de recuperación enviado', [
//                 'usuario_id' => $data['id'],
//                 'email' => $data['email'],
//                 'ip' => $request->ip()
//             ]);
            
//             // No devolvemos el código en la respuesta por seguridad
//             return $this->successResponse([
//                 'email' => $data['email']
//             ], 'Código enviado a tu correo electrónico');
            
//         } catch (Exception $e) {
//             sistemaLog('error', 'Error al enviar correo de recuperación', [
//                 'message' => $e->getMessage(),
//                 'usuario_id' => $data['id']
//             ]);
//             return $this->errorResponse('Error al enviar el correo: ' . $e->getMessage(), 500);
//         }
        
//     } catch (Exception $e) {
//         sistemaLog('error', 'Error en solicitarRecuperacion', [
//             'code' => $e->getCode(),
//             'message' => $e->getMessage(),
//             'line' => $e->getLine()
//         ]);
//         return $this->errorResponse($e->getMessage(), 500);
//     }
// }

/**
 * Solicitar recuperación - Genera código y lo envía al correo
 */
public function solicitarRecuperacion(Request $request)
{
    try {
        $validator = Validator::make($request->all(), [
            'login_user' => 'required|string|max:100'
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        $login_user = $request->login_user;
        
        // Obtener datos del usuario ANTES de llamar a la función
        $user = DB::selectOne('
            SELECT id, login_user, name, email
            FROM seguridad.users 
            WHERE login_user = ? AND isactive = true
        ', [$login_user]);
        
        if (!$user) {
            return $this->errorResponse('Usuario no encontrado o inactivo', 404);
        }
        
        // Llamar a la función de PostgreSQL con los datos del usuario
        $result = DB::selectOne('
            SELECT seguridad.fn_usuarios_solicitar_recuperacion(
                ?::VARCHAR,   -- p_login_user
                ?::BIGINT,    -- p_usuario_id (el ID del usuario que solicita)
                ?::VARCHAR,   -- p_usuario_login (el login del usuario)
                ?::VARCHAR,   -- p_usuario_nombre (el nombre del usuario)
                ?::INET,      -- p_ip_address
                ?::TEXT,      -- p_user_agent
                ?::UUID       -- p_request_id
            ) as result
        ', [
            $login_user,
            $user->id,                    // p_usuario_id
            $user->login_user,            // p_usuario_login
            $user->name,                  // p_usuario_nombre
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid()
        ]);
        
        $resultado = json_decode($result->result, true);
        
        if (!$resultado['success']) {
            return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
        }
        
        $data = $resultado['data'];
        
        // Enviar correo con el código
        try {
            $emailController = new EmailController();
            
            $object = (object) [
                'name' => $data['name'],
                'login_user' => $data['login_user'],
                'email' => $data['email'],
                'codigo' => $data['codigo'],
                'expira' => $data['expira_en'],
                'fecha' => now()->format('d/m/Y H:i:s')
            ];
            
            $attachments = [];
            $logoPath = public_path('storage/img/mail/mail.png');
            if (file_exists($logoPath)) {
                $attachments[] = [
                    'path' => $logoPath,
                    'as' => 'logo.png',
                    'mime' => 'image/png'
                ];
            }
            
            $emailController->send_email(
                $data['email'],
                $object,
                '🔐 Código de Recuperación - ' . env('APP_NAME'),
                'mail.password-recovery-code',
                $attachments
            );
            
            sistemaLog('info', 'Código de recuperación enviado', [
                'usuario_id' => $data['id'],
                'email' => $data['email'],
                'ip' => $request->ip()
            ]);
            
            // No devolvemos el código en la respuesta por seguridad
            return $this->successResponse([
                'email' => $data['email']
            ], 'Código enviado a tu correo electrónico');
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error al enviar correo de recuperación', [
                'message' => $e->getMessage(),
                'usuario_id' => $data['id']
            ]);
            return $this->errorResponse('Error al enviar el correo: ' . $e->getMessage(), 500);
        }
        
    } catch (Exception $e) {
        sistemaLog('error', 'Error en solicitarRecuperacion', [
            'code' => $e->getCode(),
            'message' => $e->getMessage(),
            'line' => $e->getLine()
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
}




/**
 * Verificar código de recuperación
 */
public function verificarRecuperacion(Request $request)
{
    try {
        $validator = Validator::make($request->all(), [
            'login_user' => 'required|string',
            'codigo' => 'required|string|min:6|max:6'
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        $result = DB::selectOne('
            SELECT seguridad.fn_usuarios_verificar_recuperacion(
                ?::VARCHAR,
                ?::VARCHAR
            ) as result
        ', [
            $request->login_user,
            $request->codigo
        ]);
        
        $resultado = json_decode($result->result, true);
        
        if (!$resultado['success']) {
            return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
        }
        
        return $this->successResponse($resultado['data'], 'Código verificado correctamente');
        
    } catch (Exception $e) {
        sistemaLog('error', 'Error en verificarRecuperacion', [
            'code' => $e->getCode(),
            'message' => $e->getMessage(),
            'line' => $e->getLine()
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
}

/**
 * Cambiar contraseña después de verificar código
 */
public function cambiarPasswordRecuperacion(Request $request)
{
    try {
        $validator = Validator::make($request->all(), [
            'login_user' => 'required|string',
            'email' => 'required|email',
            'password' => 'required|string|min:8',
            'codigo' => 'required|string|min:6|max:6'
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        // Primero verificar el código
        $verifyResult = DB::selectOne('
            SELECT seguridad.fn_usuarios_verificar_recuperacion(
                ?::VARCHAR,
                ?::VARCHAR
            ) as result
        ', [
            $request->login_user,
            $request->codigo
        ]);
        
        $verifyData = json_decode($verifyResult->result, true);
        
        if (!$verifyData['success']) {
            return $this->errorResponse($verifyData['message'], 400);
        }
        
        $userData = $verifyData['data'];
        
        // Verificar que el email coincide
        if ($userData['email'] !== $request->email) {
            return $this->errorResponse('El email no coincide con el usuario', 400);
        }
        
        // Cambiar la contraseña
        $hashedPassword = bcrypt($request->password);
        
        $result = DB::selectOne('
            SELECT seguridad.fn_usuarios_cambiar_password(
                ?::BIGINT,
                ?::VARCHAR,
                ?::BOOLEAN,
                ?::BIGINT,
                ?::VARCHAR,
                ?::VARCHAR,
                ?::INET,
                ?::TEXT,
                ?::UUID
            ) as result
        ', [
            (int)$userData['id'],
            $hashedPassword,
            false, // isreset = true
            null,
            'sistema',
            'Recuperación de Contraseña',
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid()
        ]);
        
        $resultado = json_decode($result->result, true);
        
        if ($resultado['success']) {
            // Limpiar código de recuperación
            DB::selectOne('
                SELECT seguridad.fn_usuarios_limpiar_recuperacion(?::BIGINT) as result
            ', [(int)$userData['id']]);
            
            // Enviar correo de confirmación
            try {
                $emailController = new EmailController();
                
                $object = (object) [
                    'name' => $userData['name'],
                    'login_user' => $request->login_user,
                    'email' => $userData['email'],
                    'fecha' => now()->format('d/m/Y H:i:s')
                ];
                
                $attachments = [];
                $logoPath = public_path('storage/img/mail/mail.png');
                if (file_exists($logoPath)) {
                    $attachments[] = [
                        'path' => $logoPath,
                        'as' => 'logo.png',
                        'mime' => 'image/png'
                    ];
                }
                
                $emailController->send_email(
                    $userData['email'],
                    $object,
                    'Contraseña actualizada - ' . env('APP_NAME'),
                    'mail.password-changed-success',
                    $attachments
                );
                
            } catch (Exception $e) {
                sistemaLog('warning', 'Error al enviar email de confirmación', [
                    'message' => $e->getMessage()
                ]);
            }
            
            return $this->successResponse($resultado['data'], 'Contraseña actualizada correctamente');
        } else {
            return $this->errorResponse($resultado['message'], 400);
        }
        
    } catch (Exception $e) {
        sistemaLog('error', 'Error en cambiarPasswordRecuperacion', [
            'code' => $e->getCode(),
            'message' => $e->getMessage(),
            'line' => $e->getLine()
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
}







}
















    // public function addImagen(Request $request){
    //     DB::beginTransaction();
        
    //     try {
    //         // Validación (se mantiene igual)
    //         $validator = Validator::make($request->all(), [
    //             'UserId' => 'required|integer',
    //             //'imagen_file' => 'required|image|mimes:jpeg,png,jpg,gif|max:2048',
    //         ]);

    //         if ($validator->fails()) {
    //             return $this->errorResponse($validator->errors(), 422);
    //         }

    //         $user = User::findOrFail($request->UserId);

    //         if ($request->hasFile('imagen_file')) {
    //             // Eliminar todas las variaciones de imagen del usuario
    //             $deletedFiles = [];
    //             $basePath = storage_path('app/public/img/users/');
    //             $searchPattern = $basePath.$user->id.'_userimg*';
    //             foreach (glob($searchPattern) as $filePath) {
    //                 if (file_exists($filePath)) {
    //                     unlink($filePath);
    //                     $deletedFiles[] = basename($filePath);
    //                 }
    //             }
    //             if (empty($deletedFiles)) {
    //                 \Log::warning('No se encontraron imágenes para eliminar', [
    //                     'user_id' => $user->id,
    //                     'pattern' => $searchPattern
    //                 ]);
    //             } else {
    //                 \Log::info('Imágenes eliminadas', [
    //                     'user_id' => $user->id,
    //                     'files' => $deletedFiles
    //                 ]);
    //             }


    //             $file = $request->file('imagen_file');
    //             $filename = $user->id . '_userimg' .  '.' . $file->getClientOriginalExtension();
                
    //             $path = $file->storeAs('public/img/users', $filename);
    //             $user->avatar = $filename;
    //             $user->save();

    //             DB::commit();
                
    //             return $this->successResponse([
    //                 'avatar' => $user->avatar,
    //                 'full_path' => asset('storage/img/users/' . $user->avatar)
    //             ], 'Imagen guardada con éxito');

    //         }

    //         return $this->errorResponse('No se encontró la imagen para guardar', 400);

    //     } catch (Exception $e) {
    //         DB::rollBack();
    //         return $this->errorResponse($e->getMessage(), 500);
    //     }
    // }
