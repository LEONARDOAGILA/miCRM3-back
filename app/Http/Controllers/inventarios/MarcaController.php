<?php

namespace App\Http\Controllers\inventarios;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * CRUD de marcas (inventarios.marcas).
 *
 * Mismo esquema que rh\CargoController: toda la lógica vive en las funciones
 * PL/pgSQL inventarios.fn_marcas_* (validaciones, auditoría, transacción);
 * aquí sólo se valida la entrada, se llama a la función con el contexto del
 * usuario autenticado y se traduce la respuesta.
 *
 *   GET    inventarios/marca/allMarcas?page&per_page&search   listado paginado
 *   GET    inventarios/marca/listMarcas[?activos=0]           lista simple (combos)
 *   GET    inventarios/marca/findByIdMarca/{id}
 *   POST   inventarios/marca/addMarca
 *   POST   inventarios/marca/editMarca/{id}
 *   POST   inventarios/marca/activarMarca/{id}                { activo? }; sin ella, alterna
 *   DELETE inventarios/marca/deleteMarca/{id}
 *   POST   inventarios/marca/addLogo                          { MarcaId, imagen_file }
 *   GET    inventarios/marca/getLogo/{id}                     (pública, la usa <img src>)
 */
class MarcaController extends Controller
{
    use ApiResponder;

    /** Dónde viven los logos dentro de storage/app/public. */
    private const CARPETA_LOGOS = 'img/marcas';

    /**
     * SQLSTATE que usan las funciones del módulo para las reglas de negocio.
     * Son errores del usuario, no fallos del servidor: se responden como 4xx.
     */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0006' => 409,   // nombre duplicado
        'P0013' => 404,   // la marca no existe
        'P0014' => 409,   // no se puede eliminar: tiene productos
        'P0015' => 422,   // valor inválido
        'P0016' => 422,   // la referencia no existe
    ];

    public function __construct()
    {
        // getLogo va suelta (la pide <img src> sin cabeceras); el resto, con token
        $this->middleware('auth:api')->except(['getLogo']);
    }

    // ================================================================
    // AYUDANTES
    // ================================================================

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

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    /** Los seis argumentos de auditoría que esperan todas las funciones. */
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

    /**
     * Cuerpo de la petición: JSON plano, o el envoltorio { json: "…" } que
     * usan los formularios que mandan FormData. Se admiten los dos.
     */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    /** Reglas de validación comunes a crear y modificar. */
    private function reglas(): array
    {
        return [
            'nombre'      => 'required|string|min:2|max:100',
            'descripcion' => 'nullable|string|max:2000',
            'pais_origen' => 'nullable|string|max:60',
            'sitio_web'   => 'nullable|string|max:200',
            'activo'      => 'nullable|boolean',
        ];
    }

    private function mensajes(): array
    {
        return [
            'nombre.required' => 'El nombre de la marca es obligatorio',
            'nombre.min'      => 'El nombre debe tener al menos 2 caracteres',
            'nombre.max'      => 'El nombre no puede superar los 100 caracteres',
            'sitio_web.max'   => 'El sitio web no puede superar los 200 caracteres',
        ];
    }

    /** Los cinco datos de la marca, en el orden de las funciones. */
    private function parametros(array $d): array
    {
        return [
            $d['nombre'],
            $d['descripcion'] ?? null,
            $d['pais_origen'] ?? null,
            $d['sitio_web'] ?? null,
            array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
        ];
    }

    /** Borra un logo de storage por su nombre; se calla si ya no está. */
    private function borrarLogo(?string $archivo): void
    {
        if (!$archivo) { return; }
        $ruta = storage_path('app/public/' . self::CARPETA_LOGOS . '/' . $archivo);
        if (is_file($ruta)) { @unlink($ruta); }
    }

    // ================================================================
    // LISTAR
    // ================================================================

    public function allMarcas(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_marcas_listar_paginado(?::INTEGER, ?::INTEGER, ?::TEXT) as result',
                [(int) $request->input('page', 1),
                 (int) $request->input('per_page', 15),
                 (string) $request->input('search', '')]
            );
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'], 500);
            }
            return $this->successResponse($r, 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allMarcas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function listMarcas(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $result = DB::selectOne('SELECT inventarios.fn_marcas_listar(?::BOOLEAN) as result', [$soloActivos]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listMarcas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdMarca($id)
    {
        try {
            $result = DB::selectOne('SELECT inventarios.fn_marcas_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdMarca', ['message' => $e->getMessage(), 'marca_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addMarca(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_marcas_crear(?::VARCHAR, ?::TEXT, ?::VARCHAR, ?::VARCHAR, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge($this->parametros($d), $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Marca creada', ['marca_id' => $r['data']['id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addMarca rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addMarca', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear la marca', 500);
        }
    }

    public function editMarca(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_marcas_modificar(?::BIGINT, ?::VARCHAR, ?::TEXT, ?::VARCHAR, ?::VARCHAR, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->parametros($d), $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Marca actualizada', ['marca_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editMarca rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'marca_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editMarca', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'marca_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar la marca', 500);
        }
    }

    /**
     * Pone `activo` y nada más.
     *
     * Existe aparte de editMarca porque bajar la casilla de la rejilla no
     * tiene por qué revalidar la ficha entera. `activo` es opcional: sin él la
     * función alterna, pero la pantalla manda el valor que quiere para que dos
     * personas pulsando a la vez no se peleen.
     */
    public function activarMarca(Request $request, $id)
    {
        try {
            // El booleano con filter_var: "false" en texto es true a secas
            $activo = $request->exists('activo') && $request->input('activo') !== null && $request->input('activo') !== ''
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE)
                : null;

            $result = DB::selectOne(
                'SELECT inventarios.fn_marcas_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                sistemaLog('warning', 'activarMarca rechazada', ['marca_id' => $id, 'error_code' => $r['error_code'] ?? null]);
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 500);
            }

            sistemaLog('info', 'Marca activada/desactivada', ['marca_id' => $id, 'activo' => $r['data']['activo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarMarca', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'marca_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cambiar el estado de la marca', 500);
        }
    }

    /**
     * Baja de verdad, no lógica.
     *
     * El logo se borra del disco DESPUÉS de que la base haya confirmado: al
     * revés, una transacción que se cae dejaría la fila apuntando a un fichero
     * que ya no está.
     */
    public function deleteMarca(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_marcas_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            $this->borrarLogo($r['data']['logo'] ?? null);

            sistemaLog('info', 'Marca eliminada', ['marca_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteMarca rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'marca_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteMarca', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'marca_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar la marca', 500);
        }
    }

    // ================================================================
    // EL LOGO
    // ================================================================

    /**
     * Sube o reemplaza el logo.
     *
     * NO SE PROCESA LA IMAGEN: en este servidor no está activada la extensión
     * GD, así que el fichero se guarda tal cual llega. Si hay que
     * redimensionar o poner marca de agua, se hace en el navegador antes de
     * subirlo.
     */
    public function addLogo(Request $request)
    {
        DB::beginTransaction();
        try {
            $validator = Validator::make($request->all(), [
                'MarcaId'     => 'required|integer',
                'imagen_file' => 'required|file|image|max:10240',
            ], [
                'MarcaId.required'     => 'Falta la marca',
                'imagen_file.required' => 'No se encontró la imagen para guardar',
                'imagen_file.image'    => 'El archivo debe ser una imagen',
                'imagen_file.max'      => 'La imagen no puede superar los 10 MB',
            ]);
            if ($validator->fails()) {
                DB::rollBack();
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $marcaId = (int) $request->MarcaId;
            $existe = DB::selectOne('SELECT id, logo FROM inventarios.marcas WHERE id = ?', [$marcaId]);
            if (!$existe) {
                DB::rollBack();
                return $this->errorResponse('Marca no encontrada', 404);
            }
            $logoAnterior = $existe->logo;

            $file      = $request->file('imagen_file');
            $extension = strtolower($file->getClientOriginalExtension() ?: 'jpg');
            $filename  = $marcaId . '_marcalogo.' . $extension;

            if (!$file->storeAs('public/' . self::CARPETA_LOGOS, $filename)) {
                DB::rollBack();
                return $this->errorResponse('Error al guardar el archivo', 500);
            }
            $ruta = storage_path('app/public/' . self::CARPETA_LOGOS . '/' . $filename);
            if (!is_file($ruta) || filesize($ruta) === 0) {
                DB::rollBack();
                return $this->errorResponse('El archivo no se guardó correctamente', 500);
            }

            $result = DB::selectOne(
                'SELECT inventarios.fn_marcas_logo(?::BIGINT, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$marcaId, $filename], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            // El logo anterior con OTRO nombre (otra extensión): fuera, y sólo
            // después de que la base haya confirmado
            if ($logoAnterior && $logoAnterior !== $filename) {
                $this->borrarLogo($logoAnterior);
            }
            DB::commit();

            sistemaLog('info', 'Logo de marca guardado', ['marca_id' => $marcaId, 'logo' => $filename]);
            return $this->successResponse([
                'logo'      => $r['data']['logo'],
                'full_path' => asset('storage/' . self::CARPETA_LOGOS . '/' . $r['data']['logo']),
            ], $r['message']);

        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error en addLogo (marca)',
                       ['message' => $e->getMessage(), 'line' => $e->getLine(), 'marca_id' => $request->MarcaId ?? null]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Sirve el fichero del logo. Pública: la pide <img src>, que no manda cabeceras. */
    public function getLogo($id)
    {
        try {
            $r = DB::selectOne('SELECT logo FROM inventarios.marcas WHERE id = ?', [(int) $id]);
            if (!$r || !$r->logo) {
                return $this->errorResponse('La marca no tiene logo', 404);
            }
            $ruta = storage_path('app/public/' . self::CARPETA_LOGOS . '/' . $r->logo);
            if (!is_file($ruta)) {
                return $this->errorResponse('El logo no existe en el servidor', 404);
            }
            return response()->file($ruta, [
                'Content-Type'  => mime_content_type($ruta),
                'Cache-Control' => 'public, max-age=31536000',
            ]);
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
