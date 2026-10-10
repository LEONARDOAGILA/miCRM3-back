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

            // 2. Validar si el usuario está activo (y no en la papelera de reciclaje)
            if (!$user || !$user->isactive || $user->deleted_at) {
                sistemaLog('warning', 'Acceso denegado: Usuario inactivo', [
                    'user_id' => $user->id ?? null,
                    'login_user' => $user->login_user ?? null,
                    'ip' => $request->ip()
                ]);
                return response()->json([
                    'message' => 'El usuario está inactivo. Acceso denegado.',
                ], 401);
            }

            // 3. Validar que su TIPO de usuario esté vigente
            //
            // El tipo (del sistema, web, freelance, temporal…) puede tener
            // fecha de inicio y de fin; mientras no esté vigente, el usuario no
            // entra. La regla y el texto del aviso viven en la base
            // (seguridad.fn_tipo_usuario_vigente / fn_tipo_usuario_motivo), que
            // es donde se pueden cambiar sin tocar código.
            //
            // Sin tipo (type_user NULL) no se bloquea a nadie: la vigencia es
            // una restricción del tipo, y no tenerlo no es una razón para
            // dejar a alguien fuera.
            $vigencia = DB::selectOne(
                'SELECT seguridad.fn_tipo_usuario_vigente(?::INTEGER) AS vigente,
                        seguridad.fn_tipo_usuario_motivo(?::INTEGER)  AS motivo',
                [$user->type_user, $user->type_user]
            );

            if ($vigencia && !$vigencia->vigente) {
                sistemaLog('warning', 'Acceso denegado: tipo de usuario no vigente', [
                    'user_id'    => $user->id,
                    'login_user' => $user->login_user,
                    'type_user'  => $user->type_user,
                    'motivo'     => $vigencia->motivo,
                    'ip'         => $request->ip()
                ]);
                return response()->json([
                    'message' => $vigencia->motivo ?: 'Acceso denegado. Su tipo de usuario no está vigente.',
                ], 401);
            }

            // 4. Validar si el usuario tiene un horario asignado
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

            // 5. Obtener el horario completo con sus días (SQL directo)
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

            // 6. Obtener día actual (1 = lunes, 2 = martes, ..., 7 = domingo)
            $diaActual = now()->dayOfWeek;
            $diaActualSQL = $diaActual == 0 ? 7 : $diaActual;

            // 7. Buscar si existe horario activo para el día actual
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

            // 8. Validar si la hora actual está dentro del rango permitido
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