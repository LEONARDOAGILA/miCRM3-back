<?php

// LPAA - CONTROL DE SESIONES ACTIVAS - ACTULIZA ULTIMA ACTIVIDAD

namespace App\Http\Middleware;

use Closure;
use App\Http\Controllers\auth\AuthController;

class UpdateSessionActivity
{
    public function handle($request, Closure $next)
    {
        $response = $next($request);
        
        // Actualizar actividad de la sesión
        app(AuthController::class)->updateActivity();
        
        return $response;
    }
}