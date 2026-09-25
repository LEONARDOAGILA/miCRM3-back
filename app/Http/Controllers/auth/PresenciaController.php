<?php

namespace App\Http\Controllers\auth;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use App\Events\PresenciaCambiada;

/**
 * Presencia: el «En línea / Fuera de línea» de la cabecera.
 *
 * Dos cosas distintas que se cruzan (ver seguridad.presencia):
 *   · el estado que el usuario ELIGE publicar
 *   · el latido, que dice si de verdad tiene el CRM abierto ahora
 *
 *   GET  auth/presencia/mia           lo mío, con el estado ya resuelto
 *   POST auth/presencia/cambiar       { estado, mensaje? }
 *   POST auth/presencia/latido        «sigo aquí», cada pocos minutos
 *   POST auth/presencia/desconectar   al cerrar sesión
 *   GET  auth/presencia/conectados    quién está ahora  (?todos=1 para la lista entera)
 *
 * El latido NO se difunde por websocket: son muchos y no cambian nada que
 * nadie esté mirando. Sólo se avisa cuando el estado cambia de verdad.
 */
class PresenciaController extends Controller
{
    use ApiResponder;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta el usuario
        'P0010' => 422,   // estado no admitido
        'P0013' => 404,   // el usuario no existe
    ];

    public function __construct()
    {
        $this->middleware('auth:api');
    }

    /** Convierte el error de una función PL/pgSQL en [mensaje, código HTTP]. */
    private function traducirErrorPostgres(QueryException $e): array
    {
        $sqlState = $e->errorInfo[0] ?? null;
        if (!isset(self::ERRORES_NEGOCIO[$sqlState])) {
            return ['Ocurrió un error al procesar la solicitud', 500];
        }
        $mensaje = $e->errorInfo[2] ?? $e->getMessage();
        $mensaje = preg_replace('/^.*?ERROR:\s*/s', '', $mensaje);
        $mensaje = preg_split('/\R\s*(CONTEXT|CONTEXTO|DETALLE|DETAIL|HINT):/', $mensaje)[0];
        return [trim($mensaje), self::ERRORES_NEGOCIO[$sqlState]];
    }

    private function usuarioId(): ?int
    {
        return auth('api')->user()->id ?? null;
    }

    /** Cuerpo: JSON plano o el envoltorio { json: "…" } de los FormData. */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    // ================================================================
    // LO MÍO
    // ================================================================

    public function mia()
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_presencia_mia(?::BIGINT) as result', [$this->usuarioId()]);
            $datos = json_decode($result->result, true);
            return $datos['success']
                ? $this->successResponse($datos['data'], $datos['message'])
                : $this->errorResponse($datos['message'], 404);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en presencia mia', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener tu estado', 500);
        }
    }

    /**
     * Cambia el estado y avisa a los demás por websocket.
     *
     * Lo que se difunde es el estado YA RESUELTO: quien se pone invisible sale
     * como desconectado, y nadie se entera de que eligió esconderse.
     */
    public function cambiar(Request $request)
    {
        $datos = $this->datosDe($request);

        $validator = Validator::make($datos, [
            'estado'  => 'required|string|in:DISPONIBLE,OCUPADO,NO_MOLESTAR,INVISIBLE',
            'mensaje' => 'nullable|string|max:80',
        ], [
            'estado.required' => 'Indique el estado',
            'estado.in'       => 'El estado debe ser DISPONIBLE, OCUPADO, NO_MOLESTAR o INVISIBLE',
            'mensaje.max'     => 'La nota no puede pasar de 80 caracteres',
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        DB::beginTransaction();
        try {
            $result = DB::selectOne(
                'SELECT seguridad.fn_presencia_cambiar(?::BIGINT, ?::TEXT, ?::TEXT) as result',
                [$this->usuarioId(), $datos['estado'], $datos['mensaje'] ?? null]
            );
            $respuesta = json_decode($result->result, true);
            DB::commit();

            $this->avisarPorWebsocket($this->usuarioId());

            return $this->successResponse($respuesta['data'], $respuesta['message']);
        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error al cambiar la presencia', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al cambiar tu estado', 500);
        }
    }

    /**
     * «Sigo aquí». Se llama cada pocos minutos desde el navegador.
     *
     * Es la llamada más repetida de todas, así que hace lo mínimo: una fila,
     * una columna y ningún aviso por websocket.
     */
    public function latido()
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_presencia_latido(?::BIGINT) as result', [$this->usuarioId()]);
            $respuesta = json_decode($result->result, true);
            return $this->successResponse($respuesta['data'], $respuesta['message']);
        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en el latido de presencia', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al registrar tu actividad', 500);
        }
    }

    /** Al cerrar sesión: deja de aparecer conectado sin esperar a que caduque. */
    public function desconectar()
    {
        try {
            $id = $this->usuarioId();
            DB::selectOne('SELECT seguridad.fn_presencia_desconectar(?::BIGINT) as result', [$id]);
            $this->avisarPorWebsocket($id);
            return $this->successResponse(null, 'Sesión marcada como cerrada');
        } catch (Exception $e) {
            sistemaLog('error', 'Error al desconectar la presencia', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al cerrar tu presencia', 500);
        }
    }

    /** Quién está ahora. Con ?todos=1 devuelve también a los desconectados. */
    public function conectados(Request $request)
    {
        try {
            $soloPresentes = !$request->boolean('todos');
            $result = DB::selectOne(
                'SELECT seguridad.fn_presencia_conectados(?::BOOLEAN) as result',
                [$soloPresentes]
            );
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al listar la presencia', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar quién está conectado', 500);
        }
    }

    /** El aviso a los demás: va por un único canal público. */
    private function avisarPorWebsocket(?int $userId): void
    {
        if (!$userId) { return; }

        try {
            $fila = DB::selectOne('SELECT seguridad.fn_presencia_json(?::BIGINT) as result', [$userId]);
            $datos = json_decode($fila->result, true);
            if (!$datos) { return; }

            event(new PresenciaCambiada(
                (int) $datos['user_id'],
                (string) $datos['login_user'],
                (string) $datos['efectivo'],
                $datos['mensaje'] ?? null
            ));
        } catch (Exception $e) {
            // Que no se caiga el cambio de estado por no poder avisar
            sistemaLog('warning', 'No se pudo avisar del cambio de presencia', ['message' => $e->getMessage()]);
        }
    }
}
