<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\config\ArchivoController;

use App\Http\Controllers\config\DepartamentoController;





// ARCHIVOS
Route::group([
    // 'prefix' => 'archivo',
    'prefix' => 'archivo', 'middleware' => ['jwt.auth', 'usuario.activo']

], function () {
    Route::get('allArchivos', [ArchivoController::class, 'allArchivos']);
    Route::get('getArchivoTree', [ArchivoController::class, 'getArchivoTree']);
    Route::post('addArchivo', [ArchivoController::class, 'addArchivo']);


    // Route::get('send_email', [EmailController::class, 'send_email']);
    // Route::get('findByIdMenu/{id}', [MenuController::class, 'findByIdMenu']);

    // Route::post('editMenu/{id}', [MenuController::class, 'editMenu']);
    // Route::delete('deleteMenu/{id}', [MenuController::class, 'deleteMenu']);
});


// DEPARTAMENTOS
Route::group([
    //'prefix' => 'departamento',
    'prefix' => 'departamento', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allDepartamentos', [DepartamentoController::class, 'allDepartamentos']);
    Route::get('listDepartamentos', [DepartamentoController::class, 'listDepartamentos']);
    Route::get('findByIdDepartamento/{id}', [DepartamentoController::class, 'findByIdDepartamento']);

    Route::post('addDepartamento', [DepartamentoController::class, 'addDepartamento']);
    Route::post('clonDepartamento', [DepartamentoController::class, 'clonDepartamento']);
    Route::post('editDepartamento/{id}', [DepartamentoController::class, 'editDepartamento']);
    Route::delete('deleteDepartamento/{id}', [DepartamentoController::class, 'deleteDepartamento']);
});



