<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\ecommerce\ArchivoPublicoController;
use App\Http\Controllers\ecommerce\CategoriaWebController;
use App\Http\Controllers\ecommerce\CategoriaWebPublicoController;
use App\Http\Controllers\ecommerce\EncabezadoController;
use App\Http\Controllers\ecommerce\EspanaMotosController;
use App\Http\Controllers\ecommerce\EspanaMotosPublicoController;
use App\Http\Controllers\ecommerce\GaleriaPublicoController;
use App\Http\Controllers\ecommerce\ImagenController;
use App\Http\Controllers\ecommerce\InicioPublicoController;
use App\Http\Controllers\ecommerce\PaginaInformativaController;
use App\Http\Controllers\ecommerce\PaginaInformativaPublicoController;
use App\Http\Controllers\ecommerce\PiePaginaController;
use App\Http\Controllers\ecommerce\ResumenController;
use App\Http\Controllers\ecommerce\SeccionPublicaController;

// ============================================================================
// MÓDULO ECOMMERCE. Prefijo global: /ecommerce (RouteServiceProvider).
//
// Aquí hay DOS PÚBLICOS distintos, y por eso dos bloques:
//
//   · /ecommerce/publico/…  lo pide LA TIENDA, sin token. Es un visitante
//     cualquiera con su navegador; no hay sesión que pedirle.
//   · el resto lo pide el CRM, con jwt.auth y usuario.activo como todos los
//     demás módulos.
//
// Lo público va PRIMERO y FUERA de los grupos. Si cayera dentro del grupo con
// jwt.auth, un <img src> de la tienda recibiría un 302 al login en vez de la
// imagen, y lo que se vería es el icono de imagen rota.
//
// Este módulo se traslada por pantallas desde el CRM viejo (crm-back,
// app/Http/Controllers/paginaWeb). De las quince, aquí están las páginas
// informativas; las demás se van añadiendo a este mismo fichero.
// ============================================================================

// ----------------------------------------------------------------------------
// LO QUE LEE LA TIENDA (sin token)
// ----------------------------------------------------------------------------
Route::group(['prefix' => 'publico'], function () {

    // Los ficheros. Van antes que nada porque `documentos/{nombre}` y
    // `documentos` son rutas distintas y conviene verlas juntas.
    Route::get('imagenes/{nombre}',   [ArchivoPublicoController::class, 'imagen'])
         ->where('nombre', '[A-Za-z0-9][A-Za-z0-9._-]*');
    Route::get('documentos/{nombre}', [ArchivoPublicoController::class, 'documento'])
         ->where('nombre', '[A-Za-z0-9][A-Za-z0-9._-]*\.pdf');

    // El encabezado y el pie, en una sola llamada: es lo primero que pide la
    // tienda al abrir cualquier página.
    Route::get('secciones',        [SeccionPublicaController::class, 'listar']);

    // El árbol de categorías: el desplegable del encabezado y los filtros de
    // /shop. Va anidado, no plano.
    Route::get('categorias-menu',  [CategoriaWebPublicoController::class, 'menu']);

    // El micro-sitio de España Motos. Sin publicar devuelve 404.
    Route::get('espana-motos',     [EspanaMotosPublicoController::class, 'pagina']);

    // La portada: la lista de secciones en su orden. Crece sola segun se
    // migran sus fuentes; la tienda ignora las claves que no conoce.
    Route::get('inicio',           [InicioPublicoController::class, 'inicio']);

    // Los bloques de imágenes: el banner del inicio, las tarjetas, los logos
    // de «dónde pagar» del pie. La clave es el sitio del diseño.
    Route::get('galerias/{clave}', [GaleriaPublicoController::class, 'listar'])
         ->where('clave', '[a-z0-9_]+');

    // Páginas de texto
    Route::get('documentos',       [PaginaInformativaPublicoController::class, 'documentos']);
    Route::get('paginas/{clave}',  [PaginaInformativaPublicoController::class, 'pagina'])
         ->where('clave', '[a-z0-9_-]+');
});

// ----------------------------------------------------------------------------
// LA PORTADA DEL MÓDULO
// ----------------------------------------------------------------------------
// Las once tarjetas con su conteo, en una sola llamada.
Route::group([
    'prefix' => 'resumen', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('getResumen', [ResumenController::class, 'getResumen']);
});

// ----------------------------------------------------------------------------
// CATEGORÍAS DE LA TIENDA (administración)
// ----------------------------------------------------------------------------
// El árbol es de Inventarios; aquí sólo se decide qué sale y con qué nombre.
Route::group([
    'prefix' => 'categoriaWeb', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allCategoriasWeb',       [CategoriaWebController::class, 'allCategoriasWeb']);
    Route::post('editCategoriaWeb/{id}', [CategoriaWebController::class, 'editCategoriaWeb'])->whereNumber('id');
});

// ----------------------------------------------------------------------------
// LA BIBLIOTECA DE IMÁGENES (administración)
// ----------------------------------------------------------------------------
// Una sola carpeta para toda la página web: el fondo de España Motos, los
// banners, las tarjetas del inicio y los logos del pie salen de aquí. Se sube
// una vez y se elige donde haga falta.
Route::group([
    'prefix' => 'imagen', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('listar', [ImagenController::class, 'listar']);   // ?buscar=
    Route::post('subir', [ImagenController::class, 'subir']);    // multipart, campo `imagen`
});

// ----------------------------------------------------------------------------
// ESPAÑA MOTOS (administración)
// ----------------------------------------------------------------------------
// Las pestañas agrupan categorías del catálogo; las marcas salen de
// inventarios.marcas. Se publica aparte, con su propia palanca.
Route::group([
    'prefix' => 'espanaMotos', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('getEspanaMotos',   [EspanaMotosController::class, 'getEspanaMotos']);
    Route::post('editEspanaMotos', [EspanaMotosController::class, 'editEspanaMotos']);

    Route::post('addPestana',           [EspanaMotosController::class, 'addPestana']);          // { nombre, categorias: [...] }
    Route::post('editPestana/{id}',     [EspanaMotosController::class, 'editPestana'])->whereNumber('id');
    Route::delete('deletePestana/{id}', [EspanaMotosController::class, 'deletePestana'])->whereNumber('id');

    Route::post('addMarca',           [EspanaMotosController::class, 'addMarca']);               // { marca_id }
    Route::delete('deleteMarca/{id}', [EspanaMotosController::class, 'deleteMarca'])->whereNumber('id');

    Route::post('ordenarPestanas', [EspanaMotosController::class, 'ordenarPestanas']);           // { ids: [...] }
    Route::post('ordenarMarcas',   [EspanaMotosController::class, 'ordenarMarcas']);             // { ids: [...] }
});

// ----------------------------------------------------------------------------
// ENCABEZADO (administración)
// ----------------------------------------------------------------------------
Route::group([
    'prefix' => 'encabezado', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {

    Route::get('getEncabezado',   [EncabezadoController::class, 'getEncabezado']);   // config + menú
    Route::post('editEncabezado', [EncabezadoController::class, 'editEncabezado']);  // { config }

    Route::post('addEnlace',           [EncabezadoController::class, 'addEnlace']);                        // { padre_id?, texto, … }
    Route::post('editEnlace/{id}',     [EncabezadoController::class, 'editEnlace'])->whereNumber('id');
    Route::post('activarEnlace/{id}',  [EncabezadoController::class, 'activarEnlace'])->whereNumber('id'); // { activo? }; sin ella, alterna
    Route::post('ordenarEnlaces',      [EncabezadoController::class, 'ordenarEnlaces']);                   // { ids: [...] }
    Route::delete('deleteEnlace/{id}', [EncabezadoController::class, 'deleteEnlace'])->whereNumber('id');  // se lleva sus desplegables

    Route::get('papelera',          [EncabezadoController::class, 'papelera']);
    Route::post('restaurar',        [EncabezadoController::class, 'restaurar']);      // { ids: [...] }
    Route::delete('vaciarPapelera', [EncabezadoController::class, 'vaciarPapelera']); // permiso «vaciar»
});

// ----------------------------------------------------------------------------
// PIE DE PÁGINA (administración)
// ----------------------------------------------------------------------------
Route::group([
    'prefix' => 'pie', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {

    Route::get('getPie',   [PiePaginaController::class, 'getPie']);    // config + columnas + enlaces
    Route::post('editPie', [PiePaginaController::class, 'editPie']);   // { config }

    Route::post('addColumna',           [PiePaginaController::class, 'addColumna']);
    Route::post('editColumna/{id}',     [PiePaginaController::class, 'editColumna'])->whereNumber('id');
    Route::delete('deleteColumna/{id}', [PiePaginaController::class, 'deleteColumna'])->whereNumber('id'); // se lleva sus enlaces

    Route::post('addEnlace',           [PiePaginaController::class, 'addEnlace']);
    Route::post('editEnlace/{id}',     [PiePaginaController::class, 'editEnlace'])->whereNumber('id');
    Route::delete('deleteEnlace/{id}', [PiePaginaController::class, 'deleteEnlace'])->whereNumber('id');

    Route::post('ordenarColumnas', [PiePaginaController::class, 'ordenarColumnas']); // { ids: [...] }
    Route::post('ordenarEnlaces',  [PiePaginaController::class, 'ordenarEnlaces']);  // { ids: [...] }

    // La papelera es UNA para columnas y enlaces: borrar una columna se lleva
    // los suyos y hay que verlos juntos.
    Route::get('papelera',          [PiePaginaController::class, 'papelera']);
    Route::post('restaurar',        [PiePaginaController::class, 'restaurar']);      // { tipo, id }
    Route::delete('vaciarPapelera', [PiePaginaController::class, 'vaciarPapelera']); // permiso «vaciar»
});

// ----------------------------------------------------------------------------
// PÁGINAS INFORMATIVAS (administración)
// ----------------------------------------------------------------------------
Route::group([
    'prefix' => 'paginaInformativa', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {

    Route::get('allPaginasInformativas', [PaginaInformativaController::class, 'allPaginasInformativas']); // páginas + carpetas
    Route::get('findByIdPaginaInformativa/{id}',       [PaginaInformativaController::class, 'findByIdPaginaInformativa'])->whereNumber('id');
    Route::get('findByClavePaginaInformativa/{clave}', [PaginaInformativaController::class, 'findByClavePaginaInformativa'])->where('clave', '[a-z0-9_-]+');

    Route::post('addPaginaInformativa',          [PaginaInformativaController::class, 'addPaginaInformativa']);
    Route::post('editPaginaInformativa/{id}',    [PaginaInformativaController::class, 'editPaginaInformativa'])->whereNumber('id');
    Route::post('activarPaginaInformativa/{id}', [PaginaInformativaController::class, 'activarPaginaInformativa'])->whereNumber('id'); // { activo? }; sin ella, alterna
    Route::post('ordenarPaginasInformativas',    [PaginaInformativaController::class, 'ordenarPaginasInformativas']);                  // { ids: [...] }
    Route::delete('deletePaginaInformativa/{id}',[PaginaInformativaController::class, 'deletePaginaInformativa'])->whereNumber('id');   // a la papelera

    // La papelera es UNA para páginas y carpetas: en la pantalla es un solo
    // cesto con dos niveles.
    Route::get('papelera',          [PaginaInformativaController::class, 'papelera']);
    Route::post('restaurar',        [PaginaInformativaController::class, 'restaurar']);      // { ids: [...] }
    Route::delete('vaciarPapelera', [PaginaInformativaController::class, 'vaciarPapelera']); // permiso «vaciar»

    // Carpetas
    Route::get('grupos',             [PaginaInformativaController::class, 'grupos']);
    Route::post('addGrupo',          [PaginaInformativaController::class, 'addGrupo']);
    Route::post('editGrupo/{id}',    [PaginaInformativaController::class, 'editGrupo'])->whereNumber('id');
    Route::post('ordenarGrupos',     [PaginaInformativaController::class, 'ordenarGrupos']);   // { ids: [...] }
    Route::post('restaurarGrupo/{id}', [PaginaInformativaController::class, 'restaurarGrupo'])->whereNumber('id');
    Route::delete('deleteGrupo/{id}',  [PaginaInformativaController::class, 'deleteGrupo'])->whereNumber('id'); // se lleva sus páginas
});
