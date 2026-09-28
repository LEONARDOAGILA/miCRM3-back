<?php

namespace App\Http\Controllers\ventas;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use Exception;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;

/**
 * Las conversaciones de WhatsApp de los vendedores con sus clientes.
 *
 * Los mensajes llegan de un servicio aparte (miCRM3-wa) enlazado a la cuenta
 * de WhatsApp como un dispositivo más, que sólo escucha: ni envía ni
 * responde. Aquí se guardan y se atan al cliente por el número.
 *
 * El alta NO usa el token del usuario porque quien la llama es un servicio,
 * no una persona: va con una clave compartida en la cabecera X-WA-TOKEN
 * (WHATSAPP_TOKEN del .env). Lo demás sí es del usuario y va con jwt.auth.
 */
class WhatsappController extends Controller
{
    use ApiResponder;

    /**
     * Alta de un mensaje. La llama el servicio, no el navegador.
     *
     * Es idempotente por wa_id: si el servicio se reconecta y reenvía lo
     * mismo, no se duplica.
     */
    public function recibir(Request $request)
    {
        $esperado = (string) config('services.whatsapp.token', env('WHATSAPP_TOKEN'));
        $recibido = (string) $request->header('X-WA-TOKEN', '');

        if ($esperado === '' || !hash_equals($esperado, $recibido)) {
            sistemaLog('warning', 'Mensaje de WhatsApp rechazado por token', ['ip' => $request->ip()]);
            return $this->errorResponse('No autorizado', 401);
        }

        $validator = Validator::make($request->all(), [
            'wa_id'      => 'required|string|max:120',
            'numero'     => 'required|string|max:30',
            'chat_id'    => 'nullable|string|max:80',
            'direccion'  => 'required|string|in:ENTRANTE,SALIENTE,entrante,saliente',
            'tipo'       => 'nullable|string|max:20',
            'cuerpo'     => 'nullable|string',
            'archivo'    => 'nullable|string|max:255',
            'autor'      => 'nullable|string|max:150',
            'vendedor'   => 'nullable|string|max:150',
            'enviado_at' => 'nullable|date',
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_whatsapp_guardar(?::JSONB) as result',
                [json_encode($validator->validated())]
            );
            $resultado = json_decode($result->result, true);

            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al guardar el mensaje de WhatsApp', ['message' => $e->getMessage()]);
            return $this->errorResponse('Ocurrió un error al guardar el mensaje', 500);
        }
    }

    /** Lo hablado con un cliente, del más viejo al más nuevo. */
    public function conversacion(Request $request, $clienteId)
    {
        try {
            $limite = (int) $request->query('limite', 200);
            $result = DB::selectOne(
                'SELECT ventas.fn_whatsapp_conversacion(?::BIGINT, ?::INTEGER) as result',
                [(int) $clienteId, $limite]
            );
            $resultado = json_decode($result->result, true);

            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en la conversación de WhatsApp', ['message' => $e->getMessage(), 'cliente_id' => $clienteId]);
            return $this->errorResponse('Ocurrió un error al obtener la conversación', 500);
        }
    }

    /** Cuántos mensajes hay y si quedó alguno sin responder. */
    public function resumen($clienteId)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_whatsapp_resumen(?::BIGINT) as result', [(int) $clienteId]);
            $resultado = json_decode($result->result, true);

            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            return $this->errorResponse('Ocurrió un error al obtener el resumen', 500);
        }
    }

    /** Números que escribieron y no casan con ningún cliente. */
    public function sinAsignar(Request $request)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_whatsapp_sin_asignar(?::INTEGER) as result', [(int) $request->query('limite', 50)]);
            $resultado = json_decode($result->result, true);

            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 500);
        } catch (Exception $e) {
            return $this->errorResponse('Ocurrió un error al obtener los pendientes', 500);
        }
    }

    /** Ata a un cliente todos los mensajes sueltos de un número. */
    public function asignar(Request $request)
    {
        $validator = Validator::make($request->all(), [
            'numero'     => 'required|string|max:30',
            'cliente_id' => 'required|integer',
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_whatsapp_asignar(?::VARCHAR, ?::BIGINT) as result',
                [$request->input('numero'), (int) $request->input('cliente_id')]
            );
            $resultado = json_decode($result->result, true);

            return $resultado['success']
                ? $this->successResponse($resultado['data'], $resultado['message'])
                : $this->errorResponse($resultado['message'], 422);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al asignar mensajes de WhatsApp', ['message' => $e->getMessage()]);
            return $this->errorResponse('Ocurrió un error al asignar los mensajes', 500);
        }
    }
}
