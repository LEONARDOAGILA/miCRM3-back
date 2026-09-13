<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\SoftDeletes;
use Carbon\Carbon;

/**
 * Carpetas y archivos (reportes externos) del administrador de archivos.
 *
 * Borrado lógico (SoftDeletes sobre deleted_at): "eliminar" manda el
 * registro a la papelera, de donde se puede restaurar o borrar de verdad.
 * Todas las consultas normales (árbol, hijos) excluyen la papelera solas;
 * para verla se usa onlyTrashed() / withTrashed().
 */
class Archivo extends Model{

    use HasFactory, SoftDeletes;

    protected $table = 'archivo';

    protected $casts = [
        'escarpeta'    => 'boolean',
        'activo'       => 'boolean',
        'nueva_ventana' => 'boolean',
        'es_eliminado' => 'boolean',
    ];

    protected $fillable = [
        'id' ,
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
        'tamano' ,
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

    public function children(){
        return $this->hasMany(Archivo::class, 'padre', 'id')
                    ->orderBy('orden') 
                    ->with('children');
    }

}
