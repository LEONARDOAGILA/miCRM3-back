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

/**
 * Los archivos de un cliente: fotos del local, el RUC escaneado, el contrato,
 * un video de la visita.
 *
 * Los ficheros van a storage/app/public/img/clientes, la misma carpeta donde
 * ya están la foto y el mapa del cliente, y en la tabla queda sólo el NOMBRE
 * del fichero: así cambiar de dominio o de servidor no obliga a reescribir
 * ninguna fila.
 *
 *   GET    ventas/archivoCliente/allArchivos?cliente_id=  los del cliente
 *   POST   ventas/archivoCliente/subirArchivo             { cliente_id, archivo }  sólo sube
 *   POST   ventas/archivoCliente/addArchivo               crea el registro
 *   POST   ventas/archivoCliente/editArchivo/{id}         nombre, descripción, orden, activo
 *   DELETE ventas/archivoCliente/deleteArchivo/{id}       registro + fichero
 *   GET    ventas/archivoCliente/ver/{id}                 (pública) sirve el fichero
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

    /** SQLSTATE de las funciones → código HTTP. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,  // falta un dato obligatorio
        'P0013' => 404,  // no existe
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    public function __construct()
    {
        // 'ver' queda fuera: la usa <img src> / <video src>, que no mandan cabeceras
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
            $clienteId = (int) $request->query('cliente_id');
            if (!$clienteId) {
                return $this->errorResponse('Debe indicar el cliente', 422);
            }
            $incluirInactivos = filter_var($request->query('inactivos', true), FILTER_VALIDATE_BOOLEAN);
            // Por defecto sólo los de la pestaña: las imágenes pegadas en una nota
            // viven aquí para no quedar huérfanas, pero no son documentos del cliente.
            // ?origen=todos las trae también.
            $origen = (string) $request->query('origen', 'archivo');
            $origen = in_array($origen, ['archivo', 'nota'], true) ? $origen : null;

            $result = DB::selectOne(
                'SELECT ventas.fn_archivos_clientes_listar(?::BIGINT, ?::BOOLEAN, ?::VARCHAR) as result',
                [$clienteId, $incluirInactivos, $origen]
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

            $fichero   = $request->file('archivo');
            $extension = strtolower($fichero->getClientOriginalExtension());
            if ($extension === '') {
                return $this->errorResponse('El archivo no tiene extensión; no se puede clasificar', 422);
            }

            $base   = Str::slug(pathinfo($fichero->getClientOriginalName(), PATHINFO_FILENAME)) ?: 'archivo';
            $nombre = $clienteId . '_' . substr($base, 0, 50) . '-' . date('Ymd-His') . '-' . Str::lower(Str::random(6)) . '.' . $extension;

            if (!$fichero->storeAs('public/' . self::CARPETA, $nombre)) {
                return $this->errorResponse('No se pudo guardar el archivo en el servidor', 500);
            }
            $ruta = storage_path('app/public/' . self::CARPETA . '/' . $nombre);
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
                $reglas['origen']     = 'nullable|string|in:archivo,nota';
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
                . '?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::BIGINT, ?::INTEGER, ?::BOOLEAN, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
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
            if ($archivo) {
                $ruta = 'public/' . self::CARPETA . '/' . $archivo;
                if (Storage::exists($ruta)) { Storage::delete($ruta); }
            }

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
    public function ver(Request $request, $id)
    {
        try {
            $fila = DB::selectOne(
                'SELECT nombre, archivo, mime, extension FROM ventas.archivos_clientes WHERE id = ?',
                [(int) $id]
            );
            if (!$fila) {
                return $this->errorResponse('El archivo no existe', 404);
            }

            $ruta = storage_path('app/public/' . self::CARPETA . '/' . $fila->archivo);
            if (!file_exists($ruta)) {
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
