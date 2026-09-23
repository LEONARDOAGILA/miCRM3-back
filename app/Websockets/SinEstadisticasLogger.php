<?php

namespace App\Websockets;

use BeyondCode\LaravelWebSockets\Statistics\Logger\StatisticsLogger;
use Ratchet\ConnectionInterface;

/**
 * Registro de estadísticas que no registra nada.
 *
 * El que trae el paquete (HttpStatisticsLogger) manda cada minuto lo que
 * lleva contado a una ruta del propio Laravel, que lo guarda en la tabla
 * `websockets_statistics_entries`. Ese es el único motivo por el que el
 * servidor de websockets necesita la base de datos, y en este proyecto la
 * tabla ni siquiera existe: cada envío terminaba en una excepción en el log.
 *
 * Con este no hay ni petición ni tabla ni conexión. Si algún día se quiere el
 * panel con gráficas, se publica la migración del paquete y se vuelve a
 * HttpStatisticsLogger en config/websockets.php.
 */
class SinEstadisticasLogger implements StatisticsLogger
{
    public function webSocketMessage(ConnectionInterface $connection)
    {
        //
    }

    public function apiMessage($appId)
    {
        //
    }

    public function connection(ConnectionInterface $connection)
    {
        //
    }

    public function disconnection(ConnectionInterface $connection)
    {
        //
    }

    public function save()
    {
        //
    }
}
