<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * Permiso de un usuario sobre un archivo o carpeta (seguridad.permisos_archivos).
 *
 * Una fila por (archivo, usuario). En carpetas `hereda` lo extiende al
 * subárbol; `denegar` gana sobre todo; `vigente_hasta` lo caduca. El
 * permiso EFECTIVO no se lee de aquí sino de seguridad.fn_permiso_archivo,
 * que suma propio + heredado y aplica propietario / admin / público.
 *
 * Auditoría y created_by/updated_by: triggers de la tabla (mismos que
 * core.archivos); el controlador deja el usuario en el contexto app.*.
 */
class PermisoArchivo extends Model
{
    protected $table = 'seguridad.permisos_archivos';

    /** Banderas que se pueden conceder. Mismo orden que en el front. */
    public const BANDERAS = ['ver', 'ejecutar', 'descargar', 'crear', 'editar', 'eliminar', 'administrar', 'restaurar'];

    protected $fillable = [
        'archivo_id', 'user_id',
        'ver', 'ejecutar', 'descargar', 'crear', 'editar', 'eliminar', 'administrar', 'restaurar',
        'hereda', 'denegar', 'vigente_hasta',
    ];

    protected $casts = [
        'ver' => 'boolean', 'ejecutar' => 'boolean', 'descargar' => 'boolean', 'crear' => 'boolean',
        'editar' => 'boolean', 'eliminar' => 'boolean', 'administrar' => 'boolean', 'restaurar' => 'boolean',
        'hereda' => 'boolean', 'denegar' => 'boolean',
        'vigente_hasta' => 'datetime',
    ];

    public function archivo()
    {
        return $this->belongsTo(Archivo::class, 'archivo_id');
    }

    public function usuario()
    {
        return $this->belongsTo(\App\Models\auth\User::class, 'user_id');
    }
}
