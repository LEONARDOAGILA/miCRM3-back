<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\core\SucursalController;
use App\Http\Controllers\core\PuntoVentaController;

// ============================================================================
// MODULO CORE. Prefijo global: /core (RouteServiceProvider).
//
// Aqui vive LA ESTRUCTURA DE LA EMPRESA: las sucursales y las cajas de cada
// una. No esta en /ventas porque no es de ventas: de las sucursales cuelgan
// tambien los empleados (rh), las bodegas (inventarios) y las cuentas
// contables, y tenerlas en el modulo de ventas obligaba a que recursos
// humanos dependiera de el.
//
// Mismo esquema que los demas: un grupo por entidad con jwt.auth y
// usuario.activo, salvo las rutas que consume un <img src>, que son publicas.
// ============================================================================
// La imagen de una sucursal va FUERA del grupo: la pide un <img src>, que no
// manda la cabecera Authorization. El control de acceso es el id: no lista
// nada y no dice de quién es lo que sirve, igual que getLogo de las marcas.
Route::get('sucursal/getFoto/{id}/{campo}', [SucursalController::class, 'getFoto']);

// SUCURSALES (con su perímetro en el mapa)
Route::group([
    'prefix' => 'sucursal', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allSucursales',  [SucursalController::class, 'allSucursales']);    // ?page&per_page&search&filtros
    Route::get('listSucursales', [SucursalController::class, 'listSucursales']);   // lista simple: ?activas=0
    Route::get('findByIdSucursal/{id}', [SucursalController::class, 'findByIdSucursal']);
    Route::post('addSucursal',          [SucursalController::class, 'addSucursal']);
    Route::post('editSucursal/{id}',    [SucursalController::class, 'editSucursal']);
    Route::post('activarSucursal/{id}', [SucursalController::class, 'activarSucursal']);  // { activo? }; sin ella, alterna
    Route::delete('deleteSucursal/{id}',[SucursalController::class, 'deleteSucursal']);   // a la papelera
    // ¿Ese punto cae dentro? Lo usa la pantalla para probar el dibujo
    Route::post('probarPunto/{id}',     [SucursalController::class, 'probarPunto']);      // { latitud, longitud }

    // Las imágenes: la foto del local y la captura del mapa. Se suben DESPUÉS
    // de guardar, porque el fichero necesita el id.
    Route::post('addFoto',                   [SucursalController::class, 'addFoto']);     // { SucursalId, campo, imagen_file }
    Route::delete('quitarFoto/{id}/{campo}', [SucursalController::class, 'quitarFoto']);

    // Papelera de reciclaje
    Route::get('papelera', [SucursalController::class, 'papelera']);
    Route::post('restaurar',          [SucursalController::class, 'restaurar']);          // { ids: [...] }
    Route::post('eliminarDefinitivo', [SucursalController::class, 'eliminarDefinitivo']); // { ids: [...] }
    Route::delete('vaciarPapelera',   [SucursalController::class, 'vaciarPapelera']);
});

// PUNTOS DE VENTA (las cajas de cada sucursal)
// Una sucursal tiene varias cajas, y lo que de verdad las distingue es que
// cada una cuadra su propio dinero: por eso lo importante de la ficha son
// SUS CUENTAS CONTABLES, que no se guardan por aquí sino por el mecanismo
// común (contabilidad/cuentaConfig con ámbito PUNTO_VENTA), el mismo que usan
// las categorías y los grupos de clientes.
//
// Las crean los contadores: el menú se cuelga con los accesos del plan de
// cuentas, no con los de la pantalla de clientes.
Route::group([
    'prefix' => 'puntoVenta', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allPuntosVenta', [PuntoVentaController::class, 'allPuntosVenta']);       // ?activos=0&sucursal_id=
    Route::get('listPuntosVenta', [PuntoVentaController::class, 'listPuntosVenta']);     // ?activos=1 (combos)
    Route::get('findByIdPuntoVenta/{id}', [PuntoVentaController::class, 'findByIdPuntoVenta']);
    Route::get('sugerencia', [PuntoVentaController::class, 'sugerencia']);               // ?sucursal_id=
    Route::post('addPuntoVenta', [PuntoVentaController::class, 'addPuntoVenta']);
    Route::post('editPuntoVenta/{id}', [PuntoVentaController::class, 'editPuntoVenta']);
    Route::post('activarPuntoVenta/{id}', [PuntoVentaController::class, 'activarPuntoVenta']); // { activo? }
    Route::delete('deletePuntoVenta/{id}', [PuntoVentaController::class, 'deletePuntoVenta']);

    // Papelera de reciclaje
    Route::get('papelera', [PuntoVentaController::class, 'papelera']);
    Route::post('restaurarPuntosVenta', [PuntoVentaController::class, 'restaurarPuntosVenta']); // { ids:[..] }
    Route::post('eliminarDefinitivo', [PuntoVentaController::class, 'eliminarDefinitivo']);     // { ids:[..] } (permiso «vaciar»)
    Route::post('vaciarPapelera', [PuntoVentaController::class, 'vaciarPapelera']);             // (permiso «vaciar»)
});
