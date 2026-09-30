<?php

namespace App\Http\Controllers\config;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use App\Events\BoletinPublicado;

/**
 * Boletines (core.boletines): avisos con imágenes que se muestran al usuario
 * nada más entrar al sistema.
 *
 * Mismo esquema que el resto del sistema: la lógica vive en las funciones
 * core.fn_boletines_*; aquí se valida la entrada, se guardan las imágenes y
 * se traduce la respuesta.
 *
 *   GET    config/boletin/allBoletines        paginado: ?page&per_page&search&estado
 *   GET    config/boletin/findByIdBoletin/{id}
 *   POST   config/boletin/addBoletin          { titulo, desde, hasta, imagenes[], usuarios[], grupos[] }
 *   POST   config/boletin/editBoletin/{id}
 *   DELETE config/boletin/deleteBoletin/{id}  a la papelera (borrado lógico)
 *   GET    config/boletin/papelera
 *   POST   config/boletin/restaurarBoletin/{id}
 *   POST   config/boletin/subirImagen         fichero -> nombre guardado
 *   GET    config/boletin/imagen/{imagenId}   la imagen, sólo para quien puede verla
 *   GET    config/boletin/destinatarios/{id}  quién lo verá (directos + por grupo)
 *   GET    config/boletin/misBoletines        los vigentes del usuario que entra
 *   POST   config/boletin/marcarVisto/{id}    { no_mostrar }
 *
 * Las imágenes NO se sirven desde una URL pública: se piden por este
 * controlador con el token, y sólo si quien pregunta es destinatario del
 * boletín o tiene permiso para administrarlos. Si el PHP tiene la extensión
 * GD activada, además se le estampa encima el nombre del usuario que la está
 * viendo (marca de agua quemada en el fichero que se entrega).
 */
class BoletinController extends Controller
{
    use ApiResponder;

    /** Carpeta dentro del disco `public` donde van los archivos del carrusel. */
    private const CARPETA = 'img/boletines';

    /** Extensiones que no son una imagen: la extensión decide el tipo. */
    private const EXT_VIDEO = ['mp4', 'm4v', 'webm', 'ogv', 'mov'];
    private const EXT_AUDIO = ['mp3', 'm4a', 'wav', 'ogg', 'oga'];

    /** Tope de tamaño de cada tipo, en KB. */
    private const MAX_VIDEO_KB = 65536;    // 64 MB
    private const TOPES_KB = [
        'IMAGEN' => 8192,                  //  8 MB
        'AUDIO'  => 20480,                 // 20 MB
        'VIDEO'  => self::MAX_VIDEO_KB,
    ];

    private const NOMBRES_TIPO = [
        'IMAGEN' => 'La imagen',
        'AUDIO'  => 'El audio',
        'VIDEO'  => 'El video',
    ];

    /** Pusher no admite más de 100 canales por evento. */
    private const CANALES_POR_ENVIO = 90;

    private const SUBIDA_OK = [
        'IMAGEN' => 'Imagen subida con éxito',
        'AUDIO'  => 'Audio subido con éxito',
        'VIDEO'  => 'Video subido con éxito',
    ];

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

    // ================================================================
    // LISTAR / OBTENER
    // ================================================================

    public function allBoletines(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT core.fn_boletines_listar_paginado(?, ?, ?, ?::TEXT) as result',
                [
                    (int) $request->input('page', 1),
                    (int) $request->input('per_page', 15),
                    $request->input('search', ''),
                    $request->input('estado', 'TODOS'),
                ]
            );
            return $this->successResponse(json_decode($result->result, true), 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allBoletines', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar los boletines', 500);
        }
    }

    public function findByIdBoletin($id)
    {
        try {
            $result = DB::selectOne('SELECT core.fn_boletines_obtener(?::BIGINT) as result', [(int) $id]);
            $datos = json_decode($result->result, true);
            return $datos['success']
                ? $this->successResponse($datos['data'], $datos['message'])
                : $this->errorResponse($datos['message'], 404);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdBoletin', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener el boletín', 500);
        }
    }

    public function destinatarios($id)
    {
        try {
            $result = DB::selectOne('SELECT core.fn_boletines_destinatarios(?::BIGINT) as result', [(int) $id]);
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en destinatarios', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener los destinatarios', 500);
        }
    }

    /**
     * Lanza el boletín a quien le toca, sin esperar a que vuelva a entrar.
     *
     * Avisa por websocket a los destinatarios que estén con la sesión abierta.
     * El aviso lleva el id y el título; el contenido lo vuelve a pedir cada
     * pantalla con su token.
     *
     * Con ignorar_no_mostrar se retira antes la marca de «no volver a mostrar»,
     * que es lo único que cambia en los datos del boletín.
     */
    public function lanzarBoletin(Request $request, $id)
    {
        try {
            $u = auth('api')->user();
            if (!$this->puedeAdministrar($u->id ?? null)) {
                return $this->errorResponse('No tiene permiso para lanzar boletines', 403);
            }

            $result = DB::selectOne('SELECT core.fn_boletines_obtener(?::BIGINT) as result', [(int) $id]);
            $datos = json_decode($result->result, true);
            if (!($datos['success'] ?? false) || empty($datos['data'])) {
                return $this->errorResponse($datos['message'] ?? 'El boletín no existe', 404);
            }

            // Se puede lanzar cualquiera menos un inactivo: si el administrador
            // decide mandar uno programado o ya caducado, manda su decisión.
            $boletin = $datos['data'];
            if (!$boletin['activo']) {
                return $this->errorResponse('El boletín está inactivo: actívelo antes de lanzarlo', 422);
            }
            if (empty($boletin['imagenes'])) {
                return $this->errorResponse('El boletín no tiene contenido que mostrar', 422);
            }

            // «Ignorar el no volver a mostrar»: se retira esa marca antes de
            // resolver los destinatarios, así el boletín vuelve a salirles
            // ahora y la próxima vez que entren.
            $ignorar = filter_var($request->input('ignorar_no_mostrar', false), FILTER_VALIDATE_BOOLEAN);
            $reactivados = 0;
            if ($ignorar) {
                $result = DB::selectOne('SELECT core.fn_boletines_ignorar_no_mostrar(?::BIGINT) as result', [(int) $id]);
                $reactivados = (int) (json_decode($result->result, true)['data']['reactivados'] ?? 0);
            }

            $result = DB::selectOne('SELECT core.fn_boletines_destinatarios(?::BIGINT) as result', [(int) $id]);
            $lista = json_decode($result->result, true)['data'] ?? [];

            // Sólo a los activos: al resto no le sirve de nada el aviso
            $userIds = [];
            foreach ($lista as $d) {
                if (($d['isactive'] ?? false) && !($d['no_mostrar'] ?? false)) {
                    $userIds[] = (int) $d['user_id'];
                }
            }

            if (!$userIds) {
                return $this->errorResponse('Nadie puede recibirlo: revise los destinatarios del boletín', 422);
            }

            // Pusher admite 100 canales por envío: se manda por tandas
            foreach (array_chunk($userIds, self::CANALES_POR_ENVIO) as $tanda) {
                event(new BoletinPublicado((int) $id, (string) $boletin['titulo'], $tanda));
            }

            $mensaje = count($userIds) === 1
                ? 'Boletín lanzado a 1 usuario'
                : sprintf('Boletín lanzado a %d usuarios', count($userIds));
            if ($reactivados) {
                $mensaje .= $reactivados === 1
                    ? ', a 1 de ellos se le quitó el «no volver a mostrar»'
                    : sprintf(', a %d de ellos se les quitó el «no volver a mostrar»', $reactivados);
            }

            return $this->successResponse(
                ['destinatarios' => count($userIds), 'reactivados' => $reactivados],
                $mensaje
            );
        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al lanzar el boletín', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al lanzar el boletín', 500);
        }
    }

    /**
     * Orden de la lista: los boletines de `ids`, en ese orden.
     *
     * Se reparten entre ellos las posiciones que ya ocupaban, así arrastrar
     * una fila en la grilla no toca al resto de la lista.
     */
    public function reordenarBoletines(Request $request)
    {
        $datos = $this->datosDe($request);

        $validator = Validator::make($datos, [
            'ids'   => 'required|array|min:1',
            'ids.*' => 'required|integer',
        ], [
            'ids.required' => 'No se recibió ningún boletín que ordenar',
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        DB::beginTransaction();
        try {
            $ids = '{' . implode(',', array_map('intval', $datos['ids'])) . '}';
            $result = DB::selectOne(
                'SELECT core.fn_boletines_reordenar(?::BIGINT[], ' . self::CASTS_AUDIT . ') as result',
                array_merge([$ids], $this->auditoria($request))
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
            sistemaLog('error', 'Error al reordenar boletines', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al cambiar el orden', 500);
        }
    }

    public function papelera()
    {
        try {
            $result = DB::selectOne('SELECT core.fn_boletines_papelera() as result');
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de boletines', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar la papelera', 500);
        }
    }

    // ================================================================
    // CREAR / MODIFICAR / ELIMINAR
    // ================================================================

    public function addBoletin(Request $request)
    {
        return $this->guardar($request, null);
    }

    public function editBoletin(Request $request, $id)
    {
        return $this->guardar($request, (int) $id);
    }

    private function guardar(Request $request, ?int $id)
    {
        $datos = $this->datosDe($request);

        $validator = Validator::make($datos, [
            'titulo'                 => ($id === null ? 'required' : 'sometimes') . '|string|max:200',
            'descripcion'            => 'nullable|string',
            'desde'                  => 'nullable|date',
            'hasta'                  => ($id === null ? 'required' : 'sometimes') . '|date',
            'orden'                  => 'nullable|integer|min:0',
            'obligatorio'            => 'nullable|boolean',
            // Si el visor ofrece la casilla «No volver a mostrar»
            'no_mostrar'             => 'nullable|boolean',
            'activo'                 => 'nullable|boolean',
            'imagenes'               => 'nullable|array',
            'imagenes.*.archivo'     => 'nullable|string|max:255',
            'imagenes.*.titulo'      => 'nullable|string|max:200',
            'imagenes.*.segundos'    => 'nullable|integer|min:1|max:120',
            'usuarios'               => 'nullable|array',
            'usuarios.*'             => 'integer',
            'grupos'                 => 'nullable|array',
            'grupos.*.grupo_id'      => 'required_with:grupos|integer',
        ], [
            'titulo.required' => 'El título del boletín es obligatorio',
            'titulo.max'      => 'El título no puede pasar de 200 caracteres',
            'hasta.required'  => 'Indique hasta qué día rige el boletín',
            'hasta.date'      => 'La fecha «hasta» no es una fecha válida',
            'desde.date'      => 'La fecha «desde» no es una fecha válida',
            'orden.integer'     => 'El orden debe ser un número',
            'imagenes.*.segundos.integer' => 'El tiempo en pantalla debe ser un número de segundos',
            'imagenes.*.segundos.min'     => 'Cada imagen debe quedarse al menos 1 segundo en pantalla',
            'imagenes.*.segundos.max'     => 'Una imagen no puede quedarse más de 120 segundos en pantalla',
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        DB::beginTransaction();
        try {
            $sql = $id === null
                ? 'SELECT core.fn_boletines_crear(?::JSONB, ' . self::CASTS_AUDIT . ') as result'
                : 'SELECT core.fn_boletines_modificar(?::BIGINT, ?::JSONB, ' . self::CASTS_AUDIT . ') as result';

            $parametros = $id === null
                ? array_merge([json_encode($datos)], $this->auditoria($request))
                : array_merge([$id, json_encode($datos)], $this->auditoria($request));

            $result = DB::selectOne($sql, $parametros);
            $respuesta = json_decode($result->result, true);
            DB::commit();

            return $this->successResponse($respuesta['data'], $respuesta['message']);
        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            if ($codigo === 500) {
                sistemaLog('error', 'Error al guardar el boletín', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            }
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error al guardar el boletín', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar el boletín', 500);
        }
    }

    public function deleteBoletin(Request $request, $id)
    {
        DB::beginTransaction();
        try {
            $result = DB::selectOne(
                'SELECT core.fn_boletines_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $respuesta = json_decode($result->result, true);
            DB::commit();
            return $this->successResponse(null, $respuesta['message']);
        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error en deleteBoletin', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al eliminar el boletín', 500);
        }
    }

    public function restaurarBoletin(Request $request, $id)
    {
        DB::beginTransaction();
        try {
            $result = DB::selectOne(
                'SELECT core.fn_boletines_restaurar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
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
            sistemaLog('error', 'Error en restaurarBoletin', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al restaurar el boletín', 500);
        }
    }

    /** Borra de verdad un boletín de la papelera, con sus imágenes del disco. */
    public function eliminarDefinitivo(Request $request, $id)
    {
        DB::beginTransaction();
        try {
            $result = DB::selectOne(
                'SELECT core.fn_boletines_eliminar_definitivo(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $respuesta = json_decode($result->result, true);
            DB::commit();

            $this->borrarFicheros($respuesta['data']['archivos'] ?? []);
            return $this->successResponse(null, $respuesta['message']);
        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error en eliminarDefinitivo de boletines', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al eliminar el boletín', 500);
        }
    }

    public function vaciarPapelera(Request $request)
    {
        DB::beginTransaction();
        try {
            $result = DB::selectOne(
                'SELECT core.fn_boletines_vaciar_papelera(' . self::CASTS_AUDIT . ') as result',
                $this->auditoria($request)
            );
            $respuesta = json_decode($result->result, true);
            DB::commit();

            $this->borrarFicheros($respuesta['data']['archivos'] ?? []);
            return $this->successResponse(null, $respuesta['message']);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error al vaciar la papelera de boletines', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al vaciar la papelera', 500);
        }
    }

    /** Quita del disco las imágenes que ya no tienen dueño. */
    private function borrarFicheros(array $archivos): void
    {
        foreach ($archivos as $nombre) {
            if (!$nombre) { continue; }
            Storage::disk('public')->delete(self::CARPETA . '/' . $nombre);
        }
    }

    // ================================================================
    // IMÁGENES
    // ================================================================

    /** Sube una imagen y devuelve el nombre con el que quedó guardada. */
    public function subirImagen(Request $request)
    {
        try {
            $validator = Validator::make($request->all(), [
                'imagen_file' => 'required|file|mimes:jpg,jpeg,png,webp,gif,mp4,mp3|max:' . self::MAX_VIDEO_KB,
            ], [
                'imagen_file.mimes' => 'El archivo debe ser una imagen (jpg, png, webp, gif), un video mp4 o un audio mp3',
                'imagen_file.max'   => 'El archivo no puede pasar de ' . (int) (self::MAX_VIDEO_KB / 1024) . ' MB',
            ]);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $file = $request->file('imagen_file');
            if (!$file->isValid()) {
                return $this->errorResponse('El archivo no es válido', 422);
            }

            $extension = strtolower($file->getClientOriginalExtension() ?: 'jpg');

            // Cada tipo tiene su tamaño: una imagen de 60 MB no tiene sentido
            $tipo = $this->tipoDeArchivo($extension);
            $tope = self::TOPES_KB[$tipo];
            if ($file->getSize() > $tope * 1024) {
                return $this->errorResponse(
                    sprintf('%s no puede pasar de %d MB', self::NOMBRES_TIPO[$tipo], (int) ($tope / 1024)),
                    422
                );
            }
            $nombre = 'bol_' . date('YmdHis') . '_' . Str::random(8) . '.' . $extension;

            if (!$file->storeAs('public/' . self::CARPETA, $nombre)) {
                return $this->errorResponse('No se pudo guardar la imagen', 500);
            }

            return $this->successResponse([
                'archivo' => $nombre,
                'tipo' => $tipo,
                'nombre_original' => $file->getClientOriginalName(),
                'tamano' => $file->getSize(),
            ], self::SUBIDA_OK[$tipo]);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en subirImagen de boletines', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al subir la imagen', 500);
        }
    }

    /**
     * Entrega la imagen de un boletín. Requiere token y que quien pregunte sea
     * destinatario del boletín o pueda administrarlos. Con GD activado se le
     * estampa encima el usuario que la ve.
     */
    public function imagen(Request $request, $imagenId)
    {
        try {
            $u = auth('api')->user();
            $result = DB::selectOne(
                'SELECT core.fn_boletines_imagen(?::BIGINT, ?::BIGINT) as result',
                [(int) $imagenId, $u->id ?? null]
            );
            $datos = json_decode($result->result, true);

            if (!$datos['success']) {
                return $this->errorResponse($datos['message'], 404);
            }

            // Quien no es destinatario sólo la ve si puede administrar boletines
            if (!$datos['data']['destinatario'] && !$this->puedeAdministrar($u->id ?? null)) {
                return $this->errorResponse('No tiene permiso para ver esta imagen', 403);
            }

            $ruta = storage_path('app/public/' . self::CARPETA . '/' . $datos['data']['archivo']);
            if (!file_exists($ruta)) {
                return $this->errorResponse('La imagen no está en el servidor', 404);
            }

            $cabeceras = [
                'Cache-Control'       => 'no-store, no-cache, must-revalidate, private',
                'Pragma'              => 'no-cache',
                'Content-Disposition' => 'inline',
            ];

            // El video y el audio no se marcan ni se cargan en memoria: la marca
            // de agua se la pone el navegador cuadro a cuadro sobre el lienzo.
            $clase = $this->tipoDeArchivo(pathinfo($ruta, PATHINFO_EXTENSION));
            if ($clase !== 'IMAGEN') {
                return response()->file($ruta, $cabeceras + ['Content-Type' => $this->tipoMime($ruta, false)]);
            }

            $contenido = $this->conMarcaDeAgua($ruta, $u);

            return response($contenido ?? file_get_contents($ruta), 200,
                $cabeceras + ['Content-Type' => $this->tipoMime($ruta, $contenido !== null)]);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al servir la imagen del boletín', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener la imagen', 500);
        }
    }

    /** ¿Tiene acceso a la pantalla de boletines? (menú boletines con ver/editar) */
    private function puedeAdministrar(?int $userId): bool
    {
        if (!$userId) { return false; }
        try {
            $fila = DB::selectOne(
                "SELECT 1
                   FROM seguridad.users u
                   JOIN seguridad.accesos a ON a.perfil_id = u.perfil_id
                   JOIN seguridad.menus m   ON m.id = a.menu_id
                  WHERE u.id = ?
                    AND m.url ILIKE '%boletines%'
                    AND a.ver = true
                  LIMIT 1",
                [$userId]
            );
            return (bool) $fila;
        } catch (Exception $e) {
            return false;
        }
    }

    /**
     * Estampa el login y el nombre del usuario en diagonal sobre la imagen.
     * Devuelve null si el PHP no tiene GD: entonces se entrega el original y
     * la marca la pinta la pantalla sobre un lienzo.
     */
    private function conMarcaDeAgua(string $ruta, $usuario): ?string
    {
        if (!extension_loaded('gd') || !function_exists('imagecreatetruecolor')) {
            return null;
        }

        try {
            $info = getimagesize($ruta);
            if (!$info) { return null; }

            switch ($info[2]) {
                case IMAGETYPE_JPEG: $img = imagecreatefromjpeg($ruta); break;
                case IMAGETYPE_PNG:  $img = imagecreatefrompng($ruta);  break;
                case IMAGETYPE_GIF:  $img = imagecreatefromgif($ruta);  break;
                case IMAGETYPE_WEBP: $img = function_exists('imagecreatefromwebp') ? imagecreatefromwebp($ruta) : null; break;
                default: return null;
            }
            if (!$img) { return null; }

            $ancho = imagesx($img);
            $alto  = imagesy($img);
            $texto = trim(($usuario->login_user ?? '') . '  ' . trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')));
            $texto = $texto . '  ' . date('d/m/Y H:i');

            $blanco = imagecolorallocatealpha($img, 255, 255, 255, 95);
            $negro  = imagecolorallocatealpha($img, 0, 0, 0, 105);
            $paso   = max(140, (int) ($ancho / 4));

            for ($y = 0; $y < $alto + $paso; $y += $paso) {
                for ($x = -$paso; $x < $ancho; $x += $paso * 2) {
                    imagestring($img, 5, $x + 1, $y + 1, $texto, $negro);
                    imagestring($img, 5, $x, $y, $texto, $blanco);
                }
            }

            ob_start();
            if ($info[2] === IMAGETYPE_PNG) { imagepng($img); } else { imagejpeg($img, null, 85); }
            $salida = ob_get_clean();
            imagedestroy($img);

            return $salida ?: null;
        } catch (Exception $e) {
            sistemaLog('error', 'No se pudo marcar la imagen del boletín', ['message' => $e->getMessage()]);
            return null;
        }
    }

    /** IMAGEN, VIDEO o AUDIO, igual que lo decide la base de datos. */
    private function tipoDeArchivo(string $extension): string
    {
        $ext = strtolower($extension);
        if (in_array($ext, self::EXT_VIDEO, true)) { return 'VIDEO'; }
        if (in_array($ext, self::EXT_AUDIO, true)) { return 'AUDIO'; }
        return 'IMAGEN';
    }

    private function tipoMime(string $ruta, bool $reconvertida): string
    {
        $ext = strtolower(pathinfo($ruta, PATHINFO_EXTENSION));
        $medios = [
            'mp4' => 'video/mp4', 'm4v' => 'video/mp4', 'webm' => 'video/webm',
            'ogv' => 'video/ogg', 'mov' => 'video/quicktime',
            'mp3' => 'audio/mpeg', 'm4a' => 'audio/mp4', 'wav' => 'audio/wav',
            'ogg' => 'audio/ogg', 'oga' => 'audio/ogg',
        ];
        if (isset($medios[$ext])) { return $medios[$ext]; }

        $info = @getimagesize($ruta);
        $tipo = $info['mime'] ?? 'image/jpeg';
        if ($reconvertida && $tipo !== 'image/png') { return 'image/jpeg'; }
        return $tipo;
    }

    // ================================================================
    // LO QUE VE EL USUARIO AL ENTRAR
    // ================================================================

    /**
     * Un boletín concreto, para quien lo va a ver.
     *
     * Lo usa la pantalla cuando le llega el aviso de que le han lanzado uno:
     * a diferencia de misBoletines, no mira la vigencia, porque el
     * administrador puede lanzar a mano uno programado o ya caducado. Lo que
     * sí se comprueba, en la base, es que esté activo y que quien pregunta
     * sea destinatario.
     */
    public function miBoletin(Request $request, $id)
    {
        try {
            $u = auth('api')->user();
            $result = DB::selectOne(
                'SELECT core.fn_boletines_mio(?::BIGINT, ?::BIGINT) as result',
                [(int) $id, $u->id ?? null]
            );
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en miBoletin', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener el boletín', 500);
        }
    }

    public function misBoletines(Request $request)
    {
        try {
            $u = auth('api')->user();
            $result = DB::selectOne('SELECT core.fn_boletines_mios(?::BIGINT) as result', [$u->id ?? null]);
            $datos = json_decode($result->result, true);
            return $this->successResponse($datos['data'], $datos['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en misBoletines', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener los boletines', 500);
        }
    }

    public function marcarVisto(Request $request, $id)
    {
        try {
            $u = auth('api')->user();
            $result = DB::selectOne(
                'SELECT core.fn_boletines_marcar_visto(?::BIGINT, ?::BIGINT, ?::BOOLEAN) as result',
                [(int) $id, $u->id ?? null, filter_var($request->input('no_mostrar', false), FILTER_VALIDATE_BOOLEAN)]
            );
            $datos = json_decode($result->result, true);
            return $this->successResponse(null, $datos['message']);
        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en marcarVisto', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al registrar la lectura', 500);
        }
    }
}
