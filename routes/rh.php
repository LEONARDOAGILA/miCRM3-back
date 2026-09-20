<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\rh\CargoController;
use App\Http\Controllers\rh\DepartamentoController;
use App\Http\Controllers\rh\EmpleadoController;
use App\Http\Controllers\rh\MarcacionController;
use App\Http\Controllers\rh\RostroController;

// ============================================================================
// MÓDULO RH (recursos humanos). Prefijo global: /rh (RouteServiceProvider).
// Mismo esquema que routes/auth.php: un grupo por entidad con jwt.auth y
// usuario.activo.
// ============================================================================

// CARGOS
Route::group([
    'prefix' => 'cargo', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allCargos', [CargoController::class, 'allCargos']);            // paginado: ?page&per_page&search
    Route::get('listCargos', [CargoController::class, 'listCargos']);          // lista simple: ?activos=0 para incluir inactivos
    Route::get('findByIdCargo/{id}', [CargoController::class, 'findByIdCargo']);
    Route::post('addCargo', [CargoController::class, 'addCargo']);
    Route::post('editCargo/{id}', [CargoController::class, 'editCargo']);
    Route::delete('deleteCargo/{id}', [CargoController::class, 'deleteCargo']);
});

// DEPARTAMENTOS
Route::group([
    'prefix' => 'departamento', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allDepartamentos', [DepartamentoController::class, 'allDepartamentos']);          // paginado: ?page&per_page&search
    Route::get('listDepartamentos', [DepartamentoController::class, 'listDepartamentos']);        // lista simple: ?activos=0 para incluir inactivos
    Route::get('listResponsables', [DepartamentoController::class, 'listResponsables']);          // empleados activos (combo Responsable)
    Route::get('findByIdDepartamento/{id}', [DepartamentoController::class, 'findByIdDepartamento']);
    Route::post('addDepartamento', [DepartamentoController::class, 'addDepartamento']);
    Route::post('editDepartamento/{id}', [DepartamentoController::class, 'editDepartamento']);
    Route::delete('deleteDepartamento/{id}', [DepartamentoController::class, 'deleteDepartamento']);
});

// EMPLEADOS
Route::group([
    'prefix' => 'empleado',
], function () {
    Route::get('allEmpleados', [EmpleadoController::class, 'allEmpleados'])->middleware(['jwt.auth', 'usuario.activo']);        // paginado
    Route::get('listEmpleados', [EmpleadoController::class, 'listEmpleados'])->middleware(['jwt.auth', 'usuario.activo']);      // lista simple: ?activos=0
    Route::get('findByIdEmpleado/{id}', [EmpleadoController::class, 'findByIdEmpleado'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('addEmpleado', [EmpleadoController::class, 'addEmpleado'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('editEmpleado/{id}', [EmpleadoController::class, 'editEmpleado'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::delete('deleteEmpleado/{id}', [EmpleadoController::class, 'deleteEmpleado'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('addImagen', [EmpleadoController::class, 'addImagen'])->middleware(['jwt.auth', 'usuario.activo']);            // { EmpleadoId, imagen_file }
    Route::get('listContactos/{id}', [EmpleadoController::class, 'listContactos'])->middleware(['jwt.auth', 'usuario.activo']);        // contactos de emergencia
    Route::post('guardarContactos/{id}', [EmpleadoController::class, 'guardarContactos'])->middleware(['jwt.auth', 'usuario.activo']); // { contactos: [...] } sincroniza
    // Pública (la usa <img src>), como getImagenUsuario
    Route::get('getImagenEmpleado/{id}', [EmpleadoController::class, 'getImagenEmpleado']);
});

// MARCACIONES (entradas / salidas)
Route::group([
    'prefix' => 'marcacion',
], function () {
    Route::get('allMarcaciones', [MarcacionController::class, 'allMarcaciones'])->middleware(['jwt.auth', 'usuario.activo']);        // ?page&per_page&search&desde&hasta&empleado_id&tipo&origen
    Route::get('findByIdMarcacion/{id}', [MarcacionController::class, 'findByIdMarcacion'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::get('resumen', [MarcacionController::class, 'resumen'])->middleware(['jwt.auth', 'usuario.activo']);                      // horas por empleado y día
    Route::post('registrar', [MarcacionController::class, 'registrar'])->middleware(['jwt.auth', 'usuario.activo']);                  // kiosco facial
    Route::post('addMarcacion', [MarcacionController::class, 'addMarcacion'])->middleware(['jwt.auth', 'usuario.activo']);            // alta manual
    Route::post('editMarcacion/{id}', [MarcacionController::class, 'editMarcacion'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::delete('deleteMarcacion/{id}', [MarcacionController::class, 'deleteMarcacion'])->middleware(['jwt.auth', 'usuario.activo']);
    // Pública (la usa <img src>)
    Route::get('getImagenMarcacion/{id}', [MarcacionController::class, 'getImagenMarcacion']);
});

// ROSTROS (plantillas faciales de los empleados)
Route::group([
    'prefix' => 'rostro', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allRostros', [RostroController::class, 'allRostros']);                                   // ?empleado_id
    Route::post('addRostro', [RostroController::class, 'addRostro']);                                    // { empleado_id, descriptores: [[128]…], origen }
    Route::delete('deleteRostro/{id}', [RostroController::class, 'deleteRostro']);
    Route::delete('deleteRostrosEmpleado/{empleadoId}', [RostroController::class, 'deleteRostrosEmpleado']);
});
