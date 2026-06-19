<?php

// LPAA - FUNION PARA Crear un helper o función global para loguear fácilmente
use Illuminate\Support\Facades\Log;

if (!function_exists('sistemaLog')) {
    function sistemaLog($level, $message, $context = [])
    {
        Log::channel('sistema')->$level($message, $context);
    }
}