<?php

namespace App\Models;

use Carbon\Carbon;
use Illuminate\Database\Eloquent\Model;

class UsersReporteExterno extends Model
{
    protected $table = 'users_reporteexterno';

    protected $fillable = [
        'users_id',
        'reporteexterno_id',
        'view_at',
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

    public function reporteexterno()
    {
        return $this->hasMany(ReporteExterno::class);
    }

    public function users()
    {
        return $this->hasMany(User::class);
    }    

}
