<?php

namespace App\Events;

use Illuminate\Broadcasting\Channel;
use Illuminate\Broadcasting\InteractsWithSockets;
use Illuminate\Contracts\Broadcasting\ShouldBroadcast;
use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Aviso de que hay un boletín para ver, sin esperar a que el usuario vuelva a
 * entrar al sistema.
 *
 * Va por un canal propio de cada destinatario —`boletines.{user_id}`— y lleva
 * sólo el id y el título: es un timbre, no el contenido. Al recibirlo, la
 * pantalla vuelve a pedir sus boletines con su token, y es el servidor quien
 * decide qué le toca ver; así el canal, que es público, no filtra nada.
 */
class BoletinPublicado implements ShouldBroadcast
{
    use Dispatchable, InteractsWithSockets, SerializesModels;

    public int $boletinId;
    public string $titulo;

    /** Canales a los que va: uno por destinatario. */
    private array $canales;

    /**
     * @param int[] $userIds destinatarios que deben recibir el aviso
     */
    public function __construct(int $boletinId, string $titulo, array $userIds)
    {
        $this->boletinId = $boletinId;
        $this->titulo = $titulo;
        $this->canales = array_map(
            static fn ($id) => new Channel('boletines.' . (int) $id),
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
