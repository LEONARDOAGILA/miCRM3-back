<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\ecommerce\ArchivoPublicoController;
use App\Http\Controllers\ecommerce\CategoriaWebController;
use App\Http\Controllers\ecommerce\CategoriaWebPublicoController;
use App\Http\Controllers\ecommerce\CuerpoController;
use App\Http\Controllers\ecommerce\EncabezadoController;
use App\Http\Controllers\ecommerce\EspanaMotosController;
use App\Http\Controllers\ecommerce\EspanaMotosPublicoController;
use App\Http\Controllers\ecommerce\GaleriaController;
use App\Http\Controllers\ecommerce\GaleriaPublicoController;
use App\Http\Controllers\ecommerce\ImagenController;
use App\Http\Controllers\ecommerce\InicioController;
use App\Http\Controllers\ecommerce\InicioPublicoController;
use App\Http\Controllers\ecommerce\MarcaWebController;
use App\Http\Controllers\ecommerce\PaginaInformativaController;
use App\Http\Controllers\ecommerce\PaginaInformativaPublicoController;
use App\Http\Controllers\ecommerce\PiePaginaController;
use App\Http\Controllers\ecommerce\ProductoSeccionController;
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

    // Y cualquier otra página de secciones, por su dirección: /movilidad,
    // /bajaj. La que no existe, está apagada o está en la papelera da 404.
    Route::get('cuerpo/{ruta}',    [InicioPublicoController::class, 'cuerpo'])
         ->where('ruta', '[a-z0-9][a-z0-9-]*');

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
// Todas las tarjetas con su conteo, en una sola llamada.
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

    // El orden de los circulos de la portada. Llega entero: todas las destacadas.
    Route::post('ordenarDestacadas',     [CategoriaWebController::class, 'ordenarDestacadas']);  // { ids: [...] }
    Route::post('ordenarPromocion',      [CategoriaWebController::class, 'ordenarPromocion']);   // { ids: [...] }
    // El orden dentro de una rama: todas las hijas del mismo padre.
    Route::post('ordenarCategorias',     [CategoriaWebController::class, 'ordenarCategorias']);  // { ids: [...] }

    // Las imágenes de cada categoría, programadas por fechas. El fichero sube
    // en multipart y acaba en storage/app/public/img/ecommerce.
    Route::get('imagenesCuentas',          [CategoriaWebController::class, 'imagenesCuentas']);
    Route::get('imagenes/{categoria}',     [CategoriaWebController::class, 'imagenes'])->whereNumber('categoria');
    Route::post('addImagen/{categoria}',   [CategoriaWebController::class, 'addImagen'])->whereNumber('categoria');
    Route::post('editImagen/{categoria}/{id}', [CategoriaWebController::class, 'editImagen'])
         ->whereNumber('categoria')->whereNumber('id');
    Route::post('activarImagen/{id}',      [CategoriaWebController::class, 'activarImagen'])->whereNumber('id');
    Route::post('ordenarImagenes',         [CategoriaWebController::class, 'ordenarImagenes']);   // { ids: [...] }
    Route::delete('deleteImagen/{id}',     [CategoriaWebController::class, 'deleteImagen'])->whereNumber('id');

    Route::get('papeleraImagenes/{categoria}', [CategoriaWebController::class, 'papeleraImagenes'])
         ->whereNumber('categoria');
    Route::post('restaurarImagenes',       [CategoriaWebController::class, 'restaurarImagenes']); // { ids: [...] }
    Route::post('vaciarImagenes/{categoria}', [CategoriaWebController::class, 'vaciarImagenes'])
         ->whereNumber('categoria');
});

// ----------------------------------------------------------------------------
// LOS CUERPOS DE LA TIENDA (administración)
// ----------------------------------------------------------------------------
// Un cuerpo es una página hecha de secciones. Uno es el PRINCIPAL y sale al
// abrir la tienda; los demás se llegan por su dirección, y si apuntan a una
// categoría o a una marca, el clic en ella lleva ahí en vez de a /shop.
Route::group([
    'prefix' => 'cuerpo', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allCuerpos',                [CuerpoController::class, 'allCuerpos']);
    Route::post('addCuerpo',                [CuerpoController::class, 'addCuerpo']);        // { nombre, ruta, categoria_id?, marca_id?, … }
    Route::post('editCuerpo/{id}',          [CuerpoController::class, 'editCuerpo'])->whereNumber('id');
    Route::post('activarCuerpo/{id}',       [CuerpoController::class, 'activarCuerpo'])->whereNumber('id');
    // Cuál es la entrada de la tienda. El de antes deja de serlo solo.
    Route::post('principalCuerpo/{id}',     [CuerpoController::class, 'principalCuerpo'])->whereNumber('id');
    Route::delete('deleteCuerpo/{id}',      [CuerpoController::class, 'deleteCuerpo'])->whereNumber('id');

    Route::get('papelera',                  [CuerpoController::class, 'papelera']);
    Route::post('restaurarCuerpo/{id}',     [CuerpoController::class, 'restaurarCuerpo'])->whereNumber('id');
    // Sin ids: vacía la papelera entera, como el resto de las de la casa
    Route::delete('vaciarPapelera',         [CuerpoController::class, 'vaciarPapelera']);
});

// ----------------------------------------------------------------------------
// LAS SECCIONES DE UN CUERPO (administración)
// ----------------------------------------------------------------------------
// Las de fábrica no se crean ni se borran: cada una existe porque la tienda
// sabe pintarla, y nacen con el cuerpo. Lo que se administra es su orden, su
// título y su vigencia.
//
// TODO VA POR EL `id` DE LA SECCIÓN: la clave es única dentro del cuerpo, no
// en la tabla —cada cuerpo tiene su «banner_principal»—, así que una clave
// sola no diría de cuál se habla.
Route::group([
    'prefix' => 'inicio', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allInicio',                [InicioController::class, 'allInicio']);  // ?cuerpo_id=; sin él, el principal
    Route::post('editSeccion/{id}',        [InicioController::class, 'editSeccion'])
         ->whereNumber('id');                                                        // { titulo?, subtitulo?, alcance?, activo?, desde?, hasta? }
    Route::post('activarSeccion/{id}',     [InicioController::class, 'activarSeccion'])
         ->whereNumber('id');                                                        // { activo? }; sin ella, alterna
    Route::post('altoSeccion/{id}',        [InicioController::class, 'altoSeccion'])
         ->whereNumber('id');                                                        // { alto }; sólo el alto, sin tocar el rótulo
    // El FICHERO de la imagen de al lado va aparte: editSeccion escribe todos
    // sus campos, así que guardar el rótulo la borraría
    Route::post('imagenSeccion/{id}',      [InicioController::class, 'imagenSeccion'])
         ->whereNumber('id');                                                        // multipart: imagen
    Route::delete('imagenSeccion/{id}',    [InicioController::class, 'quitarImagenSeccion'])
         ->whereNumber('id');
    // Los banners SÍ se crean y se borran desde la pantalla: son una galería de
    // imágenes con su sitio, y la tienda ya sabe pintarlos
    Route::post('addBanner',               [InicioController::class, 'addBanner']);   // { nombre, cuerpo_id? }
    Route::post('nombreBanner/{id}',       [InicioController::class, 'nombreBanner'])
         ->whereNumber('id');                                                         // { nombre }
    Route::delete('deleteBanner/{id}',     [InicioController::class, 'deleteBanner'])
         ->whereNumber('id');

    // Los escaparates de «Productos por sección» se pueden enseñar en VARIAS
    // páginas: aquí se añade uno a ésta y se quita de ésta. Quitarlo no lo
    // borra; sus productos siguen en su pantalla.
    Route::get('escaparatesDisponibles',   [InicioController::class, 'escaparatesDisponibles']); // ?cuerpo_id=
    Route::post('addEscaparate',           [InicioController::class, 'addEscaparate']);  // { seccion_id, cuerpo_id? }
    Route::delete('quitarEscaparate/{id}', [InicioController::class, 'quitarEscaparate'])
         ->whereNumber('id');

    Route::post('ordenarSecciones',        [InicioController::class, 'ordenarSecciones']);  // { ids: [...], cuerpo_id? }
});

// ----------------------------------------------------------------------------
// LAS GALERÍAS (administración)
// ----------------------------------------------------------------------------
// Una galería es un sitio del diseño con su clave fija. El fichero no se sube
// aquí: se elige de la biblioteca de imágenes y en la base va sólo el nombre.
Route::group([
    'prefix' => 'galeria', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allGalerias',          [GaleriaController::class, 'allGalerias']);
    Route::get('getGaleria/{clave}',   [GaleriaController::class, 'getGaleria'])
         ->where('clave', '[a-z0-9_]+');

    Route::post('addImagen/{clave}',       [GaleriaController::class, 'addImagen'])
         ->where('clave', '[a-z0-9_]+');
    Route::post('editImagen/{clave}/{id}', [GaleriaController::class, 'editImagen'])
         ->where('clave', '[a-z0-9_]+')->whereNumber('id');
    Route::post('activarImagen/{id}',      [GaleriaController::class, 'activarImagen'])->whereNumber('id');
    Route::post('ordenarImagenes',         [GaleriaController::class, 'ordenarImagenes']);   // { ids: [...] }
    Route::delete('deleteImagen/{id}',     [GaleriaController::class, 'deleteImagen'])->whereNumber('id');

    // La papelera es POR GALERÍA: el botón está dentro de una sola, y vaciar
    // la de todas desde ahí haría justo lo que nadie quería.
    Route::get('papelera/{clave}',         [GaleriaController::class, 'papelera'])
         ->where('clave', '[a-z0-9_]+');
    Route::post('restaurar',               [GaleriaController::class, 'restaurar']);         // { ids: [...] }
    Route::post('vaciarPapelera/{clave}',  [GaleriaController::class, 'vaciarPapelera'])
         ->where('clave', '[a-z0-9_]+');
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
// LAS MARCAS DE LA TIENDA (administración)
// ----------------------------------------------------------------------------
// El catálogo es de Inventarios; aquí sólo se decide qué marcas salen, con qué
// nombre, en qué orden y con qué imagen. La imagen programada manda sobre el
// logo del catálogo mientras esté en fecha.
Route::group([
    'prefix' => 'marcaWeb', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allMarcasWeb',        [MarcaWebController::class, 'allMarcasWeb']);
    Route::post('editMarcaWeb/{id}',  [MarcaWebController::class, 'editMarcaWeb'])->whereNumber('id');
    Route::post('ordenarMarcas',      [MarcaWebController::class, 'ordenarMarcas']);      // { ids: [...] }
    // El orden de los carteles de «Marcas en promoción», que es otro
    Route::post('ordenarPromocion',   [MarcaWebController::class, 'ordenarPromocion']);   // { ids: [...] }

    // Las imágenes de cada marca, programadas por fechas. El fichero sube en
    // multipart y acaba en storage/app/public/img/ecommerce.
    Route::get('imagenesCuentas',     [MarcaWebController::class, 'imagenesCuentas']);
    Route::get('imagenes/{marca}',    [MarcaWebController::class, 'imagenes'])->whereNumber('marca');
    Route::post('addImagen/{marca}',  [MarcaWebController::class, 'addImagen'])->whereNumber('marca');
    Route::post('editImagen/{marca}/{id}', [MarcaWebController::class, 'editImagen'])
         ->whereNumber('marca')->whereNumber('id');
    Route::post('activarImagen/{id}', [MarcaWebController::class, 'activarImagen'])->whereNumber('id');
    Route::post('ordenarImagenes',    [MarcaWebController::class, 'ordenarImagenes']);    // { ids: [...] }
    Route::delete('deleteImagen/{id}', [MarcaWebController::class, 'deleteImagen'])->whereNumber('id');

    Route::get('papeleraImagenes/{marca}', [MarcaWebController::class, 'papeleraImagenes'])
         ->whereNumber('marca');
    Route::post('restaurarImagenes',  [MarcaWebController::class, 'restaurarImagenes']);  // { ids: [...] }
    Route::post('vaciarImagenes/{marca}', [MarcaWebController::class, 'vaciarImagenes'])
         ->whereNumber('marca');
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

    // El FICHERO de la imagen de una columna va aparte: editColumna escribe
    // todos sus campos, así que renombrarla la borraría
    Route::post('imagenColumna/{id}',   [PiePaginaController::class, 'imagenColumna'])->whereNumber('id');   // multipart: imagen
    Route::delete('imagenColumna/{id}', [PiePaginaController::class, 'quitarImagenColumna'])->whereNumber('id');

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

// ----------------------------------------------------------------------------
// SECCIONES DE PRODUCTOS (administración)
// ----------------------------------------------------------------------------
// Escaparates armados a mano: «Los más vendidos», «Ofertas de navidad». La
// sección sólo tiene nombre, orden y vigencia; lo que lleva dentro va en el
// cruce, y entra de uno en uno o de golpe por filtro.
//
// EL CATÁLOGO NO ESTÁ AQUÍ: la rejilla de la pantalla lo pide a
// `inventarios/producto/allProductos`, la misma que usa la pantalla de
// productos. Y `agregarFiltro` recibe EL FILTRO, no los ids: el navegador
// sólo tiene la página que está viendo, y los 340 que cumplen el filtro los
// resuelve la base con esa misma función de listado.
Route::group([
    'prefix' => 'productoSeccion', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {

    Route::get('allSecciones',          [ProductoSeccionController::class, 'allSecciones']);
    Route::post('addSeccion',           [ProductoSeccionController::class, 'addSeccion']);                       // { nombre, desde?, hasta? }
    Route::post('editSeccion/{id}',     [ProductoSeccionController::class, 'editSeccion'])->whereNumber('id');
    Route::post('activarSeccion/{id}',  [ProductoSeccionController::class, 'activarSeccion'])->whereNumber('id'); // { activo? }; sin ella, alterna
    Route::post('ordenarSecciones',     [ProductoSeccionController::class, 'ordenarSecciones']);                  // { ids: [...] }
    Route::delete('deleteSeccion/{id}', [ProductoSeccionController::class, 'deleteSeccion'])->whereNumber('id');  // a la papelera

    Route::get('papeleraSecciones',       [ProductoSeccionController::class, 'papeleraSecciones']);
    Route::post('restaurarSeccion/{id}',  [ProductoSeccionController::class, 'restaurarSeccion'])->whereNumber('id');

    // Lo que lleva dentro. `productos` trae las fichas completas —las mismas
    // que el catálogo, para que la rejilla pinte igual las dos vistas— e
    // `ids` sólo los números, que es lo que necesita el catálogo para marcar
    // qué filas ya están dentro.
    Route::get('productos/{id}',     [ProductoSeccionController::class, 'productos'])->whereNumber('id');
    Route::get('ids/{id}',           [ProductoSeccionController::class, 'ids'])->whereNumber('id');
    Route::post('agregar/{id}',      [ProductoSeccionController::class, 'agregar'])->whereNumber('id');       // { producto_ids: [...] }
    Route::post('quitar/{id}',       [ProductoSeccionController::class, 'quitar'])->whereNumber('id');        // { producto_ids: [...] }
    Route::post('ordenar/{id}',      [ProductoSeccionController::class, 'ordenar'])->whereNumber('id');       // { producto_ids: [...] }
    Route::post('agregarFiltro/{id}', [ProductoSeccionController::class, 'agregarFiltro'])->whereNumber('id'); // { search?, marca_ids?, … }
});
