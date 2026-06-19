<?php

use Illuminate\Support\Facades\Route;
use App\Events\TestEvent;

/*
|--------------------------------------------------------------------------
| Web Routes
|--------------------------------------------------------------------------
|
| Here is where you can register web routes for your application. These
| routes are loaded by the RouteServiceProvider and all of them will
| be assigned to the "web" middleware group. Make something great!
|
*/

Route::get('/', function () {
    return view('welcome');
});

Route::get('/test-websocket', function () {
    event(new TestEvent('¡Hola desde WebSockets!'));
    return "Evento enviado";
});

Route::get('/websocket-dashboard', function () {
    return view('websocket-dashboard');
});

