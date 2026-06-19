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
