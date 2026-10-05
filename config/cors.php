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
    'paths' => ['api/*','web/*', 'auth/*', 'config/*', 'reporte/*', 'rh/*', 'ventas/*', 'crm/*', 'broadcasting/auth'   , 'sanctum/csrf-cookie'],





    'allowed_methods' => ['*'],

    'allowed_origins' => ['*'],
    //'allowed_origins' => ['https://crm.almespana.com.ec', 'http://localhost:4200'],

    'allowed_origins_patterns' => [],

    //'allowed_headers' => ['Authorization', 'Content-Type', 'Custom-Header', '*'],
    'allowed_headers' => ['*'],

    'exposed_headers' => ['Content-Disposition', 'X-Zip-Ficheros', 'X-Zip-Enlaces', 'X-Zip-Omitidos'],   // nombre de fichero y resumen del zip en descargas

    /*
     * Cuánto puede el navegador guardarse la respuesta del preflight.
     *
     * Estaba en 0, o sea «no te lo guardes»: como el front y la API están en
     * origenes distintos y toda peticion lleva Authorization, el navegador
     * mandaba un OPTIONS ANTES DE CADA GET. Son el doble de idas y vueltas
     * contra un servidor que las atiende de una en una.
     *
     * Con 24 horas el preflight se pide una vez por url y metodo. Ojo: la
     * cache va por url completa, asi que no ahorra la primera visita a un
     * cliente, pero si todas las siguientes.
     */
    'max_age' => 86400,

    //'supports_credentials' => false,
    'supports_credentials' => true,
];
