<?php

namespace App\Http\Controllers\Concerns;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

/**
 * Permiso efectivo de un usuario sobre un archivo y registro de accesos.
 *
 * La regla vive en la base (seguridad.fn_permiso_archivo): aquí sólo se
 * consulta. La usan ArchivoController (autorizar descargas / apertura) y
 * PermisoArchivoController (Mis archivos, administrar permisos).
 */
trait PermisosDeArchivo
{
    /**
     * Banderas efectivas del usuario sobre el archivo:
     * { ver, ejecutar, descargar, crear, editar, eliminar, administrar, origen }.
     */
    protected function permisoEfectivo(int $userId, int $archivoId, bool $enPapelera = false): object
    {
        $fila = DB::selectOne('SELECT * FROM seguridad.fn_permiso_archivo(?, ?, ?)', [$userId, $archivoId, $enPapelera]);
        return $fila ?? (object) [
            'ver' => false, 'ejecutar' => false, 'descargar' => false, 'crear' => false,
            'editar' => false, 'eliminar' => false, 'administrar' => false, 'restaurar' => false, 'origen' => 'NINGUNO',
        ];
    }

    /** true si el usuario autenticado tiene la bandera sobre el archivo. */
    protected function puede(string $bandera, int $archivoId): bool
    {
        $userId = auth()->id();
        if (!$userId) { return false; }
        $p = $this->permisoEfectivo((int) $userId, $archivoId);
        return (bool) ($p->{$bandera} ?? false);
    }

    /**
     * Permiso para crear dentro de $padre (null = raíz). En la raíz sólo
     * los administradores; dentro de una carpeta, quien tenga `crear`.
     */
    protected function puedeCrearEn(?int $padreId): bool
    {
        if ($padreId === null) { return $this->esAdminDeArchivos(); }
        return $this->puede('crear', $padreId);
    }

    /**
     * Mover $archivoId a $destinoId (null = raíz): hace falta `editar` sobre
     * lo que se mueve y `crear` en el destino.
     */
    protected function puedeMoverA(int $archivoId, ?int $destinoId): bool
    {
        return $this->puede('editar', $archivoId) && $this->puedeCrearEn($destinoId);
    }

    /** Puede restaurar un elemento que está en la papelera (admin, propietario o `restaurar`). */
    protected function puedeRestaurar(int $archivoId): bool
    {
        $userId = auth()->id();
        if (!$userId) { return false; }
        return (bool) $this->permisoEfectivo((int) $userId, $archivoId, true)->restaurar;
    }

    /** Super usuario (1) o administrador (2): la función SQL les da todo. */
    protected function esAdminDeArchivos(): bool
    {
        return in_array((int) (auth()->user()->type_user ?? 0), [1, 2], true);
    }

    /**
     * Deja rastro en core.archivos_accesos (EJECUTAR / DESCARGAR). Nunca
     * corta la operación: si falla el log, se escribe en el log de Laravel.
     */
    protected function registrarAcceso(Request $request, int $archivoId, string $accion): void
    {
        try {
            $usuario = auth()->user();
            DB::table('core.archivos_accesos')->insert([
                'archivo_id'    => $archivoId,
                'user_id'       => $usuario->id ?? null,
                'usuario_login' => $usuario->login_user ?? $usuario->email ?? null,
                'accion'        => $accion,
                'ip_address'    => $request->ip(),
                'user_agent'    => substr((string) $request->userAgent(), 0, 1000),
                'created_at'    => now(),
            ]);
        } catch (\Throwable $e) {
            \Log::warning('No se pudo registrar el acceso al archivo', ['archivo' => $archivoId, 'error' => $e->getMessage()]);
        }
    }
}
