<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\rh\CargoController;
use App\Http\Controllers\rh\DepartamentoController;
use App\Http\Controllers\rh\EmpleadoController;
use App\Http\Controllers\rh\HorarioEmpleadoController;
use App\Http\Controllers\rh\MarcacionController;
use App\Http\Controllers\rh\RostroController;

// ============================================================================
// MÓDULO RH (recursos humanos). Prefijo global: /rh (RouteServiceProvider).
// Mismo esquema que routes/auth.php: un grupo por entidad con jwt.auth y
// usuario.activo.
// ============================================================================

// CARGOS
Route::group([
    'prefix' => 'cargo', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allCargos', [CargoController::class, 'allCargos']);            // paginado: ?page&per_page&search
    Route::get('listCargos', [CargoController::class, 'listCargos']);          // lista simple: ?activos=0 para incluir inactivos
    Route::get('findByIdCargo/{id}', [CargoController::class, 'findByIdCargo']);
    Route::post('addCargo', [CargoController::class, 'addCargo']);
    Route::post('editCargo/{id}', [CargoController::class, 'editCargo']);
    Route::post('activarCargo/{id}', [CargoController::class, 'activarCargo']);   // { activo? }; sin ella, alterna
    Route::delete('deleteCargo/{id}', [CargoController::class, 'deleteCargo']);   // a la papelera

    // Papelera de reciclaje (borrado lógico: deleteCargo manda a la papelera)
    Route::get('papelera', [CargoController::class, 'papelera']);
    Route::post('restaurarCargos', [CargoController::class, 'restaurarCargos']);       // { ids: [...] }
    Route::post('eliminarDefinitivo', [CargoController::class, 'eliminarDefinitivo']); // { ids: [...] }
    Route::delete('vaciarPapelera', [CargoController::class, 'vaciarPapelera']);
});

// HORARIOS DE TRABAJO DEL PERSONAL (hasta 4 jornadas por día)
// No confundir con auth/horario, que es el horario de ACCESO AL CRM: aquél
// cierra la sesión fuera de hora, éste dice a qué hora se espera al empleado
// en su puesto y es contra el que se miden los atrasos de las marcaciones.
Route::group([
    'prefix' => 'horarioEmpleado', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allHorariosEmpleados',  [HorarioEmpleadoController::class, 'allHorariosEmpleados']);   // ?page&per_page&search&filtros
    Route::get('listHorariosEmpleados', [HorarioEmpleadoController::class, 'listHorariosEmpleados']);  // los activos (selector)
    Route::get('getHorarioEmpleado/{id}', [HorarioEmpleadoController::class, 'getHorarioEmpleado']);   // la ficha con sus jornadas
    Route::post('addHorarioEmpleado',       [HorarioEmpleadoController::class, 'addHorarioEmpleado']);
    Route::post('editHorarioEmpleado/{id}', [HorarioEmpleadoController::class, 'editHorarioEmpleado']);
    Route::post('activarHorarioEmpleado/{id}', [HorarioEmpleadoController::class, 'activarHorarioEmpleado']); // { activo? }; sin ella, alterna
    Route::delete('deleteHorarioEmpleado/{id}', [HorarioEmpleadoController::class, 'deleteHorarioEmpleado']); // a la papelera

    // Probar el horario contra una hora cualquiera: qué jornada toca y cuánto atraso
    Route::get('evaluar/{id}', [HorarioEmpleadoController::class, 'evaluar']);                         // ?fecha_hora=

    // Papelera de reciclaje (deleteHorarioEmpleado manda a la papelera, con sus jornadas)
    Route::get('papelera', [HorarioEmpleadoController::class, 'papelera']);
    Route::post('restaurarHorariosEmpleados', [HorarioEmpleadoController::class, 'restaurarHorariosEmpleados']); // { ids: [...] }
    Route::post('eliminarDefinitivo', [HorarioEmpleadoController::class, 'eliminarDefinitivo']);                 // { ids: [...] }
    Route::delete('vaciarPapelera', [HorarioEmpleadoController::class, 'vaciarPapelera']);
});

// DEPARTAMENTOS
Route::group([
    'prefix' => 'departamento', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allDepartamentos', [DepartamentoController::class, 'allDepartamentos']);          // paginado: ?page&per_page&search
    Route::get('listDepartamentos', [DepartamentoController::class, 'listDepartamentos']);        // lista simple: ?activos=0 para incluir inactivos
    Route::get('listResponsables', [DepartamentoController::class, 'listResponsables']);          // empleados activos (combo Responsable)
    Route::get('findByIdDepartamento/{id}', [DepartamentoController::class, 'findByIdDepartamento']);
    Route::post('addDepartamento', [DepartamentoController::class, 'addDepartamento']);
    Route::post('editDepartamento/{id}', [DepartamentoController::class, 'editDepartamento']);
    Route::post('activarDepartamento/{id}', [DepartamentoController::class, 'activarDepartamento']);   // { activo? }; sin ella, alterna
    Route::delete('deleteDepartamento/{id}', [DepartamentoController::class, 'deleteDepartamento']);   // a la papelera

    // El árbol: la rejilla trae el árbol entero y se mueve arrastrando
    Route::get('arbolDepartamentos', [DepartamentoController::class, 'arbolDepartamentos']);           // ?activos=1 para sólo los activos
    Route::post('moverDepartamento/{id}', [DepartamentoController::class, 'moverDepartamento']);       // { padre_id, antes_de }

    // Papelera de reciclaje (borrado lógico: deleteDepartamento manda a la papelera)
    Route::get('papelera', [DepartamentoController::class, 'papelera']);
    Route::post('restaurarDepartamentos', [DepartamentoController::class, 'restaurarDepartamentos']); // { ids: [...] }
    Route::post('eliminarDefinitivo', [DepartamentoController::class, 'eliminarDefinitivo']);         // { ids: [...] }
    Route::delete('vaciarPapelera', [DepartamentoController::class, 'vaciarPapelera']);
});

// EMPLEADOS
Route::group([
    'prefix' => 'empleado',
], function () {
    Route::get('allEmpleados', [EmpleadoController::class, 'allEmpleados'])->middleware(['jwt.auth', 'usuario.activo']);        // paginado
    Route::get('listEmpleados', [EmpleadoController::class, 'listEmpleados'])->middleware(['jwt.auth', 'usuario.activo']);      // lista simple: ?activos=0
    Route::get('findByIdEmpleado/{id}', [EmpleadoController::class, 'findByIdEmpleado'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('addEmpleado', [EmpleadoController::class, 'addEmpleado'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('editEmpleado/{id}', [EmpleadoController::class, 'editEmpleado'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('activarEmpleado/{id}', [EmpleadoController::class, 'activarEmpleado'])->middleware(['jwt.auth', 'usuario.activo']);   // { activo? }; sin ella, alterna
    Route::delete('deleteEmpleado/{id}', [EmpleadoController::class, 'deleteEmpleado'])->middleware(['jwt.auth', 'usuario.activo']); // a la papelera

    // Papelera de reciclaje: restaurar se puede deshacer, borrar de verdad no
    // (eso pide el permiso «vaciar», que se comprueba en el controlador)
    Route::get('papelera', [EmpleadoController::class, 'papelera'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('restaurar', [EmpleadoController::class, 'restaurar'])->middleware(['jwt.auth', 'usuario.activo']);                   // { ids: [...] }
    Route::post('eliminarDefinitivo', [EmpleadoController::class, 'eliminarDefinitivo'])->middleware(['jwt.auth', 'usuario.activo']); // { ids: [...] }
    Route::delete('vaciarPapelera', [EmpleadoController::class, 'vaciarPapelera'])->middleware(['jwt.auth', 'usuario.activo']);
    // Dónde trabaja: de aquí sale el perímetro que se le exige al marcar
    Route::post('asignarSucursal/{id}', [EmpleadoController::class, 'asignarSucursal'])->middleware(['jwt.auth', 'usuario.activo']);  // { sucursal_id }
    Route::post('addImagen', [EmpleadoController::class, 'addImagen'])->middleware(['jwt.auth', 'usuario.activo']);            // { EmpleadoId, imagen_file }
    Route::get('listContactos/{id}', [EmpleadoController::class, 'listContactos'])->middleware(['jwt.auth', 'usuario.activo']);        // contactos de emergencia
    Route::post('guardarContactos/{id}', [EmpleadoController::class, 'guardarContactos'])->middleware(['jwt.auth', 'usuario.activo']); // { contactos: [...] } sincroniza

    // Las OTRAS sucursales donde se le acepta la marcación (la suya va en la ficha)
    Route::get('listSucursalesMarcacion/{id}', [EmpleadoController::class, 'listSucursalesMarcacion'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('guardarSucursalesMarcacion/{id}', [EmpleadoController::class, 'guardarSucursalesMarcacion'])->middleware(['jwt.auth', 'usuario.activo']); // { sucursales: [...] } sincroniza
    Route::post('guardarUbicacion/{id}', [EmpleadoController::class, 'guardarUbicacion'])->middleware(['jwt.auth', 'usuario.activo']);  // los datos que trae el mapa
    Route::post('addFotoUbicacion', [EmpleadoController::class, 'addFotoUbicacion'])->middleware(['jwt.auth', 'usuario.activo']);            // { EmpleadoId, campo: mapa|casa, imagen_file }

    // Públicas (las usa <img src>), como getImagenUsuario
    Route::get('getImagenEmpleado/{id}', [EmpleadoController::class, 'getImagenEmpleado']);
    Route::get('getFotoUbicacion/{id}/{campo}', [EmpleadoController::class, 'getFotoUbicacion']);
});

// MARCACIONES (entradas / salidas)
Route::group([
    'prefix' => 'marcacion',
], function () {
    Route::get('allMarcaciones', [MarcacionController::class, 'allMarcaciones'])->middleware(['jwt.auth', 'usuario.activo']);        // ?page&per_page&search&desde&hasta&empleado_id&tipo&origen
    Route::get('findByIdMarcacion/{id}', [MarcacionController::class, 'findByIdMarcacion'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::get('resumen', [MarcacionController::class, 'resumen'])->middleware(['jwt.auth', 'usuario.activo']);                      // horas por empleado y día
    Route::post('registrar', [MarcacionController::class, 'registrar'])->middleware(['jwt.auth', 'usuario.activo']);                  // kiosco facial
    // Desde el celular del propio empleado: el empleado sale de la sesión
    Route::get('miEmpleado', [MarcacionController::class, 'miEmpleado'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::get('misMarcaciones', [MarcacionController::class, 'misMarcaciones'])->middleware(['jwt.auth', 'usuario.activo']);  // ?page&per_page&desde&hasta&tipo
    Route::post('registrarMia', [MarcacionController::class, 'registrarMia'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::post('addMarcacion', [MarcacionController::class, 'addMarcacion'])->middleware(['jwt.auth', 'usuario.activo']);            // alta manual
    Route::post('editMarcacion/{id}', [MarcacionController::class, 'editMarcacion'])->middleware(['jwt.auth', 'usuario.activo']);
    Route::delete('deleteMarcacion/{id}', [MarcacionController::class, 'deleteMarcacion'])->middleware(['jwt.auth', 'usuario.activo']);
    // Pública (la usa <img src>)
    Route::get('getImagenMarcacion/{id}', [MarcacionController::class, 'getImagenMarcacion']);
});

// ROSTROS (plantillas faciales de los empleados)
Route::group([
    'prefix' => 'rostro', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allRostros', [RostroController::class, 'allRostros']);                                   // ?empleado_id
    Route::post('addRostro', [RostroController::class, 'addRostro']);                                    // { empleado_id, descriptores: [[128]…], origen }
    Route::delete('deleteRostro/{id}', [RostroController::class, 'deleteRostro']);
    Route::delete('deleteRostrosEmpleado/{empleadoId}', [RostroController::class, 'deleteRostrosEmpleado']);
});
