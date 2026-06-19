<?php

namespace App\Models\auth;

use Carbon\Carbon;
use Illuminate\Database\Eloquent\Model;
use App\Models\auth\Access;
use App\Models\auth\User;


class Perfiles extends Model
{
    protected $table = 'seguridad.perfiles';

    protected $fillable = [
        'nombre',
        'inactividad',
        'activo',
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

    public function access()
    {
        return $this->hasMany(Access::class);
    }
    
    public function users()
    {
        return $this->hasMany(User::class);
    }    

}
