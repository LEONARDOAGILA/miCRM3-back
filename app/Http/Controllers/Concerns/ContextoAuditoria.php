<?php

namespace App\Http\Controllers\Concerns;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Deja el usuario, la ip y la petición en el contexto de la sesión de
 * PostgreSQL (app.*), que es lo que leen los triggers de auditoría:
 * fn_set_audit_users rellena created_by / updated_by y fn_auditar_cambios
 * graba en auditoria.logs_cambios quién hizo qué. Es la misma técnica que
 * usan las funciones seguridad.fn_usuarios_*, sólo que desde PHP, para los
 * controladores que trabajan con Eloquent (archivos, permisos de archivos).
 *
 * set_config(..., false) = para toda la sesión: Laravel abre una conexión
 * por petición, así que no se cuela en otra.
 */
trait ContextoAuditoria
{
    /** Login del usuario autenticado (para deleted_by y similares); null si no hay. */
    protected function loginActual(): ?string
    {
        $u = auth()->user();
        return $u ? ($u->login_user ?? $u->email ?? null) : null;
    }

    protected function contextoAuditoria(Request $request, string $modulo = 'core.archivos'): void
    {
        $usuario = auth()->user();
        $login   = $usuario->login_user ?? $usuario->email ?? null;
        $nombre  = $usuario ? trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) : null;

        DB::statement(
            "SELECT set_config('app.usuario_id', ?, false),
                    set_config('app.usuario_login', ?, false),
                    set_config('app.usuario_nombre', ?, false),
                    set_config('app.ip_address', ?, false),
                    set_config('app.user_agent', ?, false),
                    set_config('app.request_id', ?, false),
                    set_config('app.modulo', ?, false)",
            [
                (string) ($usuario->id ?? ''),
                (string) ($login ?: ''),
                (string) ($nombre ?: ''),
                (string) ($request->ip() ?? ''),
                (string) ($request->userAgent() ?? ''),
                (string) Str::uuid(),
                $modulo,
            ]
        );
    }
}
