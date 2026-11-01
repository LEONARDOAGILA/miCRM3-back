<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\ecommerce\ArchivoPublicoController;
use App\Http\Controllers\ecommerce\PaginaInformativaController;
use App\Http\Controllers\ecommerce\PaginaInformativaPublicoController;

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

    // Páginas de texto
    Route::get('documentos',       [PaginaInformativaPublicoController::class, 'documentos']);
    Route::get('paginas/{clave}',  [PaginaInformativaPublicoController::class, 'pagina'])
         ->where('clave', '[a-z0-9_-]+');
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
