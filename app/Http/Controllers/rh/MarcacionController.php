<?php

namespace App\Http\Controllers\rh;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * Marcaciones de empleados (rh.marcaciones): entradas y salidas registradas
 * con reconocimiento facial (kiosco) o a mano.
 *
 * Mismo esquema que el resto de rh: la lógica está en las funciones
 * rh.fn_marcaciones_*; aquí se valida la entrada, se guarda la foto del
 * momento si viene y se traduce la respuesta.
 *
 *   GET    rh/marcacion/allMarcaciones      paginado: ?page&per_page&search&desde&hasta&empleado_id&tipo&origen
 *   GET    rh/marcacion/findByIdMarcacion/{id}
 *   POST   rh/marcacion/registrar           kiosco / celular: { empleado_id, similitud, dispositivo,
 *                                          foto_base64, latitud, longitud, precision_m… }
 *   GET    rh/marcacion/miEmpleado          quién soy (el empleado de mi usuario) + lo de hoy
 *   GET    rh/marcacion/misMarcaciones     MIS marcaciones, paginadas (?page&per_page&desde&hasta&tipo)
 *   POST   rh/marcacion/registrarMia        marco YO desde mi celular (el empleado sale de la sesión)
 *   POST   rh/marcacion/addMarcacion        alta manual (con tipo y fecha/hora)
 *   POST   rh/marcacion/editMarcacion/{id}  corregir tipo / hora / observación
 *   DELETE rh/marcacion/deleteMarcacion/{id}
 *   GET    rh/marcacion/resumen             horas por empleado y día: ?desde&hasta&empleado_id
 *   GET    rh/marcacion/getImagenMarcacion/{id}   (pública) foto del momento
 */
class MarcacionController extends Controller
{
    use ApiResponder;

    /** Carpeta dentro del disco `public` donde van las fotos del kiosco. */
    private const CARPETA_FOTOS = 'img/marcaciones';

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // faltan datos
        'P0010' => 422,   // valor no admitido
        'P0013' => 404,   // no existe
        'P0020' => 429,   // marcación repetida dentro de la espera
        'P0021' => 409,   // empleado inactivo
        'P0022' => 422,   // descriptor facial inválido
        'P0024' => 422,   // fuera del perímetro de su sucursal
        'P0025' => 422,   // su sucursal exige ubicación y no llegó ninguna
    ];

    public function __construct() {
        $this->middleware('auth:api', ['except' => ['getImagenMarcacion']]);
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

    // ================================================================
    // LISTAR / OBTENER
    // ================================================================

    public function allMarcaciones(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT rh.fn_marcaciones_listar_paginado(?, ?, ?, ?::DATE, ?::DATE, ?::BIGINT, ?::VARCHAR, ?::VARCHAR) as result',
                [
                    (int) $request->input('page', 1),
                    (int) $request->input('per_page', 15),
                    $request->input('search', ''),
                    $request->input('desde') ?: null,
                    $request->input('hasta') ?: null,
                    $request->filled('empleado_id') ? (int) $request->input('empleado_id') : null,
                    $request->input('tipo') ?: null,
                    $request->input('origen') ?: null,
                ]
            );
            return $this->successResponse(json_decode($result->result, true), 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allMarcaciones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar las marcaciones', 500);
        }
    }

    public function findByIdMarcacion($id)
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_marcaciones_obtener(?::BIGINT) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);
            if (!($resultado['success'] ?? false)) {
                return $this->errorResponse($resultado['message'] ?? 'Marcación no encontrada', 404);
            }
            return $this->successResponse($resultado['data'], $resultado['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdMarcacion', ['message' => $e->getMessage(), 'marcacion_id' => $id]);
            return $this->errorResponse('Ocurrió un error al obtener la marcación', 500);
        }
    }

    /** Horas trabajadas por empleado y día. */
    public function resumen(Request $request)
    {
        try {
            $result = DB::selectOne('SELECT rh.fn_marcaciones_resumen(?::DATE, ?::DATE, ?::BIGINT) as result', [
                $request->input('desde') ?: null,
                $request->input('hasta') ?: null,
                $request->filled('empleado_id') ? (int) $request->input('empleado_id') : null,
            ]);
            $resultado = json_decode($result->result, true);
            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en resumen de marcaciones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al calcular el resumen', 500);
        }
    }

    // ================================================================
    // REGISTRAR (kiosco) Y ALTA MANUAL
    // ================================================================

    /**
     * Marcación desde el kiosco facial. El tipo se deduce solo (alterna con la
     * última del día) salvo que se mande. `foto_base64` es la miniatura del
     * momento: se guarda en disco y sólo se conserva el nombre del fichero.
     */
    public function registrar(Request $request)
    {
        return $this->guardar($request, true);
    }

    /** Alta manual desde la pantalla de marcaciones (con tipo y fecha/hora). */
    public function addMarcacion(Request $request)
    {
        return $this->guardar($request, false);
    }

    // ================================================================
    // DESDE MI CELULAR
    // ================================================================

    /**
     * El empleado al que corresponde el usuario de la sesión.
     *
     * La pantalla del celular no pregunta a quién marcar: lo dice el
     * servidor. Devuelve además lo de hoy, para pintar la última marcación
     * sin una segunda llamada.
     */
    /**
     * A qué empleado corresponde el usuario de la sesión.
     *
     * Primero el enlace de verdad (seguridad.users.empleado_id) y, si está
     * vacío, por el correo: usuarios y empleados son dos tablas distintas y
     * en muchas bases ese enlace no se llenó nunca. Si no se puede saber se
     * devuelve null, y quien llama contesta explicando qué falta.
     */
    private function empleadoDeLaSesion(): ?int
    {
        $u = auth('api')->user();
        if (!$u) { return null; }

        if (!empty($u->empleado_id)) { return (int) $u->empleado_id; }

        if (!empty($u->email)) {
            $fila = DB::selectOne(
                'SELECT id FROM rh.empleados WHERE LOWER(email) = LOWER(?) LIMIT 1',
                [$u->email]
            );
            if ($fila) { return (int) $fila->id; }
        }
        return null;
    }

    /**
     * Quién soy y qué he marcado hoy.
     *
     * La pantalla del celular no pregunta a quién marcar: lo dice el
     * servidor. Devuelve también lo de hoy y cuántas muestras de rostro
     * tiene el empleado, para pintarlo todo sin una segunda llamada.
     */
    public function miEmpleado(Request $request)
    {
        try {
            $empleadoId = $this->empleadoDeLaSesion();
            if (!$empleadoId) {
                return $this->errorResponse(
                    'Su usuario no está enlazado a ningún empleado: pida a Recursos Humanos que lo asocie', 409);
            }

            $ficha = DB::selectOne('SELECT rh.fn_empleados_obtener(?::BIGINT) AS result', [$empleadoId]);
            $empleado = json_decode($ficha->result ?? '{}', true)['data'] ?? null;
            if (!$empleado) {
                return $this->errorResponse('El empleado enlazado a su usuario ya no existe', 404);
            }

            $hoy = DB::selectOne(
                "SELECT COALESCE((SELECT jsonb_agg(rh.fn_marcaciones_json(m.id) ORDER BY m.fecha_hora DESC)
                                    FROM rh.marcaciones m
                                   WHERE m.empleado_id = ?::BIGINT AND m.fecha = CURRENT_DATE), '[]'::jsonb) AS result",
                [$empleadoId]
            );

            $muestras = DB::selectOne(
                'SELECT COUNT(*) AS n FROM rh.rostros_empleados WHERE empleado_id = ?::BIGINT',
                [$empleadoId]
            );

            return $this->successResponse([
                'empleado'        => $empleado,
                'marcaciones_hoy' => json_decode($hoy->result, true),
                'muestras_rostro' => (int) ($muestras->n ?? 0),
            ], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en miEmpleado', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('No se pudo obtener su ficha de empleado', 500);
        }
    }

    /**
     * MIS marcaciones, paginadas y con filtro de fechas.
     *
     * Igual que allMarcaciones pero con el empleado puesto por la sesión: la
     * pantalla del celular no manda a quién mirar, así nadie ve las horas de
     * entrada y salida de un compañero cambiando un número en la petición.
     */
    public function misMarcaciones(Request $request)
    {
        $empleadoId = $this->empleadoDeLaSesion();
        if (!$empleadoId) {
            return $this->errorResponse(
                'Su usuario no está enlazado a ningún empleado: pida a Recursos Humanos que lo asocie', 409);
        }

        try {
            $result = DB::selectOne(
                'SELECT rh.fn_marcaciones_listar_paginado(?, ?, ?, ?::DATE, ?::DATE, ?::BIGINT, ?::VARCHAR, ?::VARCHAR) as result',
                [
                    (int) $request->input('page', 1),
                    (int) $request->input('per_page', 10),
                    '',                               // el buscador no pinta aquí: son las suyas
                    $request->input('desde') ?: null,
                    $request->input('hasta') ?: null,
                    $empleadoId,                      // manda la sesión
                    $request->input('tipo') ?: null,
                    null,
                ]
            );
            return $this->successResponse(json_decode($result->result, true), 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en misMarcaciones', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar sus marcaciones', 500);
        }
    }

    /**
     * Marcación desde el celular del propio empleado.
     *
     * El empleado NO se acepta del cliente: sale de la sesión. Si no,
     * cualquiera podría marcar por un compañero desde su propio teléfono
     * cambiando un número en la petición.
     */
    public function registrarMia(Request $request)
    {
        $empleadoId = $this->empleadoDeLaSesion();
        if (!$empleadoId) {
            return $this->errorResponse(
                'Su usuario no está enlazado a ningún empleado: pida a Recursos Humanos que lo asocie', 409);
        }

        $datos = $this->datosDe($request);
        $datos['empleado_id'] = $empleadoId;   // manda la sesión, no el cliente
        $datos['origen']      = 'MOVIL';
        $request->replace($datos);

        return $this->guardar($request, true);
    }

    private function guardar(Request $request, bool $esKiosco)
    {
        $datos = $this->datosDe($request);
        $validator = Validator::make($datos, [
            'empleado_id'      => 'required|integer',
            'tipo'             => 'nullable|string|in:ENTRADA,SALIDA,entrada,salida',
            'origen'           => 'nullable|string|in:FACIAL,MANUAL,WEB,MOVIL',
            'similitud'        => 'nullable|numeric|min:0|max:100',
            'dispositivo'      => 'nullable|string|max:150',
            'latitud'          => 'nullable|numeric|between:-90,90',
            'longitud'         => 'nullable|numeric|between:-180,180',
            'observacion'      => 'nullable|string|max:1000',
            'fecha_hora'       => 'nullable|date',
            'espera_segundos'  => 'nullable|integer|min:0|max:3600',
            // Lo que declara el GPS del aparato, en metros
            'precision_m'      => 'nullable|numeric|min:0|max:100000',
            'foto_base64'      => 'nullable|string',
        ], [
            'empleado_id.required' => 'Falta el empleado',
        ]);
        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }
        $d = $validator->validated();

        $foto = null;
        try {
            if (!empty($d['foto_base64'])) {
                $foto = $this->guardarFoto($d['foto_base64'], (int) $d['empleado_id']);
            }

            $result = DB::selectOne(
                'SELECT rh.fn_marcaciones_registrar(?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::NUMERIC, ?::VARCHAR, ?::NUMERIC, ?::NUMERIC, ?::VARCHAR, ?::TEXT, ?::TIMESTAMPTZ, ?::INTEGER, ?::NUMERIC, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $d['empleado_id'],
                    isset($d['tipo']) ? strtoupper($d['tipo']) : null,
                    strtoupper($d['origen'] ?? ($esKiosco ? 'FACIAL' : 'MANUAL')),
                    $d['similitud'] ?? null,
                    $d['dispositivo'] ?? null,
                    $d['latitud'] ?? null,
                    $d['longitud'] ?? null,
                    $foto,
                    $d['observacion'] ?? null,
                    $d['fecha_hora'] ?? null,
                    // El kiosco trae su propia espera; a mano no se bloquea
                    $esKiosco ? (int) ($d['espera_segundos'] ?? 60) : 0,
                    // La ubicación y su error los manda el navegador; el enlace
                    // del mapa lo arma la función con lo que de verdad se guardó
                    $d['precision_m'] ?? null,
                ], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);

            sistemaLog('info', 'Marcación registrada', [
                'marcacion_id' => $resultado['data']['id'] ?? null,
                'empleado_id'  => $d['empleado_id'],
                'tipo'         => $resultado['data']['tipo'] ?? null,
                'origen'       => $resultado['data']['origen'] ?? null,
            ]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            if ($foto) { $this->borrarFoto($foto); }   // la marcación no entró: la foto sobra
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'Marcación rechazada', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            if ($foto) { $this->borrarFoto($foto); }
            sistemaLog('error', 'Error al registrar la marcación', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al registrar la marcación', 500);
        }
    }

    public function editMarcacion(Request $request, $id)
    {
        $datos = $this->datosDe($request);
        $validator = Validator::make($datos, [
            'tipo'        => 'nullable|string|in:ENTRADA,SALIDA,entrada,salida',
            'fecha_hora'  => 'nullable|date',
            'observacion' => 'nullable|string|max:1000',
        ]);
        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }
        $d = $validator->validated();

        try {
            $result = DB::selectOne(
                'SELECT rh.fn_marcaciones_modificar(?::BIGINT, ?::VARCHAR, ?::TIMESTAMPTZ, ?::TEXT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    isset($d['tipo']) ? strtoupper($d['tipo']) : null,
                    $d['fecha_hora'] ?? null,
                    $d['observacion'] ?? null,
                ], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);
            sistemaLog('info', 'Marcación modificada', ['marcacion_id' => $id]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editMarcacion', ['message' => $e->getMessage(), 'marcacion_id' => $id]);
            return $this->errorResponse('Ocurrió un error al modificar la marcación', 500);
        }
    }

    public function deleteMarcacion(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT rh.fn_marcaciones_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $resultado = json_decode($result->result, true);

            if (!empty($resultado['data']['foto'])) { $this->borrarFoto($resultado['data']['foto']); }

            sistemaLog('info', 'Marcación eliminada', ['marcacion_id' => $id]);
            return $this->successResponse($resultado['data'], $resultado['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteMarcacion', ['message' => $e->getMessage(), 'marcacion_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar la marcación', 500);
        }
    }

    // ================================================================
    // FOTO DEL MOMENTO
    // ================================================================

    /** Guarda la miniatura (data URL o base64 pelado) y devuelve el nombre del fichero. */
    private function guardarFoto(string $base64, int $empleadoId): ?string
    {
        if (preg_match('/^data:image\/(\w+);base64,/', $base64, $m)) {
            $extension = strtolower($m[1]) === 'png' ? 'png' : 'jpg';
            $base64 = substr($base64, strpos($base64, ',') + 1);
        } else {
            $extension = 'jpg';
        }
        $contenido = base64_decode($base64, true);
        if ($contenido === false || strlen($contenido) > 2_000_000) { return null; }   // basura o demasiado grande

        $nombre = $empleadoId . '_' . date('Ymd_His') . '_' . Str::random(6) . '.' . $extension;
        Storage::disk('public')->put(self::CARPETA_FOTOS . '/' . $nombre, $contenido);
        return $nombre;
    }

    private function borrarFoto(?string $nombre): void
    {
        if (!$nombre) { return; }
        $ruta = self::CARPETA_FOTOS . '/' . $nombre;
        if (Storage::disk('public')->exists($ruta)) { Storage::disk('public')->delete($ruta); }
    }

    /** Foto del momento de una marcación (la usa <img src>, por eso es pública). */
    public function getImagenMarcacion($id)
    {
        try {
            $fila = DB::selectOne('SELECT foto FROM rh.marcaciones WHERE id = ?', [(int) $id]);
            $ruta = $fila && $fila->foto ? self::CARPETA_FOTOS . '/' . $fila->foto : null;
            if (!$ruta || !Storage::disk('public')->exists($ruta)) {
                return response()->file(public_path('assets/img/user/default.png'));
            }
            return response()->file(Storage::disk('public')->path($ruta));
        } catch (Exception $e) {
            sistemaLog('error', 'Error en getImagenMarcacion', ['message' => $e->getMessage(), 'marcacion_id' => $id]);
            return response()->json(['message' => 'No se pudo obtener la imagen'], 500);
        }
    }
}
