<?php

namespace App\Http\Controllers\auth;

use App\Http\Controllers\Controller;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Facades\DB;
use App\Models\auth\User;
use App\Http\Resources\ApiResponder;
use Carbon\Carbon;
use Tymon\JWTAuth\Facades\JWTAuth;
use App\Helpers\UserAgentHelper;




class AuthController extends Controller
{
    use ApiResponder;

    private $maxSesionesPorUsuario = 4; // Máximo de sesiones simultáneas

    public function __construct()
    {
        $this->middleware('auth:api', [
            'except' => [
                'login',
                'logout',
                'register',
                'getMySessions',
                'closeSession',
                'logoutAllOtherSessions',
                'closeInactiveSessions'
            ]
        ]);
    }









    public function register()
    {
        $validator = Validator::make(request()->all(), [
            'name' => 'required|string|max:100',
            'surname' => 'required|string|max:100',
            'login_user' => 'required|alpha_dash|max:30|unique:seguridad.users,login_user',
            'email' => 'required|email|max:100|unique:seguridad.users,email',
            'password' => 'required|min:8|regex:/^(?=.*[a-z])(?=.*[A-Z])(?=.*\d)/',
            'phone' => 'required|string|max:30',
            'profile_id' => 'required|exists:seguridad.perfiles,id',
            'chorario_id' => 'required|exists:seguridad.chorarios,id'
        ]);

        if ($validator->fails()) {
            return response()->json($validator->errors()->toJson(), 400);
        }

        // Insert directo con SQL
        $userId = DB::table('seguridad.users')->insertGetId([
            'name' => request()->name,
            'surname' => request()->surname,
            'login_user' => request()->login_user,
            'email' => request()->email,
            'phone' => request()->phone,
            'password' => bcrypt(request()->password),
            'type_user' => 1,
            'perfil_id' => request()->profile_id,
            'chorario_id' => request()->chorario_id,
            'isactive' => true,
            'islogin' => false,
            'isreset' => false,
            'created_at' => Carbon::now(),
            'updated_at' => Carbon::now(),
            'created_by' => request()->login_user,
            'updated_by' => request()->login_user
        ]);

        $user = DB::selectOne("SELECT * FROM seguridad.users WHERE id = ?", [$userId]);

        return $this->successResponse($user, 'Se registró con éxito');
    }



















    public function login()
    {
        // 1. VALIDACIÓN DE CAMPOS
        $validator = Validator::make(request()->all(), [
            'login_user' => 'required|string|max:30',
            'password' => 'required|string'
        ]);

        if ($validator->fails()) {
            return $this->errorResponse('Los campos no pueden estar vacíos', 400);
        }

        $login_user = request()->login_user;
        $password = request()->password;

        // 2. BUSCAR USUARIO
        $user = DB::selectOne(
            "SELECT 
                u.id,
                u.name,
                u.surname,
                u.login_user,
                u.email,
                u.avatar,
                u.perfil_id,
                u.isreset,
                u.password,
                u.isactive,
                p.nombre as perfil_nombre,
                p.activo as perfil_activo,
                p.inactividad as perfil_inactividad
             FROM seguridad.users u
             INNER JOIN seguridad.perfiles p ON p.id = u.perfil_id
             WHERE u.login_user = ?",
            [$login_user]
        );

        // 3. VALIDACIONES
        if (!$user) {
            usleep(rand(200000, 500000));
            return $this->errorResponse('Credenciales inválidas', 401);
        }
        
        if ($user->isactive != true) {
            usleep(rand(200000, 500000));
            return $this->errorResponse('Usuario inactivo', 401);
        }
        
        if ($user->perfil_activo != true) {
            usleep(rand(200000, 500000));
            return $this->errorResponse('Perfil inactivo', 401);
        }
        
        if (!password_verify($password, $user->password)) {
            usleep(rand(200000, 500000));
            return $this->errorResponse('Contraseña incorrecta', 401);
        }

        // 4. CONTROL DE SESIONES MÚLTIPLES
        // Contar sesiones activas del usuario
        $sesionesActivas = DB::selectOne(
            "SELECT COUNT(*) as total 
             FROM seguridad.sesiones_activas 
             WHERE user_id = ? AND is_active = true",
            [$user->id]
        );

        if ($sesionesActivas->total >= $this->maxSesionesPorUsuario) {
            // Opción 1: Rechazar el login
            return $this->errorResponse(
                "Has alcanzado el máximo de {$this->maxSesionesPorUsuario} sesiones activas. 
                 Cierra alguna sesión antes de iniciar otra.",
                401
            );
            
            // Opción 2: Cerrar automáticamente la sesión más antigua
            // $this->cerrarSesionMasAntigua($user->id);
        }

        // 5. GENERAR TOKEN JWT
        $userModel = User::find($user->id);
        if (!$token = auth('api')->login($userModel)) {
            return $this->errorResponse('No se pudo generar token', 500);
        }

        // 6. OBTENER JTI DEL TOKEN
        $payload = JWTAuth::setToken($token)->getPayload();
        $jti = $payload->get('jti');

        // 7. DETECTAR INFORMACIÓN DEL NAVEGADOR
        $userAgentInfo = UserAgentHelper::parse(request()->userAgent());

        // 8. REGISTRAR SESIÓN ACTIVA
        DB::insert(
            "INSERT INTO seguridad.sesiones_activas 
             (user_id, token_id, ip_address, user_agent, navegador, sistema_operativo, dispositivo, last_activity, created_at, is_active)
             VALUES (?, ?, ?, ?, ?, ?, ?, NOW(), NOW(), true)",
            [
                $user->id,
                $jti,
                request()->ip(),
                request()->userAgent(),
                $userAgentInfo['navegador'],
                $userAgentInfo['sistema_operativo'],
                $userAgentInfo['dispositivo']
            ]
        );

        // 9. ACTUALIZAR DATOS DEL USUARIO
        DB::update(
            "UPDATE seguridad.users 
             SET last_login_at = NOW(), 
                 user_verified_at = COALESCE(user_verified_at, NOW())
             WHERE id = ?",
            [$user->id]
        );

        return $this->respondWithToken($token, $user);
    }






    /**
     * Cerrar todas las sesiones de un usuario (excepto la actual)
     */
    public function logoutAllOtherSessions()
    {
        $userId = auth('api')->user()->id;
        $currentJti = JWTAuth::getPayload()->get('jti');
        
        DB::delete(
            "DELETE FROM seguridad.sesiones_activas 
             WHERE user_id = ? AND token_id != ?",
            [$userId, $currentJti]
        );
        
        return $this->successResponse(null, 'Todas las otras sesiones fueron cerradas');
    }














    
    /**
     * Obtener todas las sesiones activas del usuario actual
     */
  public function getMySessions()
{
    // Obtener usuario autenticado (el middleware auth:api ya verificó el token)
    $user = auth('api')->user();
    
    if (!$user) {
        return $this->errorResponse('No autenticado', 401);
    }
    
    // Obtener el jti actual (opcional, solo para marcar sesión actual)
    $currentJti = null;
    try {
        $currentJti = JWTAuth::getPayload()->get('jti');
    } catch (\Exception $e) {
        // Ignorar error, solo no marcaremos sesión actual
    }
    
    // Consultar sesiones
    $sessions = DB::select(
        "SELECT 
            id,
            token_id,
            ip_address,
            navegador,
            sistema_operativo,
            dispositivo,
            last_activity,
            created_at
         FROM seguridad.sesiones_activas
         WHERE user_id = ? AND is_active = true
         ORDER BY last_activity DESC",
        [$user->id]
    );
    
    // Agregar flag de sesión actual
    foreach ($sessions as $session) {
        $session->is_current_session = ($currentJti && $session->token_id === $currentJti);
    }
    
    return $this->successResponse($sessions, 'Sesiones activas');
}



    /**
     * Cerrar una sesión específica por su ID
     */
public function closeSession($sessionId)
{
    try {
        // 1. VERIFICAR USUARIO AUTENTICADO
        $user = auth('api')->user();
        
        if (!$user) {
            return $this->errorResponse('Usuario no autenticado', 401);
        }
        
        $userId = $user->id;
        
        // 2. OBTENER JTI DEL TOKEN ACTUAL (para no permitir cerrar la sesión actual)
        $currentJti = null;
        try {
            $currentJti = JWTAuth::getPayload()->get('jti');
        } catch (\Exception $e) {
            // Si no se puede obtener, continuar
        }
        
        // 3. BUSCAR LA SESIÓN
        $session = DB::selectOne(
            "SELECT token_id FROM seguridad.sesiones_activas 
             WHERE id = ? AND user_id = ? AND is_active = true",
            [$sessionId, $userId]
        );
        
        if (!$session) {
            return $this->errorResponse('Sesión no encontrada', 404);
        }
        
        // 4. NO PERMITIR CERRAR LA SESIÓN ACTUAL
        if ($currentJti && $session->token_id === $currentJti) {
            return $this->errorResponse('No puedes cerrar tu sesión actual. Usa logout para eso.', 400);
        }
        
        // 5. ELIMINAR LA SESIÓN
        DB::delete(
            "DELETE FROM seguridad.sesiones_activas WHERE id = ?",
            [$sessionId]
        );
        
        \Log::info('Sesión cerrada manualmente', [
            'user_id' => $userId,
            'session_id' => $sessionId,
            'ip' => request()->ip()
        ]);
        
        return $this->successResponse(null, 'Sesión cerrada exitosamente');
        
    } catch (\Exception $e) {
        \Log::error('Error en closeSession: ' . $e->getMessage());
        return $this->errorResponse('Error al cerrar sesión', 500);
    }
}










    /**
     * Cerrar sesiones inactivas (para admin)
     */
    public function closeInactiveSessions($minutesInactive = 60)
    {
        $deleted = DB::delete(
            "DELETE FROM seguridad.sesiones_activas 
             WHERE last_activity < NOW() - INTERVAL '{$minutesInactive} minutes'"
        );
        
        return $this->successResponse(
            ['deleted' => $deleted],
            "Se cerraron {$deleted} sesiones inactivas"
        );
    }




















    /**
     * Middleware para actualizar last_activity
     */
    public function updateActivity()
    {
        if (auth('api')->check()) {
            $jti = JWTAuth::getPayload()->get('jti');
            
            DB::update(
                "UPDATE seguridad.sesiones_activas 
                 SET last_activity = NOW() 
                 WHERE token_id = ?",
                [$jti]
            );
        }
    }

















    protected function respondWithToken($token, $user)
    {
        $userId = $user->id;
        
        // Contar sesiones activas del usuario
        $sesionesCount = DB::selectOne(
            "SELECT COUNT(*) as total 
             FROM seguridad.sesiones_activas 
             WHERE user_id = ? AND is_active = true",
            [$userId]
        );
        
        // Consultar accesos
        $accesos = DB::select(
            "SELECT 
                u.id as user_id, 
                me.nombre, 
                me.url, 
                p.nombre as perfil_nombre,
                me.icono,
                me.padre_id,
                me.orden
             FROM seguridad.users u
             INNER JOIN seguridad.perfiles p ON p.id = u.perfil_id
             INNER JOIN seguridad.accesos acc ON acc.perfil_id = p.id AND acc.ejecutar = true
             INNER JOIN seguridad.menus me ON me.id = acc.menu_id
             WHERE u.id = ? AND me.url IS NOT NULL
             ORDER BY me.orden",
            [$userId]
        );
        
        return response()->json([
            'access_token' => $token,
            'token_type' => 'bearer',
            'expires_in' => config('jwt.ttl') * 60,
            'sesiones_activas' => $sesionesCount->total,
            'max_sesiones_permitidas' => $this->maxSesionesPorUsuario,
            'accesos' => $accesos,
            'user' => [
                'id' => $user->id,
                'name' => $user->name,
                'surname' => $user->surname,
                'full_name' => trim($user->surname . ' ' . $user->name),
                'login_user' => $user->login_user,
                'isreset' => $user->isreset,
                'email' => $user->email,
                'avatar' => $user->avatar,
                'perfil' => [
                    'id' => $user->perfil_id,
                    'nombre' => $user->perfil_nombre ?? null,
                    'activo' => $user->perfil_activo ?? null,
                    'inactividad' => $user->perfil_inactividad ?? null
                ]
            ]
        ]);
    }





















    public function me()
    {
        $user = DB::selectOne(
            "SELECT u.id, u.name, u.surname, u.login_user, u.email, u.avatar, u.perfil_id, u.isreset,
                    p.nombre as perfil_nombre
             FROM seguridad.users u
             LEFT JOIN seguridad.perfiles p ON p.id = u.perfil_id
             WHERE u.id = ?",
            [auth('api')->user()->id]
        );

        return response()->json($user);
    }













public function logout()
{
    try {
        // Intentar obtener el token del header
        $token = JWTAuth::parseToken();
        
        if (!$token) {
            return $this->errorResponse('Token no proporcionado', 400);
        }
        
        // Obtener el payload
        $payload = $token->getPayload();
        $jti = $payload->get('jti');
        $userId = $payload->get('sub'); // 'sub' normalmente es el user_id
        
        // Eliminar la sesión activa
        DB::delete(
            "DELETE FROM seguridad.sesiones_activas 
             WHERE user_id = ? AND token_id = ?",
            [$userId, $jti]
        );
        
        // Actualizar estado del usuario
        DB::update(
            "UPDATE seguridad.users SET islogin = false WHERE id = ?",
            [$userId]
        );
        
        // Invalidar el token
        auth('api')->logout();
        
        return $this->successResponse(null, 'Sesión cerrada exitosamente');
        
    } catch (\Tymon\JWTAuth\Exceptions\TokenInvalidException $e) {
        // Token ya inválido, pero igual limpiamos la BD si podemos
        \Log::warning('Intento de logout con token inválido', [
            'ip' => request()->ip()
        ]);
        return $this->successResponse(null, 'Sesión cerrada');
        
    } catch (\Tymon\JWTAuth\Exceptions\TokenExpiredException $e) {
        // Token expirado, limpiamos la sesión de la BD si podemos identificar al usuario
        \Log::warning('Intento de logout con token expirado', [
            'ip' => request()->ip()
        ]);
        return $this->successResponse(null, 'Sesión expirada');
        
    } catch (\Exception $e) {
        \Log::error('Error en logout: ' . $e->getMessage(), [
            'ip' => request()->ip()
        ]);
        return $this->errorResponse('Error al cerrar sesión', 500);
    }
}










  

    public function refresh()
    {
        $token = JWTAuth::parseToken()->refresh();
        $user = auth('api')->user();

        return $this->respondWithToken($token, $user);
    }






















}