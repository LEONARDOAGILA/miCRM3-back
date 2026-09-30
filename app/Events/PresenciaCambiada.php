<?php

namespace App\Events;

use Illuminate\Broadcasting\Channel;
use Illuminate\Broadcasting\InteractsWithSockets;
use Illuminate\Contracts\Broadcasting\ShouldBroadcast;
use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Aviso de que alguien cambió su estado: disponible, ocupado, se fue…
 *
 * Va por un único canal público, `presencia`, porque no es un dato reservado:
 * es justo lo que todos tienen que ver. Lleva el estado YA RESUELTO, así que
 * de quien se pone invisible sólo se dice que está desconectado.
 *
 * El latido no pasa por aquí: son muchos y no cambian nada que se vea.
 */
class PresenciaCambiada implements ShouldBroadcast
{
    use Dispatchable, InteractsWithSockets, SerializesModels;

    public int $userId;
    public string $loginUser;
    /** DISPONIBLE, OCUPADO, NO_MOLESTAR, AUSENTE o DESCONECTADO */
    public string $estado;
    public ?string $mensaje;

    public function __construct(int $userId, string $loginUser, string $estado, ?string $mensaje = null)
    {
        $this->userId = $userId;
        $this->loginUser = $loginUser;
        $this->estado = $estado;
        $this->mensaje = $mensaje;
    }

    /**
     * @return array<int, \Illuminate\Broadcasting\Channel>
     */
    public function broadcastOn(): array
    {
        return [new Channel('presencia')];
    }
}
