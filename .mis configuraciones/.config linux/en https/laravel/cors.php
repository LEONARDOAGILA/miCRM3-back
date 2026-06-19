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

    'allowed_methods' => ['*'],    // permite GET, POST, PUT, DELETE, etc.
    'allowed_origins' => ['*'],    // permite todas las IPs/domains, o pon tu IP: 'http://192.168.254.15'
    'allowed_origins_patterns' => [],
    'allowed_headers' => ['*'],
    'exposed_headers' => [],
    'max_age' => 0,
    'supports_credentials' => false,
    
];
