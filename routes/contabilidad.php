<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\contabilidad\PlanCuentaController;
use App\Http\Controllers\contabilidad\CuentaConfigController;

// ============================================================================
// MÓDULO CONTABILIDAD. Prefijo global: /contabilidad (RouteServiceProvider).
// Mismo esquema que routes/inventarios.php: un grupo por entidad con jwt.auth
// y usuario.activo.
// ============================================================================

// PLAN DE CUENTAS (árbol, sin tope de niveles)
Route::group([
    'prefix' => 'planCuenta', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allPlanCuentas',  [PlanCuentaController::class, 'allPlanCuentas']);   // el árbol entero: ?activos=1 para sólo activas
    Route::get('listPlanCuentas', [PlanCuentaController::class, 'listPlanCuentas']);  // lo mismo, para los combos
    Route::get('findByIdPlanCuenta/{id}', [PlanCuentaController::class, 'findByIdPlanCuenta']);
    Route::get('codigoSugerido',          [PlanCuentaController::class, 'codigoSugerido']);    // ?padre_id=
    Route::post('addPlanCuenta',          [PlanCuentaController::class, 'addPlanCuenta']);
    Route::post('editPlanCuenta/{id}',    [PlanCuentaController::class, 'editPlanCuenta']);
    Route::post('activarPlanCuenta/{id}', [PlanCuentaController::class, 'activarPlanCuenta']); // { activo? }; sin ella, alterna
    Route::post('moverPlanCuenta/{id}',   [PlanCuentaController::class, 'moverPlanCuenta']);   // { padre_id, antes_de }
    Route::delete('deletePlanCuenta/{id}',[PlanCuentaController::class, 'deletePlanCuenta']);  // a la papelera

    // Papelera de reciclaje (borrado lógico: deletePlanCuenta manda a la papelera)
    Route::get('papelera', [PlanCuentaController::class, 'papelera']);
    Route::post('restaurarPlanCuentas', [PlanCuentaController::class, 'restaurarPlanCuentas']); // { ids: [...] }
    Route::post('eliminarDefinitivo',   [PlanCuentaController::class, 'eliminarDefinitivo']);   // { ids: [...] }
    Route::delete('vaciarPapelera',     [PlanCuentaController::class, 'vaciarPapelera']);
});

// QUÉ CUENTA USA CADA COSA (de momento, las categorías de inventario)
Route::group([
    'prefix' => 'cuentaConfig', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('conceptos',  [CuentaConfigController::class, 'conceptos']);   // ?ambito=CATEGORIA
    Route::get('categorias', [CuentaConfigController::class, 'categorias']);  // el árbol con sus cuentas: ?transaccion=1
    Route::get('grupos',     [CuentaConfigController::class, 'grupos']);     // el árbol de grupos de clientes: ?activos=1

    // El id falta en el ámbito GLOBAL, que es el valor por omisión de todos
    Route::get('obtener/{ambito}/{id?}',  [CuentaConfigController::class, 'obtener']);
    Route::post('guardar/{ambito}/{id?}', [CuentaConfigController::class, 'guardar']); // { cuentas: {CONCEPTO: id|null} }
});
