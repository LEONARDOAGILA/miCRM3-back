<?php

// LPAA - CONTROL DE SESIONES ACTIVAS - CIERRA SESIONES ACTIVAS LUEGO DE 60 MINUTOS

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;

class CleanExpiredSessions extends Command
{
    protected $signature = 'sessions:clean-expired';
    protected $description = 'Limpia sesiones expiradas por inactividad';

    public function handle()
    {
        // Sesiones inactivas por más de 60 minutos
        $deleted = DB::delete(
            "DELETE FROM seguridad.sesiones_activas 
             WHERE last_activity < NOW() - INTERVAL '60 minutes'"
        );
        
        $this->info("Se limpiaron {$deleted} sesiones expiradas");
    }
}
