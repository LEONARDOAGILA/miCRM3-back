<?php

// LPAA - AUDITORIA MANUAL - REGISTROS EN CADA TABLA
namespace App\Services;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

class AuditoriaService
{
    public function registrar(
        string $tabla,
        int $registroId,
        string $operacion,
        ?array $datosAnteriores = null,
        ?array $datosNuevos = null,
        ?int $usuarioId = null,
        ?string $usuarioLogin = null,
        ?string $usuarioNombre = null,
        ?string $ip = null,
        ?string $userAgent = null,
        ?string $requestId = null,
        ?string $modulo = null
    ) {
        $ip = $ip ?? request()->ip();
        $userAgent = $userAgent ?? request()->userAgent();
        $requestId = $requestId ?? (string) Str::uuid();

        if (!$usuarioId && auth()->check()) {
            $usuario = auth()->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? $usuario->email ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
        }

        DB::selectOne('SELECT auditoria.fn_registrar_evento(?, ?, ?, ?::jsonb, ?::jsonb, ?, ?, ?, ?::inet, ?, ?::uuid, ?)', [
            $tabla,
            $registroId,
            $operacion,
            $datosAnteriores ? json_encode($datosAnteriores) : null,
            $datosNuevos ? json_encode($datosNuevos) : null,
            $usuarioId,
            $usuarioLogin,
            $usuarioNombre,
            $ip,
            $userAgent,
            $requestId,
            $modulo ?? $tabla
        ]);
    }
}