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
    /** Memoria de esAdminDeArchivos() dentro de la misma petición. */
    private ?bool $adminDeArchivos = null;

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

    /**
     * Administrador del gestor de archivos: la función SQL les da todo.
     *
     * Manda `es_administrador` del GRUPO, la misma señal que usa
     * seguridad.fn_permiso_archivo y que el resto del CRM (la lista de
     * clientes, la agenda, el tablero, la visibilidad de datos).
     *
     * Antes mandaba users.type_user IN (1, 2), de cuando el gestor nació y
     * todavía no había grupos. Eso dejaba fuera a quien es administrador por
     * su grupo con otro type_user —SISTEMAS-GYE, por ejemplo— y además se
     * quedaba atrás en cuanto se le cambiaba de grupo a alguien.
     *
     * Se resuelve una sola vez por petición: lo preguntan el árbol, la
     * papelera y cada comprobación de nodo.
     */
    protected function esAdminDeArchivos(): bool
    {
        if ($this->adminDeArchivos !== null) { return $this->adminDeArchivos; }

        $userId = auth()->id();
        if (!$userId) { return false; }   // sin cachear: aún puede no haber sesión

        $fila = DB::selectOne(
            'SELECT COALESCE(g.es_administrador, false) AS admin
               FROM seguridad.users u
               LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
              WHERE u.id = ?',
            [(int) $userId]
        );

        return $this->adminDeArchivos = (bool) ($fila->admin ?? false);
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
