<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\inventarios\CaracteristicaController;
use App\Http\Controllers\inventarios\CaracteristicaNombreController;
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
// Las imagenes que van DENTRO de la descripcion: las pide un <img src> del
// propio texto, asi que tampoco pueden llevar cabecera Authorization
Route::get('producto/getImagenDescripcion/{archivo}', [ProductoController::class, 'getImagenDescripcion']);


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
    Route::delete('deleteMarca/{id}',[MarcaController::class, 'deleteMarca']);   // a la papelera

    // Papelera de reciclaje (borrado lógico: deleteMarca manda a la papelera)
    Route::get('papelera', [MarcaController::class, 'papelera']);
    Route::post('restaurarMarcas', [MarcaController::class, 'restaurarMarcas']);     // { ids: [...] }
    Route::post('eliminarDefinitivo', [MarcaController::class, 'eliminarDefinitivo']); // { ids: [...] }
    Route::delete('vaciarPapelera', [MarcaController::class, 'vaciarPapelera']);
    Route::post('addLogo',           [MarcaController::class, 'addLogo']);                 // { MarcaId, imagen_file }
});

// CARACTERÍSTICAS (la plantilla de cada categoría)
Route::group([
    'prefix' => 'caracteristica', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allCaracteristicas',  [CaracteristicaController::class, 'allCaracteristicas']);   // ?page&per_page&search&categoria_id&filtros
    Route::get('listCaracteristicas', [CaracteristicaController::class, 'listCaracteristicas']);  // la plantilla: ?categoria_id&activos=1
    Route::get('findByIdCaracteristica/{id}', [CaracteristicaController::class, 'findByIdCaracteristica']);
    Route::post('addCaracteristica',          [CaracteristicaController::class, 'addCaracteristica']);
    Route::post('editCaracteristica/{id}',    [CaracteristicaController::class, 'editCaracteristica']);
    Route::post('activarCaracteristica/{id}', [CaracteristicaController::class, 'activarCaracteristica']); // { activo? }; sin ella, alterna
    Route::post('requeridoCaracteristica/{id}', [CaracteristicaController::class, 'requeridoCaracteristica']); // { requerido? }; sin ella, alterna
    Route::post('ordenarCaracteristicas',     [CaracteristicaController::class, 'ordenarCaracteristicas']); // { ids: [...] } en el orden nuevo
    Route::delete('deleteCaracteristica/{id}',[CaracteristicaController::class, 'deleteCaracteristica']);  // a la papelera

    // Papelera de reciclaje
    Route::get('papelera', [CaracteristicaController::class, 'papelera']);
    Route::post('restaurar',          [CaracteristicaController::class, 'restaurar']);           // { ids: [...] }
    Route::post('eliminarDefinitivo', [CaracteristicaController::class, 'eliminarDefinitivo']);  // { ids: [...] }
    Route::delete('vaciarPapelera',   [CaracteristicaController::class, 'vaciarPapelera']);
});

// NOMBRES DE CARACTERÍSTICA (el diccionario del que se escoge; pantalla de
// sistemas). `listCaracteristicasNombres` es lo que rellena el combo de
// saveCaracteristica y de la ficha del producto.
Route::group([
    'prefix' => 'caracteristicaNombre', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allCaracteristicasNombres',  [CaracteristicaNombreController::class, 'allCaracteristicasNombres']);  // ?page&per_page&search&filtros
    Route::get('listCaracteristicasNombres', [CaracteristicaNombreController::class, 'listCaracteristicasNombres']); // el combo: ?activos=1
    Route::get('findByIdCaracteristicaNombre/{id}', [CaracteristicaNombreController::class, 'findByIdCaracteristicaNombre']);
    Route::post('addCaracteristicaNombre',          [CaracteristicaNombreController::class, 'addCaracteristicaNombre']);
    Route::post('editCaracteristicaNombre/{id}',    [CaracteristicaNombreController::class, 'editCaracteristicaNombre']);
    Route::post('activarCaracteristicaNombre/{id}', [CaracteristicaNombreController::class, 'activarCaracteristicaNombre']); // { activo? }; sin ella, alterna
    Route::delete('deleteCaracteristicaNombre/{id}',[CaracteristicaNombreController::class, 'deleteCaracteristicaNombre']);  // a la papelera

    // Papelera de reciclaje
    Route::get('papelera', [CaracteristicaNombreController::class, 'papelera']);
    Route::post('restaurar',          [CaracteristicaNombreController::class, 'restaurar']);           // { ids: [...] }
    Route::post('eliminarDefinitivo', [CaracteristicaNombreController::class, 'eliminarDefinitivo']);  // { ids: [...] }
    Route::delete('vaciarPapelera',   [CaracteristicaNombreController::class, 'vaciarPapelera']);
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

    // Lo relleno de la plantilla de su categoría
    Route::get('caracteristicas/{id}',   [ProductoController::class, 'caracteristicas']);

    // La galería
    Route::get('imagenes/{id}',          [ProductoController::class, 'imagenes']);
    Route::post('addImagen',             [ProductoController::class, 'addImagen']);
    Route::post('subirImagenDescripcion', [ProductoController::class, 'subirImagenDescripcion']); // { imagen } -> { archivo }        // { ProductoId, imagen_file }
    Route::post('imagenPrincipal/{id}',  [ProductoController::class, 'imagenPrincipal']);  // {id} es el de la IMAGEN
    Route::post('ordenarImagenes/{id}',  [ProductoController::class, 'ordenarImagenes']);  // { ids: [...] } en el orden nuevo
    Route::delete('deleteImagen/{id}',   [ProductoController::class, 'deleteImagen']);     // {id} es el de la IMAGEN
});
