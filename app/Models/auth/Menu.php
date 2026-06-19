<?php

namespace App\Models\auth;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Database\Eloquent\Model;
use Carbon\Carbon;

class Menu extends Model
{
    use HasFactory;

    protected $table = 'seguridad.menus';

    protected $fillable = [
        'padre_id' ,
        'orden', 
        'nivel', 
        'nombre',  
        'url', 
        'descripcion', 
        'etiqueta',      
        'icono'        
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

    // Relación recursiva: un menú puede tener hijos
    public function children()
    {
        return $this->hasMany(Menu::class, 'padre_id', 'id')
                    ->orderBy('orden') // Ordenar hijos por el campo 'order'
                    ->with('children'); // Carga recursiva
    }

    public function access()
    {
        return $this->hasMany(Access::class);
    }

}
