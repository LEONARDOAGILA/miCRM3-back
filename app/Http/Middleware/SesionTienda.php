<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Tymon\JWTAuth\Facades\JWTAuth;

/**
 * LA SESIÓN DE UN CLIENTE DE LA TIENDA.
 *
 * El hermano de `usuario.activo`, para la otra puerta. Aquél deja entrar al
 * personal al CRM y rechaza a las cuentas de la web; éste hace lo contrario.
 *
 * MIRA DOS COSAS, Y LAS DOS HACEN FALTA:
 *
 *   · que el usuario sea de la tienda (`type_user = 4`), porque el token lo
 *     firma el mismo JWT para todos;
 *   · y que el token se haya emitido POR LA PUERTA DE LA TIENDA (el dato
 *     `ambito` = «tienda»), para que el token de un empleado no sirva aquí
 *     aunque algún día alguien le ponga el tipo equivocado.
 *
 * LO QUE NO MIRA, a propósito: el HORARIO. El del CRM cierra fuera de hora, y
 * una tienda en línea no cierra. Tampoco cuenta sesiones: el tope de 44 es
 * una herramienta para vigilar al personal, no para un cliente con el
 * teléfono y el computador abiertos.
 *
 * EL CORREO SIN CONFIRMAR NO BLOQUEA LA ENTRADA: se puede entrar, mirar y
 * llenar el carrito. Lo que no se puede es terminar un pedido, y eso lo mira
 * quien lo cobre, no este middleware.
 */
class SesionTienda
{
    public function handle(Request $request, Closure $next)
    {
        try {
            $user = JWTAuth::parseToken()->authenticate();

            if (!$user || !$user->isactive || $user->deleted_at) {
                return response()->json(['message' => 'Tu cuenta no está disponible.'], 401);
            }

            if ((int) $user->type_user !== 4) {
                return response()->json(['message' => 'Esta cuenta no es de la tienda.'], 401);
            }

            $ambito = JWTAuth::parseToken()->getPayload()->get('ambito');
            if ($ambito !== 'tienda') {
                return response()->json(['message' => 'Inicia sesión en la tienda.'], 401);
            }

            return $next($request);

        } catch (\Exception $e) {
            // Token ausente, caducado o reventado: para la tienda es lo mismo
            return response()->json(['message' => 'Inicia sesión para continuar.'], 401);
        }
    }
}
