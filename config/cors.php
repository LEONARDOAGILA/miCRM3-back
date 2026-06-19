<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Cross-Origin Resource Sharing (CORS) Configuration
    |--------------------------------------------------------------------------
    |
    | Here you may configure your settings for cross-origin resource sharing
    | or "CORS". This determines what cross-origin operations may execute
    | in web browsers. You are free to adjust these settings as needed.
    |
    | To learn more: https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS
    |
    */

    //lpaa -> configura todas las rutas para evitar error de cors
    'paths' => ['api/*','web/*', 'auth/*', 'config/*', 'reporte/*', 'crm/*', 'broadcasting/auth'   , 'sanctum/csrf-cookie'],





    'allowed_methods' => ['*'],

    'allowed_origins' => ['*'],
    //'allowed_origins' => ['https://crm.almespana.com.ec', 'http://localhost:4200'],

    'allowed_origins_patterns' => [],

    //'allowed_headers' => ['Authorization', 'Content-Type', 'Custom-Header', '*'],
    'allowed_headers' => ['*'],

    'exposed_headers' => [],

    'max_age' => 0,

    //'supports_credentials' => false,
    'supports_credentials' => true,
];
