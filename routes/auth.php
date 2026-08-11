<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\auth\AuthController;

use App\Http\Controllers\auth\ProfileController;
use App\Http\Controllers\auth\MenuController;
use App\Http\Controllers\auth\EmailController;
use App\Http\Controllers\auth\UserController;
use App\Http\Controllers\auth\HorarioController;
use App\Http\Controllers\auth\AuditoriaController;




// AUTENTIFICACION
Route::group([
    //'prefix' => 'auth',
], function () {
    Route::post('/register', [AuthController::class, 'register'])->name('register');
    Route::post('/login', [AuthController::class, 'login'])->name('login');
    Route::post('/login_ecommerce', [AuthController::class, 'login_ecommerce'])->name('login_ecommerce');
    Route::post('/logout', [AuthController::class, 'logout'])->name('logout');
    Route::post('/refresh', [AuthController::class, 'refresh'])->name('refresh');
    Route::post('/me', [AuthController::class, 'me'])->name('me');

   
    // LPAA - CONTROL DE SESIONES ACTIVAS - RUTAS
    Route::get('/my-sessions', [AuthController::class, 'getMySessions']);
    Route::delete('/close-session/{id}', [AuthController::class, 'closeSession']);
    Route::post('/logout-all-others', [AuthController::class, 'logoutAllOtherSessions']);

    Route::delete('/close-inactive-sessions/{minutes?}', [AuthController::class, 'closeInactiveSessions']);

});





// PERFILES
Route::group([
    //'prefix' => 'profile',
    'prefix' => 'profile', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('allProfiles', [ProfileController::class, 'allProfiles']);
    Route::get('listProfiles', [ProfileController::class, 'listProfiles']);
    Route::get('findByIdProfile/{id}', [ProfileController::class, 'findByIdProfile']);
    Route::get('findByIdProfileAccess/{id}', [ProfileController::class, 'findByIdProfileAccess']);
    Route::get('findByProgramProfile/{profile}/{program}', [ProfileController::class, 'findByProgramProfile']);
    Route::get('getAppMenus/{id}', [ProfileController::class, 'getAppMenus']);


    Route::post('addProfile', [ProfileController::class, 'addProfile']);
    Route::post('editProfile/{id}', [ProfileController::class, 'editProfile']);
    Route::delete('deleteProfile/{id}', [ProfileController::class, 'deleteProfile']);
    Route::post('clonProfile', [ProfileController::class, 'clonProfile']);
});




// MENUS
Route::group([
    'prefix' => 'menu', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('send_email', [EmailController::class, 'send_email']);
    Route::get('allMenus', [MenuController::class, 'allMenus']);
    Route::get('getMenuTree', [MenuController::class, 'getMenuTree']);
    Route::get('findByIdMenu/{id}', [MenuController::class, 'findByIdMenu']);
    Route::post('addMenu', [MenuController::class, 'addMenu']);
    Route::post('editMenu/{id}', [MenuController::class, 'editMenu']);
    Route::delete('deleteMenu/{id}', [MenuController::class, 'deleteMenu']);
});




// USUARIOS
Route::group([
    'prefix' => 'user',
], function () {
    Route::get('allUsers', [UserController::class, 'allUsers'])->middleware(['jwt.auth', 'usuario.activo']); 
    Route::get('findByIdUser/{id}', [UserController::class, 'findByIdUser'])->middleware(['jwt.auth', 'usuario.activo']);     
    Route::get('listUsers', [UserController::class, 'listUsers'])->middleware(['jwt.auth', 'usuario.activo']); 
    Route::post('addUser', [UserController::class, 'addUser'])->middleware(['jwt.auth', 'usuario.activo']); 
    Route::post('editUser/{id}', [UserController::class, 'editUser'])->middleware(['jwt.auth', 'usuario.activo']); 
    Route::delete('deleteUser/{id}', [UserController::class, 'deleteUser'])->middleware(['jwt.auth', 'usuario.activo']); 
    Route::post('changePassword/{id}', [UserController::class, 'changePassword'])->middleware(['jwt.auth', 'usuario.activo']); 
    Route::post('changePasswordLogin/{id}', [UserController::class, 'changePasswordLogin'])->middleware(['jwt.auth', 'usuario.activo']); 

    Route::post('addImagen', [UserController::class, 'addImagen'])->middleware(['jwt.auth', 'usuario.activo']); 
    
    // Rutas públicas de recuperación (sin autenticación)
    Route::get('getImagenUsuario/{id}', [UserController::class, 'getImagenUsuario']); 
    Route::post('verificar-usuario-recuperacion', [UserController::class, 'verificarUsuarioRecuperacion']);
    Route::post('solicitar-recuperacion', [UserController::class, 'solicitarRecuperacion']);
    Route::post('verificar-recuperacion', [UserController::class, 'verificarRecuperacion']);   
    Route::post('cambiar-password-recuperacion', [UserController::class, 'cambiarPasswordRecuperacion']);


});





// HORARIOS
Route::group([
    'prefix' => 'horario', 'middleware' => ['jwt.auth', 'usuario.activo']
    //'prefix' => 'horario', 
], function () {
    Route::get('/allHorarios', [HorarioController::class, 'allHorarios']);
    Route::get('/listHorarios', [HorarioController::class, 'listHorarios']);
    Route::get('/getHorario/{id}', [HorarioController::class, 'getHorario']);
    Route::post('/addHorario', [HorarioController::class, 'addHorario']);
    Route::post('/editHorario/{id}', [HorarioController::class, 'editHorario']);
    Route::delete('/deleteHorario/{id}', [HorarioController::class, 'deleteHorario']);
});




// AUDITORIA
Route::group([
    'prefix' => 'auditoria', 'middleware' => ['jwt.auth', 'usuario.activo']
], function () {
    Route::get('all', [AuditoriaController::class, 'all']);
    Route::post('getByRecord/{tabla}/{id}', [AuditoriaController::class, 'getByRecord']);
    Route::get('getLatest/ultimos/{limit?}', [AuditoriaController::class, 'getLatest'])->where('limit', '[0-9]+');
});


