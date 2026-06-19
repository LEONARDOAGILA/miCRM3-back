<?php

namespace App\Models\auth;

use Carbon\Carbon;
use Illuminate\Database\Eloquent\Model;


class Auditoria extends Model
{
    protected $table = 'auditoria.auditoria';

    protected $fillable = [
    'tabla_afectada',
    'id_registro_afectado',
    'tipo_operacion',
    'datos_anteriores',
    'datos_nuevos',
    'fecha_operacion',
    'usuario_operador',
    'ip_address',
    'user_agent',
    'request_id',
    'modulo',
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

}
