<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\SoftDeletes;
use Carbon\Carbon;

/**
 * Carpetas y archivos del administrador de archivos (tabla core.archivos).
 *
 * Árbol por `padre`: NULL = raíz; FK autorreferencial (fk_archivos_padre,
 * ON DELETE SET NULL) que garantiza que ningún nodo apunte a un padre
 * inexistente. Antes vivía en public.archivo con padre = 0 en la raíz.
 *
 * Borrado lógico (SoftDeletes sobre deleted_at): "eliminar" manda el
 * registro a la papelera, de donde se puede restaurar o borrar de verdad.
 * Todas las consultas normales (árbol, hijos) excluyen la papelera solas;
 * para verla se usa onlyTrashed() / withTrashed().
 *
 * Auditoría: la hace la base con los triggers de la tabla
 * (trg_archivos_audit → auditoria.logs_cambios; trigger_archivos_set_users
 * → created_by / updated_by). El controlador sólo tiene que dejar el
 * usuario en el contexto de la sesión (ver ArchivoController::contextoAuditoria).
 */
class Archivo extends Model{

    use HasFactory, SoftDeletes;

    protected $table = 'core.archivos';

    protected $casts = [
        'padre'         => 'integer',
        'escarpeta'     => 'boolean',
        'activo'        => 'boolean',
        'nueva_ventana' => 'boolean',
        'proteger_url'  => 'boolean',
        'publico'       => 'boolean',
        'es_eliminado'  => 'boolean',
    ];

    protected $fillable = [
        'padre' ,
        'orden' ,
        'nivel' ,
        'tipo' ,
        'nombre' ,
        'url' ,
        'descripcion' ,
        'modulo' ,
        'icono' ,
        'activo' ,
        'nueva_ventana' ,
        'proteger_url' ,
        'deleted_by' ,
        'publico' ,
        'tamano' ,
        'extension_archivo' ,
        'escarpeta' ,
        'color'
    ];

    public function setCreatedAtAttribute($value)
    {
        date_default_timezone_set("America/Guayaquil");
        $this->attributes["created_at"] = Carbon::now();
    }

    public function setUpdatedAtAttribute($value)
    {
        date_default_timezone_set("America/Guayaquil");
        $this->attributes["updated_at"] = Carbon::now();
    }

    /** Hijos directos, ordenados, cargando recursivamente los suyos. */
    public function children(){
        return $this->hasMany(Archivo::class, 'padre', 'id')
                    ->orderBy('orden')
                    ->orderBy('nombre')
                    ->with('children');
    }

    /** Carpeta que lo contiene (null en la raíz). */
    public function parent(){
        return $this->belongsTo(Archivo::class, 'padre', 'id');
    }

    /** Sólo las raíces (padre NULL). */
    public function scopeRaices($query){
        return $query->whereNull('padre');
    }

    /** Hijos directos de una carpeta; null o 0 = raíces. */
    public function scopeHijosDe($query, ?int $padre){
        return $padre ? $query->where('padre', $padre) : $query->whereNull('padre');
    }
}
