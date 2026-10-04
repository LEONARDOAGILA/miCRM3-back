<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\ventas\ClienteController;
use App\Http\Controllers\ventas\GestionController;
use App\Http\Controllers\ventas\WhatsappController;
use App\Http\Controllers\ventas\CatalogoGestionController;

// ============================================================================
// MÓDULO VENTAS. Prefijo global: /ventas (RouteServiceProvider).
// Mismo esquema que routes/rh.php: un grupo por entidad con jwt.auth y
// usuario.activo, salvo las rutas que consume <img src> (públicas, como
// getImagenEmpleado).
// ============================================================================

// CLIENTES
Route::group([
    'prefix' => 'cliente',
], function () {
    Route::get('allClientes', [ClienteController::class, 'allClientes'])->middleware(['jwt.auth', 'usuario.activo']);        // paginado: ?page&per_page&search
    Route::get('listClientes', [ClienteController::class, 'listClientes'])->middleware(['jwt.auth', 'usuario.activo']);      // lista simple: ?activos=0
    Route::get('findByIdCliente/{id}', [ClienteController::class, 'findByIdCliente'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('addCliente', [ClienteController::class, 'addCliente'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('editCliente/{id}', [ClienteController::class, 'editCliente'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::delete('deleteCliente/{id}', [ClienteController::class, 'deleteCliente'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('addImagen', [ClienteController::class, 'addImagen'])->middleware(['jwt.auth', 'usuario.activo']);           // { ClienteId, imagen_file }
    Route::get('listContactos/{id}', [ClienteController::class, 'listContactos'])->middleware(['jwt.auth', 'usuario.activo']);        // personas de contacto
    Route::post('guardarContactos/{id}', [ClienteController::class, 'guardarContactos'])->middleware(['jwt.auth', 'usuario.activo']); // { contactos: [...] } sincroniza
    Route::post('guardarUbicacion/{id}', [ClienteController::class, 'guardarUbicacion'])->middleware(['jwt.auth', 'usuario.activo']); // los datos que trae el mapa
    Route::post('addFotoUbicacion', [ClienteController::class, 'addFotoUbicacion'])->middleware(['jwt.auth', 'usuario.activo']);      // { ClienteId, campo: mapa|casa, imagen_file }

    // Papelera de reciclaje (borrado lógico: deleteCliente manda a la papelera)
    Route::get('papelera', [ClienteController::class, 'papelera'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('restaurarClientes', [ClienteController::class, 'restaurarClientes'])->middleware(['jwt.auth', 'usuario.activo']);   // { ids: [...] }
    Route::post('eliminarDefinitivo', [ClienteController::class, 'eliminarDefinitivo'])->middleware(['jwt.auth', 'usuario.activo']); // { ids: [...] }
    Route::delete('vaciarPapelera', [ClienteController::class, 'vaciarPapelera'])->middleware(['jwt.auth', 'usuario.activo']);

    // Públicas (las usa <img src>), como getImagenEmpleado
    Route::get('getImagenCliente/{id}', [ClienteController::class, 'getImagenCliente']);
    Route::get('getFotoUbicacion/{id}/{campo}', [ClienteController::class, 'getFotoUbicacion']);
});

// GESTIÓN DE CLIENTES (llamadas hechas, programadas y reasignación de cartera)
Route::group([
    'prefix' => 'gestion', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allGestiones', [GestionController::class, 'allGestiones']);                 // ?cliente_id&page&per_page&search&tipo&estado&desde&hasta
    Route::get('findByIdGestion/{id}', [GestionController::class, 'findByIdGestion']);
    Route::get('resumen/{clienteId}', [GestionController::class, 'resumen']);               // contadores + última y próxima
    Route::get('estadisticas', [GestionController::class, 'estadisticas']);   // tablero: ?dias=14
    Route::get('agenda', [GestionController::class, 'agenda']);
    Route::get('agendaPaginada', [GestionController::class, 'agendaPaginada']);  // la grilla: + ?page&per_page&search                             // ?empleado_id&desde&hasta&limite
    Route::post('addGestion', [GestionController::class, 'addGestion']);                    // registrar una hecha o programar una
    Route::post('editGestion/{id}', [GestionController::class, 'editGestion']);
    Route::post('cerrarGestion/{id}', [GestionController::class, 'cerrarGestion']);         // { resultado, nota?, duracion_minutos?, siguiente? }
    Route::delete('deleteGestion/{id}', [GestionController::class, 'deleteGestion']);

    // Cartera
    Route::post('reasignar/{clienteId}', [GestionController::class, 'reasignar']);          // { empleado_id, motivo?, mover_agenda?, rol? }
    Route::get('asignaciones/{clienteId}', [GestionController::class, 'asignaciones']);
    Route::get('responsables/{clienteId}', [GestionController::class, 'responsables']);  // quién lo atiende ahora, por papel
});

// CATÁLOGO DE GESTIÓN (tipos y sus asuntos)
// El asunto de una gestión se elige de aquí, no se escribe: es lo que
// permite tabularlo después. 'catalogo' es lo que carga el formulario de
// gestión; el resto lo usa la pantalla de mantenimiento.
Route::group([
    'prefix' => 'catalogoGestion', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('catalogo', [CatalogoGestionController::class, 'catalogo']);                  // tipos activos + sus asuntos activos

    Route::get('allTipos', [CatalogoGestionController::class, 'allTipos']);                  // ?inactivos=0
    Route::post('addTipo', [CatalogoGestionController::class, 'saveTipo']);
    Route::post('editTipo/{id}', [CatalogoGestionController::class, 'saveTipo']);
    Route::delete('deleteTipo/{id}', [CatalogoGestionController::class, 'deleteTipo']);      // si está en uso, desactiva

    Route::get('allAsuntos', [CatalogoGestionController::class, 'allAsuntos']);              // ?tipo_id&inactivos=0
    Route::post('addAsunto', [CatalogoGestionController::class, 'saveAsunto']);
    Route::post('editAsunto/{id}', [CatalogoGestionController::class, 'saveAsunto']);
    Route::delete('deleteAsunto/{id}', [CatalogoGestionController::class, 'deleteAsunto']);  // si está en uso, desactiva
});

// CONVERSACIONES DE WHATSAPP
// El alta la llama el servicio miCRM3-wa con la clave X-WA-TOKEN (no es un
// usuario, así que no lleva jwt.auth); el resto lo consume la pantalla.
Route::group(['prefix' => 'whatsapp'], function () {
    Route::post('mensaje', [WhatsappController::class, 'recibir']);

    Route::group(['middleware' => ['jwt.auth', 'usuario.activo']], function () {
        Route::get('conversacion/{clienteId}', [WhatsappController::class, 'conversacion']);   // ?limite=200
        Route::get('resumen/{clienteId}', [WhatsappController::class, 'resumen']);
        Route::get('sinAsignar', [WhatsappController::class, 'sinAsignar']);                   // ?limite=50
        Route::post('asignar', [WhatsappController::class, 'asignar']);                        // { numero, cliente_id }
    });
});
