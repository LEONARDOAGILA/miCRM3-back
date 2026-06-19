<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Carbon\Carbon;

class Archivo extends Model{

    use HasFactory;

    protected $table = 'archivo';

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
