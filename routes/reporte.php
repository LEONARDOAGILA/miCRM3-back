<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\reporte\ReporteExternoController;

// reportes externos
Route::group([
    'prefix' => 'reporteexterno',
], function () {
    Route::get('allReportesExternos', [ReporteExternoController::class, 'allReportesExternos']);
    Route::get('listReportesExternos', [ReporteExternoController::class, 'listReporteExterno']);
    Route::get('findByIdReporteExterno/{id}', [ReporteExternoController::class, 'findByIdReporteExterno']);
    Route::post('addReporteExterno', [ReporteExternoController::class, 'addReporteExterno']);
    Route::post('clonReporteExterno', [ReporteExternoController::class, 'clonReporteExterno']);
    Route::post('editReporteExterno/{id}', [ReporteExternoController::class, 'editReporteExterno']);
    Route::delete('deleteReporteExterno/{id}', [ReporteExternoController::class, 'deleteReporteExterno']);


    Route::get('listUserReportesExternos', [ReporteExternoController::class, 'listUserReportesExternos']);
    Route::get('listUsersReportesExternosSelected/{id}', [ReporteExternoController::class, 'listUsersReportesExternosSelected']);
    Route::get('listUsersReportesExternosPendientexSeleccionar/{id}', [ReporteExternoController::class, 'listUsersReportesExternosPendientexSeleccionar']);
    Route::post('saveUsersReportesExternos', [ReporteExternoController::class, 'saveUsersReportesExternos']);
    Route::post('updateUsersReportesExternos/{id}', [ReporteExternoController::class, 'updateUsersReportesExternos']);



});

