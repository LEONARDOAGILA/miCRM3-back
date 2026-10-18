<?php

namespace App\Http\Controllers\Concerns;

use Illuminate\Support\Facades\DB;

/**
 * Comprueba en el SERVIDOR un permiso del perfil sobre una pantalla.
 *
 * POR QUÉ EXISTE ESTO. Esconder un botón no es un permiso: la llamada sigue
 * ahí y se puede hacer a mano. Mientras el front decide qué pinta, el back
 * tiene que decidir qué deja hacer, y eso vale sobre todo para lo que no
 * tiene vuelta atrás: eliminar definitivamente y vaciar la papelera.
 *
 *     if ($no = $this->exigirPermiso('allMarcas', 'vaciar',
 *                                    'No tiene permiso para borrar definitivamente marcas')) {
 *         return $no;              // 403 ya armado
 *     }
 *
 * EL PROGRAMA SE BUSCA POR LA URL DEL MENÚ, no por su id: el id del menú no
 * es el mismo en todas las bases (lo sabíamos ya por puedeAdministrarPerfiles,
 * que hace esta misma consulta a mano para los perfiles).
 *
 * Quien está en un grupo marcado como administrador pasa siempre: es la misma
 * regla que usa el resto de la aplicación.
 */
trait AccesoDeLaPantalla
{
    /**
     * ¿El usuario de la petición tiene `$permiso` en la pantalla `$pantalla`?
     *
     * @param string $pantalla El último tramo de la url del menú: 'allMarcas'.
     * @param string $permiso  Una columna de seguridad.accesos: 'vaciar'.
     */
    protected function puedeEnPantalla(string $pantalla, string $permiso): bool
    {
        // El nombre de la columna acaba dentro de la consulta: lista blanca,
        // no confianza. Es la misma razón que en los filtros de columna.
        $permitidos = ['ver', 'crear', 'editar', 'eliminar', 'listar',
                       'reporte', 'ejecutar', 'auditar', 'papelera', 'vaciar'];
        if (!in_array($permiso, $permitidos, true)) { return false; }

        $u = auth('api')->user();
        if (!$u) { return false; }

        $fila = DB::selectOne(
            "SELECT COALESCE(g.es_administrador, false) AS admin,
                    COALESCE((SELECT a.{$permiso}
                                FROM seguridad.accesos a
                                JOIN seguridad.menus m ON m.id = a.menu_id
                               WHERE a.perfil_id = u.perfil_id
                                 AND UPPER(SPLIT_PART(m.url, '/', 2)) = UPPER(?)
                               LIMIT 1), false) AS tiene
               FROM seguridad.users u
               LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
              WHERE u.id = ?",
            [$pantalla, (int) $u->id]
        );

        return (bool) (($fila->admin ?? false) || ($fila->tiene ?? false));
    }

    /**
     * Devuelve la respuesta 403 si NO tiene el permiso, y null si lo tiene.
     *
     * Se devuelve en lugar de lanzar para que cada controlador lo ponga en su
     * try/catch como una salida más, sin cambiar cómo responde.
     */
    protected function exigirPermiso(string $pantalla, string $permiso, string $mensaje)
    {
        if ($this->puedeEnPantalla($pantalla, $permiso)) { return null; }

        sistemaLog('warning', 'Intento de usar algo sin el permiso necesario', [
            'pantalla' => $pantalla,
            'permiso'  => $permiso,
            'usuario'  => auth('api')->user()->login_user ?? null,
            'ip'       => request()->ip(),
        ]);

        return $this->errorResponse($mensaje, 403);
    }
}
