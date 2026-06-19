<?php

use Illuminate\Support\Facades\Route;
use App\Events\NewTrade;
//use App\Http\Controllers\auth\AuthController;



/*
|--------------------------------------------------------------------------
| API Routes
|--------------------------------------------------------------------------
|
| Here is where you can register API routes for your application. These
| routes are loaded by the RouteServiceProvider and all of them will
| be assigned to the "api" middleware group. Make something great!
|
*/

// Route::middleware('auth:sanctum')->get('/user', function (Request $request) {
//     return $request->user();
// });

Route::group([
    //'middleware' => 'api',

    //'prefix' => 'auth'

], function ($router) {
    // Route::post('/register', [AuthController::class, 'register'])->name('register');
    // Route::post('/login', [AuthController::class, 'login'])->name('login');
    // Route::post('/login_ecommerce', [AuthController::class, 'login_ecommerce'])->name('login_ecommerce');
    // Route::post('/logout', [AuthController::class, 'logout'])->name('logout');
    // Route::post('/refresh', [AuthController::class, 'refresh'])->name('refresh');
    // Route::post('/me', [AuthController::class, 'me'])->name('me');
});


Route::post('/send-trade', function (Illuminate\Http\Request $request) {
    $message = $request->input('trade', 'Mensaje vacío');
    event(new NewTrade($message));  // 👈 Esto debe emitir
    return response()->json(['status' => 'ok', 'trade' => $message]);
});