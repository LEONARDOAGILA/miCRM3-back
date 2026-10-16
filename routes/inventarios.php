<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\inventarios\CategoriaController;
use App\Http\Controllers\inventarios\MarcaController;
use App\Http\Controllers\inventarios\ProductoController;

// ============================================================================
// MÓDULO INVENTARIOS. Prefijo global: /inventarios (RouteServiceProvider).
// Mismo esquema que routes/rh.php: un grupo por entidad con jwt.auth y
// usuario.activo.
//
// Las dos rutas que sirven ficheros (getLogo, getImagen) van FUERA de los
// grupos: las pide un <img src>, que no manda la cabecera Authorization. El
// control de acceso de esas dos es el id: no listan nada y no dicen de quién
// es lo que sirven, igual que getImagenCliente y getImagenEmpleado.
// ============================================================================

// Ficheros (públicas, las usa <img src>)
Route::get('marca/getLogo/{id}',      [MarcaController::class,    'getLogo']);
Route::get('producto/getImagen/{id}', [ProductoController::class, 'getImagen']);


// CATEGORÍAS (árbol)
Route::group([
    'prefix' => 'categoria', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allCategorias',  [CategoriaController::class, 'allCategorias']);          // el árbol entero: ?activos=1 para sólo activas
    Route::get('listCategorias', [CategoriaController::class, 'listCategorias']);         // lo mismo, para los combos
    Route::get('findByIdCategoria/{id}', [CategoriaController::class, 'findByIdCategoria']);
    Route::post('addCategoria',          [CategoriaController::class, 'addCategoria']);
    Route::post('editCategoria/{id}',    [CategoriaController::class, 'editCategoria']);
    Route::post('activarCategoria/{id}', [CategoriaController::class, 'activarCategoria']); // { activo? }; sin ella, alterna
    Route::post('moverCategoria/{id}',   [CategoriaController::class, 'moverCategoria']);   // { padre_id, antes_de }
    Route::delete('deleteCategoria/{id}',[CategoriaController::class, 'deleteCategoria']);   // a la papelera

    // Papelera de reciclaje (borrado lógico: deleteCategoria manda a la papelera)
    Route::get('papelera', [CategoriaController::class, 'papelera']);
    Route::post('restaurarCategorias', [CategoriaController::class, 'restaurarCategorias']); // { ids: [...] }
    Route::post('eliminarDefinitivo', [CategoriaController::class, 'eliminarDefinitivo']);   // { ids: [...] }
    Route::delete('vaciarPapelera', [CategoriaController::class, 'vaciarPapelera']);
});

// MARCAS
Route::group([
    'prefix' => 'marca', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allMarcas',   [MarcaController::class, 'allMarcas']);                      // paginado: ?page&per_page&search
    Route::get('listMarcas',  [MarcaController::class, 'listMarcas']);                     // lista simple: ?activos=0
    Route::get('findByIdMarca/{id}', [MarcaController::class, 'findByIdMarca']);
    Route::post('addMarca',          [MarcaController::class, 'addMarca']);
    Route::post('editMarca/{id}',    [MarcaController::class, 'editMarca']);
    Route::post('activarMarca/{id}', [MarcaController::class, 'activarMarca']);            // { activo? }; sin ella, alterna
    Route::delete('deleteMarca/{id}',[MarcaController::class, 'deleteMarca']);
    Route::post('addLogo',           [MarcaController::class, 'addLogo']);                 // { MarcaId, imagen_file }
});

// PRODUCTOS
Route::group([
    'prefix' => 'producto', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allProductos',  [ProductoController::class, 'allProductos']);              // ?page&per_page&search&marca_id&categoria_id&filtros

    // Papelera de reciclaje (borrado lógico: deleteProducto manda a la papelera)
    Route::get('papelera', [ProductoController::class, 'papelera']);
    Route::post('restaurarProductos', [ProductoController::class, 'restaurarProductos']);   // { ids: [...] }
    Route::post('eliminarDefinitivo', [ProductoController::class, 'eliminarDefinitivo']);   // { ids: [...] }
    Route::delete('vaciarPapelera', [ProductoController::class, 'vaciarPapelera']);
    Route::get('listProductos', [ProductoController::class, 'listProductos']);             // lista simple: ?activos=0
    Route::get('findByIdProducto/{id}', [ProductoController::class, 'findByIdProducto']);  // incluye la galería
    Route::post('addProducto',          [ProductoController::class, 'addProducto']);
    Route::post('editProducto/{id}',    [ProductoController::class, 'editProducto']);
    Route::post('activarProducto/{id}', [ProductoController::class, 'activarProducto']);   // { activo? }; sin ella, alterna
    Route::delete('deleteProducto/{id}',[ProductoController::class, 'deleteProducto']);

    // La galería
    Route::get('imagenes/{id}',          [ProductoController::class, 'imagenes']);
    Route::post('addImagen',             [ProductoController::class, 'addImagen']);        // { ProductoId, imagen_file }
    Route::post('imagenPrincipal/{id}',  [ProductoController::class, 'imagenPrincipal']);  // {id} es el de la IMAGEN
    Route::post('ordenarImagenes/{id}',  [ProductoController::class, 'ordenarImagenes']);  // { ids: [...] } en el orden nuevo
    Route::delete('deleteImagen/{id}',   [ProductoController::class, 'deleteImagen']);     // {id} es el de la IMAGEN
});
