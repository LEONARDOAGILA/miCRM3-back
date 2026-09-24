<?php

namespace App\Http\Controllers\config;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use App\Events\NotificacionRecibida;

/**
 * Notificaciones (core.notificaciones): avisos breves que cuelgan de la
 * campana de cada usuario.
 *
 * Mismo esquema que el resto del sistema: la lógica vive en las funciones
 * core.fn_notificaciones_*; aquí se valida la entrada, se avisa por websocket
 * y se traduce la respuesta.
 *
 *   -- Administración
 *   GET    config/notificacion/allNotificaciones      paginado: ?page&per_page&search&tipo
 *   GET    config/notificacion/findByIdNotificacion/{id}
 *   GET    config/notificacion/destinatarios/{id}     quién la recibió y quién la leyó
 *   POST   config/notificacion/enviarNotificacion     { titulo, mensaje, tipo, url, usuarios[], grupos[], todos }
 *   DELETE config/notificacion/deleteNotificacion/{id}
 *
 *   -- La campana del usuario
 *   GET    config/notificacion/misNotificaciones      ?solo_no_leidas&limite&desplazamiento
 *   GET    config/notificacion/contador
 *   POST   config/notificacion/marcarLeidas           { ids[] }  (sin ids = todas)
 *   POST   config/notificacion/archivar               { ids[] }  (sin ids = todas)
 *
 * Al enviarla se resuelven los grupos y queda una fila por destinatario, así
 * que cada usuario tiene su propio «leída» y su propia campana.
 */
class NotificacionController extends Controller
{
    use ApiResponder;

    /** Pusher no admite más de 100 canales por evento. */
    private const CANALES_POR_ENVIO = 90;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // faltan datos
        'P0010' => 422,   // valor no admitido
        'P0013' => 404,   // no existe
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

    /** Usuario autenticado, en el orden que esperan las funciones. */
    private function auditoria(Request $request): array
    {
        $u = auth('api')->user();
        return [
            $u->id ?? null,
            $u->login_user ?? null,
            trim(($u->name ?? '') . ' ' . ($u->surname ?? '')) ?: null,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid(),
        ];
    }

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    /** Cuerpo: JSON plano o el envoltorio { json: "…" } de los FormData. */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    /** Array de PostgreSQL a partir de una lista de ids. */
    private function arrayPg(?array $ids): ?string
    {
        if (!$ids) { return null; }
        return '{' . implode(',', array_map('intval', $ids)) . '}';
    }

    // ================================================================
    // ADMINISTRACIÓN
    // ================================================================

    public function allNotificaciones(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT core.fn_notificaciones_listar_paginado(?, ?, ?, ?::TEXT) as result',
                [
                    (int) $request->input('page', 1),
                    (int) $request->input('per_page', 15),
                    $request->input('search', ''),
                    $request->input('tipo', 'TODOS'),
                ]
            );
            return $this->successResponse(json_decode($result->result, true), 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allNotificaciones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar las notificaciones', 500);
        }
    }

    public function findByIdNotificacion($id)
    {
        try {
            $result = DB::selectOne('SELECT core.fn_notificaciones_obtener(?::BIGINT) as result', [(int) $id]);
            $datos = json_decode($result->result, true);
            return $datos['success']
                ? $this->successResponse($datos['data'], $datos['message'])
                : $this->errorResponse($datos['message'], 404);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdNotificacion', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener la notificación', 500);
        }
    }

    public function destinatarios($id)
    {
        try {
            $result = DB::selectOne('SELECT core.fn_notificaciones_destinatarios(?::BIGINT) as result', [(int) $id]);
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en destinatarios de notificación', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener los destinatarios', 500);
        }
    }

    /**
     * Envía la notificación y avisa por websocket a quien esté conectado.
     *
     * Los destinatarios se resuelven en la base (usuarios sueltos, grupos con
     * sus subgrupos, o todo el mundo) y quedan como filas, cada una con su
     * propio «leída».
     */
    public function enviarNotificacion(Request $request)
    {
        $datos = $this->datosDe($request);

        $validator = Validator::make($datos, [
            'titulo'                 => 'required|string|max:200',
            'mensaje'                => 'nullable|string|max:2000',
            'tipo'                   => 'nullable|in:INFO,EXITO,AVISO,ERROR',
            'icono'                  => 'nullable|string|max:60',
            'url'                    => 'nullable|string|max:500',
            'url_texto'              => 'nullable|string|max:60',
            'caduca_at'              => 'nullable|date',
            'usuarios'               => 'nullable|array',
            'usuarios.*'             => 'integer',
            'grupos'                 => 'nullable|array',
            'grupos.*.grupo_id'      => 'required_with:grupos|integer',
            'todos'                  => 'nullable|boolean',
        ], [
            'titulo.required' => 'El título de la notificación es obligatorio',
            'titulo.max'      => 'El título no puede pasar de 200 caracteres',
            'tipo.in'         => 'El tipo debe ser INFO, EXITO, AVISO o ERROR',
            'caduca_at.date'  => 'La fecha de caducidad no es válida',
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        // Quien envía a mano nunca marca el origen: eso lo pone el sistema
        $datos['origen'] = 'MANUAL';

        DB::beginTransaction();
        try {
            $result = DB::selectOne(
                'SELECT core.fn_notificaciones_enviar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode($datos)], $this->auditoria($request))
            );
            $respuesta = json_decode($result->result, true);
            DB::commit();

            $this->avisarPorWebsocket($respuesta['data'] ?? []);

            return $this->successResponse($respuesta['data'], $respuesta['message']);
        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error al enviar la notificación', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al enviar la notificación', 500);
        }
    }

    /** El timbre para los que están con la sesión abierta. */
    private function avisarPorWebsocket(array $data): void
    {
        $n = $data['notificacion'] ?? null;
        $ids = array_map('intval', $data['ids_usuarios'] ?? []);
        if (!$n || !$ids) { return; }

        foreach (array_chunk($ids, self::CANALES_POR_ENVIO) as $tanda) {
            event(new NotificacionRecibida(
                (int) $n['id'],
                (string) $n['titulo'],
                (string) ($n['tipo'] ?? 'INFO'),
                $tanda
            ));
        }
    }

    public function deleteNotificacion(Request $request, $id)
    {
        DB::beginTransaction();
        try {
            $result = DB::selectOne(
                'SELECT core.fn_notificaciones_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $respuesta = json_decode($result->result, true);
            DB::commit();
            return $this->successResponse($respuesta['data'], $respuesta['message']);
        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error al eliminar la notificación', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al eliminar la notificación', 500);
        }
    }

    // ================================================================
    // LA CAMPANA DEL USUARIO
    // ================================================================

    public function misNotificaciones(Request $request)
    {
        try {
            $u = auth('api')->user();
            $result = DB::selectOne(
                'SELECT core.fn_notificaciones_mias(?::BIGINT, ?::BOOLEAN, ?::INTEGER, ?::INTEGER) as result',
                [
                    $u->id ?? null,
                    filter_var($request->input('solo_no_leidas', false), FILTER_VALIDATE_BOOLEAN),
                    (int) $request->input('limite', 20),
                    (int) $request->input('desplazamiento', 0),
                ]
            );
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en misNotificaciones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener las notificaciones', 500);
        }
    }

    public function contador()
    {
        try {
            $u = auth('api')->user();
            $result = DB::selectOne('SELECT core.fn_notificaciones_contador(?::BIGINT) as result', [$u->id ?? null]);
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en el contador de notificaciones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al contar las notificaciones', 500);
        }
    }

    /** Sin ids, marca todas las del usuario. */
    public function marcarLeidas(Request $request)
    {
        try {
            $u = auth('api')->user();
            $ids = $this->arrayPg($this->datosDe($request)['ids'] ?? null);
            $result = DB::selectOne(
                'SELECT core.fn_notificaciones_marcar_leidas(?::BIGINT, ?::BIGINT[]) as result',
                [$u->id ?? null, $ids]
            );
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al marcar notificaciones como leídas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al marcar las notificaciones', 500);
        }
    }

    /** Sin ids, quita de la campana todas las del usuario. */
    public function archivar(Request $request)
    {
        try {
            $u = auth('api')->user();
            $ids = $this->arrayPg($this->datosDe($request)['ids'] ?? null);
            $result = DB::selectOne(
                'SELECT core.fn_notificaciones_archivar(?::BIGINT, ?::BIGINT[]) as result',
                [$u->id ?? null, $ids]
            );
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al archivar notificaciones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al quitar las notificaciones', 500);
        }
    }
}
