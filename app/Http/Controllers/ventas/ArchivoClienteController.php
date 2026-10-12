<?php

namespace App\Http\Controllers\ventas;

use App\Http\Controllers\Controller;
use App\Http\Controllers\config\ArchivoController;
use App\Http\Resources\ApiResponder;
use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use Tymon\JWTAuth\Facades\JWTAuth;

/**
 * Los archivos de un cliente: fotos del local, el RUC escaneado, el contrato,
 * un video de la visita.
 *
 * Los ficheros van a storage/app/public/img/clientes, la misma carpeta donde
 * ya están la foto y el mapa del cliente, y en la tabla queda sólo el NOMBRE
 * del fichero: así cambiar de dominio o de servidor no obliga a reescribir
 * ninguna fila.
 *
 * Los adjuntos de una GESTIÓN van aparte, a img/clientes/gestiones. No es
 * manía de ordenar: la carpeta del cliente es la que se mira cuando alguien
 * pregunta «qué documentos tenemos de este cliente», y mezclar ahí todo lo que
 * se mandó por WhatsApp en un año la vuelve inservible. Son dos cosas
 * distintas y se guardan en dos sitios distintos.
 *
 * Los que se subieron antes de ese cambio siguen en la carpeta de siempre, así
 * que para leer y para borrar se busca en las dos (ver rutaDeFichero).
 *
 *   GET    ventas/archivoCliente/allArchivos?cliente_id=  los del cliente
 *   POST   ventas/archivoCliente/subirArchivo             { cliente_id, archivo }  sólo sube
 *   POST   ventas/archivoCliente/addArchivo               crea el registro
 *   POST   ventas/archivoCliente/editArchivo/{id}         nombre, descripción, orden, activo
 *   DELETE ventas/archivoCliente/deleteArchivo/{id}       registro + fichero
 *   GET    ventas/archivoCliente/ver/{id}?t=<token>       sirve el fichero
 *
 * Subir y crear el registro van separados, como en el administrador de
 * archivos: así la pantalla puede enseñar el progreso de cada fichero y, si
 * algo falla al guardar la descripción, no se queda un registro apuntando a un
 * fichero que no se subió.
 */
class ArchivoClienteController extends Controller
{
    use ApiResponder;

    /** La misma carpeta donde ClienteController guarda la foto y el mapa. */
    private const CARPETA = 'img/clientes';

    /** Lo adjuntado a una gestión, aparte de los documentos del cliente. */
    private const CARPETA_GESTIONES = 'img/clientes/gestiones';

    /** Qué carpeta le toca a un fichero según de dónde venga. */
    private static function carpetaDe(?string $origen): string
    {
        return $origen === 'gestion' ? self::CARPETA_GESTIONES : self::CARPETA;
    }

    /**
     * Dónde está de verdad un fichero.
     *
     * Primero donde le toca por su origen y, si no está, en la otra carpeta:
     * los adjuntos de gestión subidos antes de que existiera img/clientes/
     * gestiones siguen en la carpeta del cliente, y tienen que poder abrirse y
     * borrarse igual. Devuelve null si no está en ninguna.
     */
    private static function rutaDeFichero(?string $archivo, ?string $origen): ?string
    {
        if (!$archivo) { return null; }

        foreach ([self::carpetaDe($origen), self::CARPETA, self::CARPETA_GESTIONES] as $carpeta) {
            $ruta = storage_path('app/public/' . $carpeta . '/' . $archivo);
            if (file_exists($ruta)) { return $ruta; }
        }
        return null;
    }

    /** SQLSTATE de las funciones → código HTTP. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,  // falta un dato obligatorio
        'P0013' => 404,  // no existe
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    public function __construct()
    {
        // 'ver' queda fuera del middleware, pero NO es pública: la usan <img src>
        // y <video src>, que no mandan cabeceras, así que el token llega por la
        // url (?t=) y se comprueba a mano dentro. Ver quienPuedeVer().
        $this->middleware('auth:api')->except(['ver']);
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

    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    // ================================================================
    // LISTAR
    // ================================================================

    public function allArchivos(Request $request)
    {
        try {
            // Con ?gestion_id= se piden los adjuntos de esa gestión y el cliente
            // sobra: la gestión ya sabe de quién es.
            $gestionId = (int) $request->query('gestion_id');
            $clienteId = (int) $request->query('cliente_id');
            if (!$clienteId && !$gestionId) {
                return $this->errorResponse('Debe indicar el cliente', 422);
            }
            $incluirInactivos = filter_var($request->query('inactivos', true), FILTER_VALIDATE_BOOLEAN);
            // Por defecto sólo los de la pestaña: las imágenes pegadas en una nota
            // y los adjuntos de una gestión viven aquí para no quedar huérfanos,
            // pero no son documentos del cliente. ?origen=todos los trae también.
            $origen = (string) $request->query('origen', 'archivo');
            $origen = in_array($origen, ['archivo', 'nota', 'gestion'], true) ? $origen : null;

            // Quién pregunta, que es lo que decide qué archivos de ese cliente
            // se le devuelven. No es opcional: la función falla cerrado y sin
            // usuario no devuelve ninguno.
            $quien = auth('api')->id();

            $result = DB::selectOne(
                'SELECT ventas.fn_archivos_clientes_listar(?::BIGINT, ?::BOOLEAN, ?::VARCHAR, ?::BIGINT, ?::BIGINT) as result',
                [$clienteId ?: null, $incluirInactivos, $origen, $gestionId ?: null, $quien]
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allArchivos de cliente', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener los archivos', 500);
        }
    }

    // ================================================================
    // SUBIR (sólo deja el fichero en disco)
    // ================================================================

    /**
     * Guarda el fichero y devuelve con qué nombre quedó.
     *
     * El nombre lleva el id del cliente delante y un sufijo aleatorio:
     * <cliente>_<slug>-<fecha>-<azar>.<ext>. Con el id delante se sabe de quién
     * es un fichero mirando la carpeta; con el azar, dos «cedula.jpg» no se
     * pisan. No crea el registro: eso es addArchivo.
     *
     * El tipo se deduce de la EXTENSIÓN, no del contenido, reutilizando la
     * tabla del administrador de archivos: un .xlsx es un ZIP por dentro y la
     * regla `mimes:` de Laravel lo clasificaría mal.
     *
     * Con origen=gestion el fichero va a img/clientes/gestiones. El origen se
     * manda al SUBIR y no sólo al crear el registro porque para entonces el
     * fichero ya está escrito: decidirlo después obligaría a moverlo.
     */
    public function subirArchivo(Request $request)
    {
        try {
            if (!$request->hasFile('archivo') || !$request->file('archivo')->isValid()) {
                // Si supera post_max_size, PHP descarta la petición entera y aquí
                // no llega ni el fichero: el mensaje lo explica.
                return $this->errorResponse('No se recibió el archivo. Si es muy grande, revise upload_max_filesize y post_max_size en php.ini', 422);
            }

            $clienteId = (int) $request->input('cliente_id');
            if (!$clienteId) {
                return $this->errorResponse('Debe indicar el cliente', 422);
            }
            $existe = DB::selectOne('SELECT id FROM ventas.clientes WHERE id = ? AND deleted_at IS NULL', [$clienteId]);
            if (!$existe) {
                return $this->errorResponse('El cliente no existe o está en la papelera', 404);
            }

            $origen  = $request->input('origen') === 'gestion' ? 'gestion' : null;
            $carpeta = self::carpetaDe($origen);

            $fichero   = $request->file('archivo');
            $extension = strtolower($fichero->getClientOriginalExtension());
            if ($extension === '') {
                return $this->errorResponse('El archivo no tiene extensión; no se puede clasificar', 422);
            }

            $base   = Str::slug(pathinfo($fichero->getClientOriginalName(), PATHINFO_FILENAME)) ?: 'archivo';
            $nombre = $clienteId . '_' . substr($base, 0, 50) . '-' . date('Ymd-His') . '-' . Str::lower(Str::random(6)) . '.' . $extension;

            // storeAs crea la carpeta si no existe, así que la primera gestión con
            // adjunto es la que estrena img/clientes/gestiones
            if (!$fichero->storeAs('public/' . $carpeta, $nombre)) {
                return $this->errorResponse('No se pudo guardar el archivo en el servidor', 500);
            }
            $ruta = storage_path('app/public/' . $carpeta . '/' . $nombre);
            if (!file_exists($ruta) || filesize($ruta) === 0) {
                // Un fichero de 0 bytes es que la subida se cortó o venía vacío. Se
                // quita antes de rendirse: si no, la carpeta se va llenando de
                // restos que no apuntan a ninguna fila y nadie se atreve a borrar.
                if (file_exists($ruta)) { @unlink($ruta); }
                return $this->errorResponse('El archivo llegó vacío o se cortó la subida. Inténtalo de nuevo.', 422);
            }

            return $this->successResponse([
                'archivo'         => $nombre,
                'tipo'            => ArchivoController::tipoPorExtension($extension),
                'nombre_original' => $fichero->getClientOriginalName(),
                'extension'       => $extension,
                'mime'            => $fichero->getClientMimeType(),
                'tamano'          => $fichero->getSize(),
            ], 'Archivo subido');

        } catch (Exception $e) {
            sistemaLog('error', 'Error al subir archivo de cliente', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al subir el archivo', 500);
        }
    }

    // ================================================================
    // REGISTRO
    // ================================================================

    public function addArchivo(Request $request)
    {
        return $this->guardar($request, null);
    }

    public function editArchivo(Request $request, $id)
    {
        return $this->guardar($request, (int) $id);
    }

    private function guardar(Request $request, ?int $id)
    {
        try {
            $reglas = [
                'nombre'      => 'required|string|min:1|max:150',
                'descripcion' => 'nullable|string|max:4000',
                'orden'       => 'nullable|integer|min:0|max:99999',
                'activo'      => 'nullable|boolean',
            ];
            if ($id === null) {
                // Al crear hace falta saber de quién es y qué fichero se subió
                $reglas['cliente_id'] = 'required|integer';
                $reglas['archivo']    = 'required|string|max:200';
                $reglas['tipo']       = 'nullable|string|max:20';
                $reglas['extension']  = 'nullable|string|max:20';
                $reglas['mime']       = 'nullable|string|max:120';
                $reglas['tamano']     = 'nullable|integer|min:0';
                $reglas['origen']     = 'nullable|string|in:archivo,nota,gestion';
                $reglas['gestion_id'] = 'nullable|integer';
            }

            $validator = Validator::make($this->datosDe($request), $reglas, [
                'nombre.required'     => 'El nombre del archivo es obligatorio',
                'cliente_id.required' => 'Debe indicar el cliente',
                'archivo.required'    => 'Falta el fichero subido',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_archivos_clientes_guardar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::TEXT, ?::VARCHAR, '
                . '?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::BIGINT, ?::INTEGER, ?::BOOLEAN, ?::VARCHAR, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id,
                    isset($d['cliente_id']) ? (int) $d['cliente_id'] : null,
                    $d['nombre'],
                    $d['descripcion'] ?? null,
                    $d['archivo'] ?? null,
                    $d['tipo'] ?? 'otro',
                    $d['extension'] ?? null,
                    $d['mime'] ?? null,
                    isset($d['tamano']) ? (int) $d['tamano'] : null,
                    isset($d['orden']) ? (int) $d['orden'] : null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                    $d['origen'] ?? 'archivo',
                    isset($d['gestion_id']) ? (int) $d['gestion_id'] : null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Archivo de cliente guardado', ['archivo_id' => $r['data']['id'] ?? null, 'cliente_id' => $d['cliente_id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'archivo de cliente rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al guardar archivo de cliente', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar el archivo', 500);
        }
    }

    /**
     * Borra el registro y, sólo si la fila se fue, el fichero del disco.
     *
     * En ese orden: si se borrara el fichero primero y la fila fallara, la
     * pestaña quedaría mostrando un archivo que ya no existe.
     */
    public function deleteArchivo(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_archivos_clientes_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            $archivo = $r['data']['archivo'] ?? null;
            $ruta    = self::rutaDeFichero($archivo, $r['data']['origen'] ?? null);
            if ($ruta) { @unlink($ruta); }

            sistemaLog('info', 'Archivo de cliente eliminado', ['archivo_id' => $id, 'archivo' => $archivo]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteArchivo de cliente rechazado', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al eliminar archivo de cliente', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al eliminar el archivo', 500);
        }
    }

    // ================================================================
    // SERVIR EL FICHERO
    // ================================================================

    /**
     * Devuelve el fichero. Va sin jwt porque la consumen <img src> y
     * <video src>, que no mandan cabeceras —es el mismo trato que ya tienen
     * getImagenCliente y getFotoUbicacion—.
     *
     * Con ?descargar=1 fuerza la descarga con el nombre que puso el usuario,
     * en vez de abrirlo en el navegador.
     */
    /**
     * Quién pide el fichero, y si puede.
     *
     * El token llega por la url porque quien pide es un <img src>, un <video
     * src> o un <iframe>, y esos no mandan cabeceras. Se acepta también la
     * cabecera de siempre, para quien sí pueda ponerla.
     *
     * QUE EL TOKEN VAYA EN LA URL TIENE UN COSTE: queda en el historial del
     * navegador y en los registros del servidor. Se acepta aquí porque la
     * alternativa —enlaces firmados con caducidad— obliga a que el servidor
     * acuñe una url por fichero y a cambiar los tres sitios que las construyen;
     * es la mejora siguiente, no la primera.
     *
     * Devuelve el usuario, o null si no hay sesión válida.
     */
    private function quienPide(Request $request)
    {
        $token = $request->query('t') ?: $request->bearerToken();
        if (!$token) { return null; }

        try {
            return JWTAuth::setToken($token)->authenticate() ?: null;
        } catch (Exception $e) {
            return null;
        }
    }

    /**
     * ¿Ese usuario puede ver los ficheros de ese cliente?
     *
     * La misma regla que decide qué clientes se ven en la lista: los de la
     * gente a cargo (el propio usuario y los grupos por debajo del suyo), y
     * todo si su grupo es administrador. Reusar la función de ventas es lo que
     * evita que dentro de un mes la lista diga una cosa y los ficheros otra.
     */
    private function puedeVerCliente($usuario, $clienteId): bool
    {
        if (!$usuario || !$clienteId) { return false; }

        $fila = DB::selectOne(
            'SELECT COALESCE(g.es_administrador, false) AS admin
               FROM seguridad.users u
               LEFT JOIN seguridad.grupos g ON g.id = u.grupo_id
              WHERE u.id = ?',
            [(int) $usuario->id]
        );
        if ($fila && $fila->admin) { return true; }

        $puede = DB::selectOne(
            'SELECT ventas.fn_cliente_es_de_alguno(?::BIGINT, ventas.fn_usuarios_a_cargo(?::BIGINT)) AS si',
            [(int) $clienteId, (int) $usuario->id]
        );
        return (bool) ($puede->si ?? false);
    }

    /**
     * ¿Y ese fichero concreto, se lo deja ver su perfil?
     *
     * Son dos reglas distintas según de dónde salió el fichero:
     *
     *   colgado de una gestión  manda la gestión. Un adjunto es parte de ella,
     *                           no un documento del cliente: si se ve la
     *                           gestión se ven sus adjuntos, y si no, ninguno.
     *   pegado en una nota      el dato NOTA, que es lo que lo contiene.
     *   de la pestaña Archivos  el dato ARCHIVO.
     *
     * Con la tabla de visibilidad vacía las tres dicen sí, que es lo de hoy.
     */
    private function puedeVerArchivo($usuario, $fila): bool
    {
        if (!empty($fila->gestion_id)) {
            $r = DB::selectOne(
                'SELECT ventas.fn_gestion_visible_para(?::BIGINT, ?::BIGINT) AS si',
                [(int) $fila->gestion_id, (int) $usuario->id]
            );
            return (bool) ($r->si ?? false);
        }

        $r = DB::selectOne(
            'SELECT seguridad.fn_puede_ver(?::BIGINT, ?::VARCHAR, ?::BIGINT) AS si',
            [
                (int) $usuario->id,
                $fila->origen === 'nota' ? 'NOTA' : 'ARCHIVO',
                $fila->usuario_id !== null ? (int) $fila->usuario_id : null,
            ]
        );
        return (bool) ($r->si ?? false);
    }

    public function ver(Request $request, $id)
    {
        try {
            $usuario = $this->quienPide($request);
            if (!$usuario) {
                return $this->errorResponse('Hay que iniciar sesión para ver este archivo', 401);
            }

            $fila = DB::selectOne(
                'SELECT nombre, archivo, mime, extension, origen, cliente_id, gestion_id, usuario_id
                   FROM ventas.archivos_clientes WHERE id = ?',
                [(int) $id]
            );
            if (!$fila) {
                return $this->errorResponse('El archivo no existe', 404);
            }

            // Antes esto no se miraba: con el id a mano, cualquiera se llevaba
            // el fichero de cualquier cliente sin siquiera tener sesión.
            if (!$this->puedeVerCliente($usuario, $fila->cliente_id)) {
                sistemaLog('warning', 'Intento de ver un archivo de otro cliente', [
                    'archivo_id' => $id, 'usuario_id' => $usuario->id ?? null,
                ]);
                return $this->errorResponse('Este archivo no es de un cliente tuyo', 403);
            }

            // Y la segunda pregunta: dentro del cliente, ¿este fichero es de
            // los que le toca ver? Sin esto, tapar un adjunto en la lista no
            // serviría de nada —el enlace directo seguiría dándolo—, que es
            // exactamente la fuga que se acaba de cerrar, una puerta más allá.
            if (!$this->puedeVerArchivo($usuario, $fila)) {
                sistemaLog('warning', 'Intento de ver un archivo fuera de su visibilidad', [
                    'archivo_id' => $id, 'usuario_id' => $usuario->id ?? null,
                ]);
                return $this->errorResponse('Este archivo no está a su alcance', 403);
            }

            $ruta = self::rutaDeFichero($fila->archivo, $fila->origen);
            if (!$ruta) {
                return $this->errorResponse('El archivo ya no está en el servidor', 404);
            }

            if (filter_var($request->query('descargar', false), FILTER_VALIDATE_BOOLEAN)) {
                $comoSeLlama = $fila->nombre . ($fila->extension ? '.' . $fila->extension : '');
                return response()->download($ruta, $comoSeLlama);
            }

            return response()->file($ruta, $fila->mime ? ['Content-Type' => $fila->mime] : []);

        } catch (Exception $e) {
            sistemaLog('error', 'Error al servir archivo de cliente', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al abrir el archivo', 500);
        }
    }
}
