<?php

namespace App\Events;

use Illuminate\Broadcasting\Channel;
use Illuminate\Broadcasting\InteractsWithSockets;
use Illuminate\Contracts\Broadcasting\ShouldBroadcast;
use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Aviso de que a alguien le acaba de entrar una notificación.
 *
 * Va por el canal propio de cada destinatario —`notificaciones.{user_id}`— y
 * lleva sólo lo justo para pintar la campana sin pedir nada: el id, el título
 * y el tipo. El contenido completo, y sobre todo el contador, los vuelve a
 * pedir la pantalla con su token, que es quien decide qué le toca ver.
 */
class NotificacionRecibida implements ShouldBroadcast
{
    use Dispatchable, InteractsWithSockets, SerializesModels;

    public int $notificacionId;
    public string $titulo;
    public string $tipo;

    /** Canales a los que va: uno por destinatario. */
    private array $canales;

    /**
     * @param int[] $userIds destinatarios que deben recibir el aviso
     */
    public function __construct(int $notificacionId, string $titulo, string $tipo, array $userIds)
    {
        $this->notificacionId = $notificacionId;
        $this->titulo = $titulo;
        $this->tipo = $tipo;
        $this->canales = array_map(
            static fn ($id) => new Channel('notificaciones.' . (int) $id),
            array_values(array_unique($userIds))
        );
    }

    /**
     * @return array<int, \Illuminate\Broadcasting\Channel>
     */
    public function broadcastOn(): array
    {
        return $this->canales;
    }
}
