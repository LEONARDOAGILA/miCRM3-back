<?php

namespace App\Providers;

use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Foundation\Support\Providers\RouteServiceProvider as ServiceProvider;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\Facades\Route;

class RouteServiceProvider extends ServiceProvider
{
    /**
     * The path to your application's "home" route.
     *
     * Typically, users are redirected here after authentication.
     *
     * @var string
     */
    public const HOME = '/home';

    /**
     * Define your route model bindings, pattern filters, and other route configuration.
     */
    public function boot(): void
    {

        // RateLimiter::for('api', function (Request $request) {
        //     return Limit::perMinute(10000)->by($request->user()?->id ?: $request->ip());
        // });

        //lpaa -> codigo que controla 10000 solicitudos por minuto y por usuario
        foreach (['api', 'auth', 'config', 'reporte'] as $key) {
            RateLimiter::for($key, function (Request $request) {
                return Limit::perMinute(10000)->by($request->user()?->id ?: $request->ip());
            });
        }

        /*
         * Limitador de INICIO DE SESIÓN.
         *
         * Los grupos de arriba permiten 10.000 peticiones por minuto, que sobre
         * /auth/login es fuerza bruta sin freno: 600.000 contraseñas por hora.
         * Aquí se aplica un límite propio, mucho más estricto.
         *
         * Son DOS límites a la vez:
         *
         *  - Por cuenta + IP (5/min): corta el ataque de diccionario contra un
         *    usuario concreto. Se incluye la IP a propósito: con la cuenta sola,
         *    cualquiera podría dejar fuera a un usuario legítimo fallando
         *    adrede sus intentos (denegación de servicio por bloqueo).
         *
         *  - Por IP (20/min): corta el barrido de muchas cuentas desde un mismo
         *    origen, que el límite anterior no ve porque cambia de usuario.
         *
         * 5 intentos por minuto son de sobra para una persona y bajan el techo
         * del atacante de 600.000 a 300 intentos por hora.
         */
        RateLimiter::for('login', function (Request $request) {
            $cuenta = strtolower(trim((string) $request->input('login_user')));

            return [
                Limit::perMinute(5)->by('login:' . $cuenta . '|' . $request->ip()),
                Limit::perMinute(20)->by('login-ip:' . $request->ip()),
            ];
        });

        /*
         * Limitador de RECUPERACIÓN DE CONTRASEÑA.
         *
         * Más estricto todavía porque el código de recuperación es de 6 dígitos
         * (un millón de combinaciones) y seguridad.fn_usuarios_verificar_recuperacion
         * no lleva contador de intentos fallidos: sin este freno el código se
         * revienta por fuerza bruta en minutos.
         *
         * El límite por hora va SOLO por cuenta para que no baste con cambiar de
         * IP; aquí el bloqueo temporal es preferible a que entren.
         */
        RateLimiter::for('recuperacion', function (Request $request) {
            $cuenta = strtolower(trim((string) $request->input('login_user')));

            return [
                Limit::perMinute(5)->by('rec-ip:' . $request->ip()),
                Limit::perHour(10)->by('rec-cuenta:' . $cuenta),
            ];
        });


        //lpaa -> rutas como los modulos
        $this->routes(function () {

            Route::prefix('api')
                ->middleware('api')
                ->namespace($this->namespace)
                ->group(base_path('routes/api.php'));


            Route::prefix('auth')
                ->middleware('auth')
                ->namespace($this->namespace)
                ->group(base_path('routes/auth.php'));

            Route::prefix('config')
                ->middleware('config')
                ->namespace($this->namespace)
                ->group(base_path('routes/config.php'));

            Route::prefix('reporte')
                ->middleware('reporte')
                ->namespace($this->namespace)
                ->group(base_path('routes/reporte.php'));


            Route::middleware('web')
                ->group(base_path('routes/web.php'));




        });
    }
}


            // Route::middleware('api')
            //     ->prefix('api')
            //     ->group(base_path('routes/api.php'));
