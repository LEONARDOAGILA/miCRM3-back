<?php

namespace App\Models\auth;

use Illuminate\Foundation\Auth\User as Authenticatable;
use Tymon\JWTAuth\Contracts\JWTSubject;

class User extends Authenticatable implements JWTSubject
{
    protected $table = 'seguridad.users';    
    protected $primaryKey = 'id';
    
    protected $hidden = [
        'password',
    ];

    
    // Deshabilitar timestamps porque usas triggers en la BD
    public $timestamps = false;
    
    
    // Método requerido por JWT
    public function getJWTIdentifier()
    {
        return $this->getKey();
    }    
    public function getJWTCustomClaims()
    {
        return [];
    }




}