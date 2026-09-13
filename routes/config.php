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
    Route::get('findByIdArchivo/{id}', [ArchivoController::class, 'findByIdArchivo']);
    Route::get('descargarArchivo/{id}', [ArchivoController::class, 'descargarArchivo']);   // fichero subido, como adjunto (descarga)
    Route::post('addArchivo', [ArchivoController::class, 'addArchivo']);
    Route::post('subirArchivo', [ArchivoController::class, 'subirArchivo']);   // fichero físico, antes de crear el registro
    Route::post('editArchivo/{id}', [ArchivoController::class, 'editArchivo']);
    Route::delete('deleteArchivo/{id}', [ArchivoController::class, 'deleteArchivo']);   // a la papelera

    // Papelera de reciclaje (borrado lógico)
    Route::get('papelera', [ArchivoController::class, 'papelera']);
    Route::post('restaurarArchivo/{id}', [ArchivoController::class, 'restaurarArchivo']);
    Route::delete('eliminarDefinitivo/{id}', [ArchivoController::class, 'eliminarDefinitivo']);
    Route::delete('vaciarPapelera', [ArchivoController::class, 'vaciarPapelera']);
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



