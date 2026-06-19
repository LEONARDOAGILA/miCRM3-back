<?php

namespace App\Helpers;

class UserAgentHelper
{
    public static function parse($userAgent)
    {
        $data = [
            'navegador' => 'Desconocido',
            'sistema_operativo' => 'Desconocido',
            'dispositivo' => 'Desconocido'
        ];
        
        // Detectar navegador
        if (strpos($userAgent, 'Chrome') !== false) {
            $data['navegador'] = 'Chrome';
        } elseif (strpos($userAgent, 'Firefox') !== false) {
            $data['navegador'] = 'Firefox';
        } elseif (strpos($userAgent, 'Safari') !== false) {
            $data['navegador'] = 'Safari';
        } elseif (strpos($userAgent, 'Edge') !== false) {
            $data['navegador'] = 'Edge';
        } elseif (strpos($userAgent, 'Opera') !== false) {
            $data['navegador'] = 'Opera';
        } elseif (strpos($userAgent, 'MSIE') !== false || strpos($userAgent, 'Trident') !== false) {
            $data['navegador'] = 'Internet Explorer';
        }
        
        // Detectar sistema operativo
        if (strpos($userAgent, 'Windows') !== false) {
            $data['sistema_operativo'] = 'Windows';
        } elseif (strpos($userAgent, 'Mac') !== false) {
            $data['sistema_operativo'] = 'macOS';
        } elseif (strpos($userAgent, 'Linux') !== false) {
            $data['sistema_operativo'] = 'Linux';
        } elseif (strpos($userAgent, 'Android') !== false) {
            $data['sistema_operativo'] = 'Android';
        } elseif (strpos($userAgent, 'iOS') !== false || strpos($userAgent, 'iPhone') !== false || strpos($userAgent, 'iPad') !== false) {
            $data['sistema_operativo'] = 'iOS';
        }
        
        // Detectar dispositivo
        if (strpos($userAgent, 'Mobile') !== false || strpos($userAgent, 'Android') !== false) {
            $data['dispositivo'] = 'Móvil';
        } elseif (strpos($userAgent, 'iPad') !== false) {
            $data['dispositivo'] = 'Tablet';
        } else {
            $data['dispositivo'] = 'Escritorio';
        }
        
        return $data;
    }
}