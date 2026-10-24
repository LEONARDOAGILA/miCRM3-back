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

            // 4. El horario de acceso: ¿puede entrar AHORA?
            //
            // La decisión la toma la base (seguridad.fn_horarios_puede_entrar)
            // y no este middleware: ahí están las cuatro jornadas posibles de
            // cada día, las que cruzan la medianoche y el horario apagado, y
            // tenerlo en un solo sitio es lo que permite probarlo sin montar
            // una petición HTTP.
            $acceso = DB::selectOne(
                'SELECT seguridad.fn_horarios_puede_entrar(?::BIGINT) as r',
                [$user->chorario_id]
            );
            $acceso = json_decode($acceso->r ?? '{}', true);

            if (!($acceso['permitido'] ?? false)) {
                sistemaLog('warning', 'Acceso denegado por horario', [
                    'user_id'     => $user->id ?? null,
                    'login_user'  => $user->login_user ?? null,
                    'chorario_id' => $user->chorario_id,
                    'motivo'      => $acceso['motivo'] ?? 'DESCONOCIDO',
                    'dia'         => $acceso['dia'] ?? null,
                    'hora'        => now()->format('H:i:s'),
                    'ip'          => $request->ip(),
                ]);
                return response()->json([
                    'message' => 'Acceso denegado. ' . ($acceso['mensaje'] ?? 'Fuera del horario permitido.'),
                ], 401);
            }

            // Acceso permitido
            sistemaLog('info', 'Acceso permitido por middleware', [
                'user_id'    => $user->id ?? null,
                'login_user' => $user->login_user ?? null,
                'horario'    => $acceso['horario'] ?? null,
                'dia'        => $acceso['dia'] ?? null,
                'jornada'    => $acceso['jornada'] ?? null,
                'franja'     => ($acceso['desde'] ?? '?') . ' a ' . ($acceso['hasta'] ?? '?'),
                'hora'       => now()->format('H:i:s'),
                'ip'         => $request->ip(),
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