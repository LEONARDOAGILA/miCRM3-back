<?php

namespace App\Models\auth;

use Carbon\Carbon;
use Illuminate\Database\Eloquent\Model;
use App\Models\auth\Perfiles;


class Access extends Model
{
    protected $table = 'seguridad.accesos';

    protected $fillable = [
        'perfil_id',
        'menu_id',
        'listar',
        'ver',
        'crear',
        'editar',
        'eliminar',
        'reporte',
        'executar',
        'auditar',
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

    public function menu()
    {
        return $this->belongsTo(Menu::class);
    }

    public function perfil()
    {
        return $this->belongsTo(Perfiles::class);
    }

}
