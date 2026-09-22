<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\config\ArchivoController;
use App\Http\Controllers\config\PermisoArchivoController;

use App\Http\Controllers\config\DepartamentoController;
use App\Http\Controllers\config\BoletinController;





// ARCHIVOS
Route::group([
    // 'prefix' => 'archivo',
    'prefix' => 'archivo', 'middleware' => ['jwt.auth', 'usuario.activo']

], function () {
    Route::get('allArchivos', [ArchivoController::class, 'allArchivos']);
    Route::get('getArchivoTree', [ArchivoController::class, 'getArchivoTree']);
    Route::get('findByIdArchivo/{id}', [ArchivoController::class, 'findByIdArchivo']);
    Route::get('descargarArchivo/{id}', [ArchivoController::class, 'descargarArchivo']);   // fichero subido, como adjunto (descarga)
    Route::post('descargarZip', [ArchivoController::class, 'descargarZip']);   // uno o varios (carpetas incluidas) en un .zip { ids[] }
    Route::post('addArchivo', [ArchivoController::class, 'addArchivo']);
    Route::post('subirArchivo', [ArchivoController::class, 'subirArchivo']);   // fichero físico, antes de crear el registro
    Route::post('editArchivo/{id}', [ArchivoController::class, 'editArchivo']);
    Route::post('moverArchivo/{id}', [ArchivoController::class, 'moverArchivo']);   // a otra carpeta (o a la raíz)
    Route::post('moverArchivos', [ArchivoController::class, 'moverArchivos']);       // varios a la vez { ids[], padre }
    Route::post('reordenarArchivos', [ArchivoController::class, 'reordenarArchivos']); // orden manual entre hermanos { ids[], antes_de, padre }
    Route::post('eliminarArchivos', [ArchivoController::class, 'eliminarArchivos']); // varios a la papelera { ids[] }
    Route::delete('deleteArchivo/{id}', [ArchivoController::class, 'deleteArchivo']);   // a la papelera

    // Permisos por archivo (por usuario) — PermisoArchivoController
    Route::get('permisosArchivo/{id}', [PermisoArchivoController::class, 'permisosDe']);              // filas del nodo + heredadas
    Route::post('permisosArchivo/{id}', [PermisoArchivoController::class, 'guardar']);                // crea/actualiza la fila de un usuario
    Route::delete('permisosArchivo/{id}/{userId}', [PermisoArchivoController::class, 'quitar']);
    Route::get('usuariosParaPermisos', [PermisoArchivoController::class, 'usuarios']);               // selector de usuarios ?search=
    Route::get('accesosArchivo/{id}', [PermisoArchivoController::class, 'accesos']);                 // quién abrió / descargó
    Route::post('transferirPropietario/{id}', [PermisoArchivoController::class, 'transferirPropietario']); // ceder la propiedad { user_id, incluir_contenido, conservar_acceso }
    // Usuario final
    Route::get('misArchivos', [PermisoArchivoController::class, 'misArchivos']);                     // árbol con lo que puede ver
    Route::get('miPermisoArchivo/{id}', [PermisoArchivoController::class, 'miPermiso']);
    Route::post('abrirArchivo/{id}', [PermisoArchivoController::class, 'abrir']);                    // autoriza ejecutar + registra acceso

    // Papelera de reciclaje (borrado lógico)
    Route::get('almacenamiento', [ArchivoController::class, 'almacenamiento']);   // espacio usado por las subidas + disco
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





// BOLETINES (avisos con imágenes que se muestran al entrar al sistema)
Route::group([
    'prefix' => 'boletin', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allBoletines', [BoletinController::class, 'allBoletines']);
    Route::get('findByIdBoletin/{id}', [BoletinController::class, 'findByIdBoletin']);
    Route::get('destinatarios/{id}', [BoletinController::class, 'destinatarios']);   // quién lo verá
    Route::get('papelera', [BoletinController::class, 'papelera']);

    Route::post('addBoletin', [BoletinController::class, 'addBoletin']);
    Route::post('editBoletin/{id}', [BoletinController::class, 'editBoletin']);
    Route::post('restaurarBoletin/{id}', [BoletinController::class, 'restaurarBoletin']);
    Route::delete('deleteBoletin/{id}', [BoletinController::class, 'deleteBoletin']);
    Route::delete('eliminarDefinitivo/{id}', [BoletinController::class, 'eliminarDefinitivo']);
    Route::delete('vaciarPapelera', [BoletinController::class, 'vaciarPapelera']);

    Route::post('subirImagen', [BoletinController::class, 'subirImagen']);           // fichero -> nombre guardado
    Route::get('imagen/{imagenId}', [BoletinController::class, 'imagen']);           // con marca de agua del que la ve

    // Lo que ve el usuario al iniciar sesión
    Route::get('misBoletines', [BoletinController::class, 'misBoletines']);
    Route::post('marcarVisto/{id}', [BoletinController::class, 'marcarVisto']);
});
