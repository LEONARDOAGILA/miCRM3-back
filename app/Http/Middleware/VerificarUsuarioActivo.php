<?php

namespace App\Http\Middleware;

use Tymon\JWTAuth\Facades\JWTAuth;
use Illuminate\Http\Request;
use Closure;
use Illuminate\Support\Facades\DB;

class VerificarUsuarioActivo
{
    public function handle(Request $request, Closure $next)
    {
        try {
            // 1. Obtener el usuario desde el token JWT
            $user = JWTAuth::parseToken()->authenticate();

            // 2. Validar si el usuario está activo
            if (!$user || !$user->isactive) {
                sistemaLog('warning', 'Acceso denegado: Usuario inactivo', [
                    'user_id' => $user->id ?? null,
                    'login_user' => $user->login_user ?? null,
                    'ip' => $request->ip()
                ]);
                return response()->json([
                    'message' => 'El usuario está inactivo. Acceso denegado.',
                ], 401);
            }

            // 3. Validar si el usuario tiene un horario asignado
            if (!$user->chorario_id) {
                sistemaLog('warning', 'Acceso denegado: Usuario sin horario asignado', [
                    'user_id' => $user->id ?? null,
                    'login_user' => $user->login_user ?? null,
                    'ip' => $request->ip()
                ]);
                return response()->json([
                    'message' => 'Acceso denegado. Este usuario no tiene un horario asignado.',
                ], 401);
            }

            // 4. Obtener el horario completo con sus días (SQL directo)
            $horario = DB::selectOne("
                SELECT 
                    c.id,
                    c.nombre,
                    c.activo as estado
                FROM seguridad.chorarios c
                WHERE c.id = ? AND c.activo = true
            ", [$user->chorario_id]);

            if (!$horario) {
                sistemaLog('warning', 'Acceso denegado: Horario inactivo', [
                    'user_id' => $user->id,
                    'login_user' => $user->login_user,
                    'chorario_id' => $user->chorario_id,
                    'ip' => $request->ip()
                ]);
                return response()->json([
                    'message' => 'Acceso denegado. El horario asignado está inactivo.',
                ], 401);
            }

            // 5. Obtener día actual (1 = lunes, 2 = martes, ..., 7 = domingo)
            $diaActual = now()->dayOfWeek;
            $diaActualSQL = $diaActual == 0 ? 7 : $diaActual;

            // 6. Buscar si existe horario activo para el día actual
            $diaHorario = DB::selectOne("
                SELECT 
                    id,
                    dia,
                    hora_inicio,
                    hora_fin,
                    activo as estado
                FROM seguridad.dhorarios
                WHERE chorario_id = ? AND dia = ? AND activo = true
            ", [$user->chorario_id, $diaActualSQL]);

            if (!$diaHorario) {
                sistemaLog('warning', 'Acceso denegado: Sin acceso en este día', [
                    'user_id' => $user->id,
                    'login_user' => $user->login_user,
                    'dia' => $diaActualSQL,
                    'ip' => $request->ip()
                ]);
                return response()->json([
                    'message' => 'Acceso denegado. No tiene acceso permitido hoy.',
                ], 401);
            }

            // 7. Validar si la hora actual está dentro del rango permitido
            $horaActual = now()->format('H:i:s');

            if ($horaActual < $diaHorario->hora_inicio || $horaActual > $diaHorario->hora_fin) {
                sistemaLog('warning', 'Acceso denegado: Horario fuera de rango', [
                    'user_id' => $user->id,
                    'login_user' => $user->login_user,
                    'hora_actual' => $horaActual,
                    'hora_inicio' => $diaHorario->hora_inicio,
                    'hora_fin' => $diaHorario->hora_fin,
                    'ip' => $request->ip()
                ]);
                return response()->json([
                    'message' => "Acceso denegado. Horario permitido hoy: {$diaHorario->hora_inicio} a {$diaHorario->hora_fin}",
                ], 401);
            }

            // Acceso permitido
            sistemaLog('info', 'Acceso permitido por middleware', [
                'user_id' => $user->id,
                'login_user' => $user->login_user,
                'horario' => $horario->nombre,
                'dia' => $diaActualSQL,
                'hora' => $horaActual,
                'ip' => $request->ip()
            ]);

            return $next($request);
            
        } catch (\Exception $e) {
            sistemaLog('error', 'Error en middleware VerificarUsuarioActivo', [
                'message' => $e->getMessage(),
                'line' => $e->getLine(),
                'ip' => $request->ip()
            ]);
            
            return response()->json([
                'message' => 'Error de autenticación',
                'error' => $e->getMessage()
            ], 401);
        }
    }
}