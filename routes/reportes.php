<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\reportes\VentaDemoController;

// ============================================================================
// MÓDULO REPORTES. Prefijo global: /reportes (RouteServiceProvider).
//
// Tableros: todo lo de aquí LEE y no escribe nada, así que no hay POST ni
// DELETE. Mismo esquema que los demás módulos: un grupo por entidad con
// jwt.auth y usuario.activo.
//
// El prefijo nuevo necesita además su entrada en config/cors.php, su grupo en
// Kernel.php y su limitador en RouteServiceProvider; si falta alguna, Angular
// sólo dice «Error en el servidor».
// ============================================================================

// VENTAS DEMO (el tablero de ejemplo)
Route::group([
    'prefix' => 'ventaDemo', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('opciones', [VentaDemoController::class, 'opciones']);   // dimensiones, medidas y valores
    Route::get('pivote',   [VentaDemoController::class, 'pivote']);     // ?filas&columnas&medida&agregacion&filtros&orden&limite
    Route::get('detalle',  [VentaDemoController::class, 'detalle']);    // ?page&per_page&filtros&ordenar&sentido
});
