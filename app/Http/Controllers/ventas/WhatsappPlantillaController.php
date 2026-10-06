<?php

namespace App\Http\Controllers\ventas;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Illuminate\Support\Facades\Validator;

/**
 * Las plantillas de WhatsApp: los mensajes que se ofrecen al escribirle a un
 * cliente.
 *
 * Estaban escritas en el código del front y ahora se mantienen desde la
 * pantalla, para poder cambiar el texto, añadir más y quitar las que no se
 * usan sin tocar un despliegue.
 *
 * Mismo esquema que CatalogoGestionController: la lógica vive en funciones
 * PL/pgSQL y aquí sólo se valida la entrada y se traduce el error.
 */
class WhatsappPlantillaController extends Controller
{
    use ApiResponder;

    /** SQLSTATE de las funciones → código HTTP. Los mismos que usa el catálogo. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,  // falta un dato obligatorio
        'P0013' => 404,  // no existe
        'P0020' => 409,  // repetido
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    public function __construct()
    {
        $this->middleware('auth:api');
    }

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

    private function auditoria(Request $request): array
    {
        $u = auth('api')->user();
        return [
            isset($u->id) ? (int) $u->id : null,
            $u->login_user ?? null,
            trim(($u->name ?? '') . ' ' . ($u->surname ?? '')) ?: null,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid(),
        ];
    }

    /** Cuerpo de la petición: JSON plano o el envoltorio { json: "…" } (FormData). */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    /**
     * Las plantillas.
     *
     * ?inactivos=0 devuelve sólo las activas, que es lo que pide el menú de
     * WhatsApp de gestión de clientes; sin el parámetro vienen todas, que es
     * lo que necesita el mantenimiento.
     */
    public function allPlantillas(Request $request)
    {
        try {
            $incluirInactivas = filter_var($request->query('inactivos', true), FILTER_VALIDATE_BOOLEAN);
            $result = DB::selectOne(
                'SELECT ventas.fn_whatsapp_plantillas_listar(?::BOOLEAN) as result',
                [$incluirInactivas]
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allPlantillas de WhatsApp', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener las plantillas', 500);
        }
    }

    /** Crear (sin id) o modificar (con id), como en el catálogo de gestiones. */
    public function savePlantilla(Request $request, $id = null)
    {
        try {
            $validator = Validator::make($this->datosDe($request), [
                // El código se puede omitir: la función lo saca del nombre
                'codigo' => 'nullable|string|min:3|max:30',
                'nombre' => 'required|string|min:3|max:60',
                'icono'  => 'nullable|string|max:40',
                'asunto' => 'required|string|min:3|max:200',
                'texto'  => 'required|string|min:10|max:4000',
                'orden'  => 'nullable|integer|min:0|max:9999',
                'activo' => 'nullable|boolean',
            ], [
                'nombre.required' => 'El nombre es obligatorio',
                'nombre.min'      => 'El nombre debe tener al menos 3 caracteres',
                'asunto.required' => 'El asunto es obligatorio',
                'texto.required'  => 'El mensaje es obligatorio',
                'texto.min'       => 'El mensaje debe tener al menos 10 caracteres',
                'texto.max'       => 'El mensaje no puede pasar de 4000 caracteres',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_whatsapp_plantillas_guardar(?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::TEXT, ?::INTEGER, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id !== null ? (int) $id : null,
                    $d['codigo'] ?? null,
                    $d['nombre'],
                    $d['icono'] ?? null,
                    $d['asunto'],
                    $d['texto'],
                    array_key_exists('orden', $d) ? (int) $d['orden'] : 100,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Plantilla de WhatsApp guardada', ['id' => $id, 'nombre' => $d['nombre']]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'savePlantilla rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en savePlantilla', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar la plantilla', 500);
        }
    }

    public function deletePlantilla(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_whatsapp_plantillas_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Plantilla de WhatsApp eliminada', ['id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deletePlantilla rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deletePlantilla', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar la plantilla', 500);
        }
    }
}
