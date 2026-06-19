<?php

namespace App\Models;

use Carbon\Carbon;
use Illuminate\Database\Eloquent\Model;

/**
 * @property int $id
 * @property string|null $nombre
 * @property int|null $activo
 * @property \Illuminate\Support\Carbon|null $created_at
 * @property \Illuminate\Support\Carbon|null $updated_at
 * 
 * @property-read \Illuminate\Database\Eloquent\Collection<int, \App\Models\Access> $access
 * @method static \Illuminate\Database\Eloquent\Builder|ReporteExterno newModelQuery()
 * @method static \Illuminate\Database\Eloquent\Builder|ReporteExterno newQuery()
 * @method static \Illuminate\Database\Eloquent\Builder|ReporteExterno query()
 * @method static \Illuminate\Database\Eloquent\Builder|ReporteExterno whereCreatedAt($value)
 * @method static \Illuminate\Database\Eloquent\Builder|ReporteExterno whereId($value)
 * @method static \Illuminate\Database\Eloquent\Builder|ReporteExterno whereInactivity($value)
 * @method static \Illuminate\Database\Eloquent\Builder|ReporteExterno whereIsactive($value)
 * @method static \Illuminate\Database\Eloquent\Builder|ReporteExterno whereName($value)
 * @method static \Illuminate\Database\Eloquent\Builder|ReporteExterno whereUpdatedAt($value)
 * @mixin \Eloquent
 */

class ReporteExterno extends Model
{
    protected $table = 'reporteexterno';

    protected $fillable = [
        'nombre',
        'descripcion',
        'url',
        'activo',
        'departamento_id',
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

    public function departamento()
    {
        return $this->belongsTo(Departamento::class);
    }

    // public function users()
    // {
    //     return $this->belongsToMany(User::class, 'users_reporteexterno', 'reporteexterno_id', 'users_id');
    // }

    public function users()
    {
        return $this->belongsToMany(User::class, 'users_reporteexterno', 'reporteexterno_id', 'users_id')
            ->withTimestamps()
            ->withPivot(['view_at']);
    }

}
