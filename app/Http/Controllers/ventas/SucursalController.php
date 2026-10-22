<?php

namespace App\Http\Controllers\ventas;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * CRUD de SUCURSALES (ventas.sucursales).
 *
 * Una sucursal es el sitio donde trabaja la gente, y lleva dibujado su
 * PERÍMETRO en el mapa (un polígono, o un círculo con centro y radio). A cada
 * empleado se le asigna la suya y, al marcar asistencia, el servidor sólo le
 * acepta la marcación si está dentro de ese perímetro.
 *
 * Mismo esquema que MarcaController: la lógica vive en las funciones
 * ventas.fn_sucursales_* (validaciones, auditoría, transacción) y aquí sólo
 * se valida la entrada, se llama con el contexto del usuario y se traduce la
 * respuesta.
 *
 *   GET    ventas/sucursal/allSucursales?page&per_page&search&filtros
 *   GET    ventas/sucursal/listSucursales?activas=1        lista simple
 *   GET    ventas/sucursal/findByIdSucursal/{id}
 *   POST   ventas/sucursal/addSucursal
 *   POST   ventas/sucursal/editSucursal/{id}
 *   POST   ventas/sucursal/activarSucursal/{id}            { activo? }; sin ella, alterna
 *   DELETE ventas/sucursal/deleteSucursal/{id}             a la papelera
 *   POST   ventas/sucursal/probarPunto/{id}                { latitud, longitud } ¿cae dentro?
 *   POST   ventas/sucursal/addFoto                         { SucursalId, campo: foto|mapa, imagen_file }
 *   GET    ventas/sucursal/getFoto/{id}/{campo}            la imagen, para <img src>
 *   DELETE ventas/sucursal/quitarFoto/{id}/{campo}
 *   GET    ventas/sucursal/papelera
 *   POST   ventas/sucursal/restaurar            { ids: [...] }
 *   POST   ventas/sucursal/eliminarDefinitivo   { ids: [...] }  (permiso «vaciar»)
 *   DELETE ventas/sucursal/vaciarPapelera                       (permiso «vaciar»)
 */
class SucursalController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;
    use \App\Http\Controllers\Concerns\FiltrosDeColumna;

    /**
     * Por qué columnas deja filtrar la rejilla, y de qué tipo.
     *
     * Lista blanca, no comprobación: el nombre de la columna acaba dentro de
     * una consulta y lo que no esté aquí se tira. `estado` y
     * `tiene_perimetro` son lo que SE VE en la celda, no columnas de la
     * tabla.
     */
    private const COLUMNAS_FILTRABLES = [
        'id'              => 'numero',
        'num_empleados'   => 'numero',
        'codigo'          => 'texto',
        'nombre'          => 'texto',
        'direccion'       => 'texto',
        'telefono'        => 'texto',
        'email'           => 'texto',
        'estado'          => 'texto',
        'tiene_perimetro' => 'texto',
        'created_by'      => 'texto',
        'updated_by'      => 'texto',
        // Las fechas, como texto sobre lo que se ve: «2026-10» busca el mes
        'created_at'      => 'texto',
        'updated_at'      => 'texto',
    ];

    /**
     * SQLSTATE que usan las funciones del módulo para las reglas de negocio.
     * Son errores del usuario, no fallos del servidor: se responden como 4xx.
     */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0006' => 409,   // código o nombre repetido
        'P0013' => 404,   // la sucursal no existe
        'P0015' => 422,   // perímetro inválido
        'P0019' => 404,   // no está en la papelera
        'P0021' => 409,   // tiene empleados asignados
    ];

    public function __construct()
    {
        // getFoto va suelta (la pide un <img src>, que no manda cabeceras);
        // el resto, con token. Sin el `except`, la imagen contesta con un
        // 302 a la pantalla de login y el <img> se ve roto.
        $this->middleware('auth:api')->except(['getFoto']);
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

    /** JSON plano, o el envoltorio { json: "…" } de los formularios FormData. */
    private function datosDe(Request $request): array
    {
        if ($request->filled('json')) {
            $datos = json_decode($request->input('json'), true);
            return is_array($datos) ? $datos : [];
        }
        return $request->all();
    }

    private function reglas(): array
    {
        return [
            'codigo'            => 'required|string|min:2|max:20',
            'nombre'            => 'required|string|min:3|max:150',
            'direccion'         => 'nullable|string|max:250',
            // La escrita a mano, con referencias. Google no la toca.
            'direccion_completa' => 'nullable|string|max:500',
            'telefono'          => 'nullable|string|max:50',
            'email'             => 'nullable|email|max:150',
            'tipo'              => 'nullable|string|in:POLIGONO,CIRCULO,poligono,circulo',
            'color'             => 'nullable|string|max:20',
            // El polígono: [{lat, lng}, …]. El mínimo de tres lo exige la función.
            'vertices'          => 'nullable|array',
            'vertices.*.lat'    => 'required_with:vertices|numeric|between:-90,90',
            'vertices.*.lng'    => 'required_with:vertices|numeric|between:-180,180',
            'centro_lat'        => 'nullable|numeric|between:-90,90',
            'centro_lng'        => 'nullable|numeric|between:-180,180',
            'radio_metros'      => 'nullable|numeric|min:1|max:100000',
            'tolerancia_metros' => 'nullable|numeric|min:0|max:5000',
            'activo'            => 'nullable|boolean',
            // El punto de la sucursal (la puerta). Si no viene, la función lo
            // deduce del perímetro.
            'latitud'           => 'nullable|numeric|between:-90,90',
            'longitud'          => 'nullable|numeric|between:-180,180',
        ];
    }

    private function mensajes(): array
    {
        return [
            'codigo.required' => 'El código de la sucursal es obligatorio',
            'codigo.min'      => 'El código debe tener al menos 2 caracteres',
            'nombre.required' => 'El nombre de la sucursal es obligatorio',
            'nombre.min'      => 'El nombre debe tener al menos 3 caracteres',
            'email.email'     => 'El correo no tiene un formato válido',
            'direccion.max'            => 'La dirección no puede superar los 250 caracteres',
            'direccion_completa.max'   => 'La dirección completa no puede superar los 500 caracteres',
            'radio_metros.max'      => 'El radio no puede superar los 100 km',
            'tolerancia_metros.max' => 'La tolerancia no puede superar los 5 km',
        ];
    }

    /** Los datos de la ficha, en el orden que esperan crear y modificar. */
    private function parametros(array $d): array
    {
        $num = fn ($v) => ($v === null || $v === '') ? null : $v;

        return [
            $d['codigo'],
            $d['nombre'],
            $num($d['direccion'] ?? null),
            $num($d['direccion_completa'] ?? null),
            $num($d['telefono'] ?? null),
            $num($d['email'] ?? null),
            strtoupper($d['tipo'] ?? 'POLIGONO'),
            $num($d['color'] ?? null) ?? '#348FE2',
            // El polígono viaja como JSON; la función lo valida
            isset($d['vertices']) && is_array($d['vertices']) && count($d['vertices'])
                ? json_encode(array_values($d['vertices']))
                : null,
            $num($d['centro_lat'] ?? null),
            $num($d['centro_lng'] ?? null),
            $num($d['radio_metros'] ?? null),
            $num($d['tolerancia_metros'] ?? null) ?? 50,
            array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
            // El punto de la sucursal; nulo = que lo deduzca del perímetro
            $num($d['latitud'] ?? null),
            $num($d['longitud'] ?? null),
        ];
    }

    // codigo, nombre, direccion, direccion_completa, telefono, email, tipo,
    // color, vertices, centro_lat, centro_lng, radio, tolerancia, activo,
    // latitud, longitud  (el mismo orden que `parametros`)
    private const CASTS_DATOS = '?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR,
                                 ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::JSONB, ?::NUMERIC,
                                 ?::NUMERIC, ?::NUMERIC, ?::NUMERIC, ?::BOOLEAN, ?::NUMERIC,
                                 ?::NUMERIC';

    // ================================================================
    // LISTAR
    // ================================================================

    /** El listado de la pantalla: paginado, con buscador y filtros de columna. */
    public function allSucursales(Request $request)
    {
        try {
            // Los filtros se aplican en el SERVIDOR porque la pantalla pagina:
            // ag-Grid sólo tiene las filas de la página.
            $filtros = $this->filtrosDeColumna($request->input('filtros'), self::COLUMNAS_FILTRABLES);

            $result = DB::selectOne(
                'SELECT ventas.fn_sucursales_listar_paginado(?::INTEGER, ?::INTEGER, ?::TEXT, ?::JSONB) as result',
                [(int) $request->input('page', 1),
                 (int) $request->input('per_page', 15),
                 (string) $request->input('search', ''),
                 json_encode((object) $filtros)]
            );
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'], 500);
            }
            return $this->successResponse($r, 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allSucursales', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Lista simple, para los desplegables (asignar la sucursal a un empleado). */
    public function listSucursales(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_sucursales_listar(?::BOOLEAN) as result',
                [$request->input('activas', '1') === '1']
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar', 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listSucursales', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdSucursal($id)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_sucursales_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdSucursal', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * ¿Ese punto cae dentro del perímetro?
     *
     * Lo usa la pantalla para probar el dibujo antes de guardarlo, y es el
     * mismo cálculo que decide si una marcación entra o no.
     */
    public function probarPunto(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);
            $result = DB::selectOne(
                'SELECT ventas.fn_sucursales_contiene(?::BIGINT, ?::NUMERIC, ?::NUMERIC) as result',
                [(int) $id,
                 isset($d['latitud'])  && $d['latitud']  !== '' ? (float) $d['latitud']  : null,
                 isset($d['longitud']) && $d['longitud'] !== '' ? (float) $d['longitud'] : null]
            );
            return $this->successResponse(json_decode($result->result, true), 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en probarPunto', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addSucursal(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_sucursales_crear(' . self::CASTS_DATOS . ', ' . self::CASTS_AUDIT . ') as result',
                array_merge($this->parametros($d), $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Sucursal creada', ['nombre' => $d['nombre'], 'codigo' => $d['codigo']]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addSucursal', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function editSucursal(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_sucursales_modificar(?::BIGINT, ' . self::CASTS_DATOS . ', ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->parametros($d), $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Sucursal actualizada', ['id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editSucursal', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Enciende o apaga; sin `activo` en el cuerpo, alterna. */
    public function activarSucursal(Request $request, $id)
    {
        try {
            $datos = $this->datosDe($request);
            $activo = array_key_exists('activo', $datos) ? (bool) $datos['activo'] : null;

            $result = DB::selectOne(
                'SELECT ventas.fn_sucursales_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarSucursal', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** A la papelera (borrado lógico). */
    public function deleteSucursal(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_sucursales_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Sucursal enviada a la papelera', ['id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteSucursal', ['message' => $e->getMessage(), 'id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================

    public function papelera(Request $request)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_sucursales_papelera_listar() as result');
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de sucursales', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function restaurar(Request $request)
    {
        return $this->accionPapelera($request, 'ventas.fn_sucursales_restaurar', 'restaurar');
    }

    public function eliminarDefinitivo(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar», que es
        // otro distinto de «papelera». Se comprueba AQUÍ y no sólo en el
        // front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allSucursales', 'vaciar',
                'No tiene permiso para eliminar definitivamente sucursales')) {
            return $no;
        }

        return $this->accionPapelera($request, 'ventas.fn_sucursales_eliminar_definitivo', 'eliminarDefinitivo');
    }

    public function vaciarPapelera(Request $request)
    {
        if ($no = $this->exigirPermiso('allSucursales', 'vaciar',
                'No tiene permiso para vaciar la papelera de sucursales')) {
            return $no;
        }

        return $this->accionPapelera($request, 'ventas.fn_sucursales_papelera_vaciar', 'vaciarPapelera', false);
    }

    /** El tronco común de restaurar / eliminar definitivo / vaciar. */
    private function accionPapelera(Request $request, string $funcion, string $nombre, bool $conIds = true)
    {
        try {
            $auditoria = $this->auditoria($request);

            if ($conIds) {
                $datos = $this->datosDe($request);
                $ids = array_values(array_filter(array_map('intval', (array) ($datos['ids'] ?? []))));
                if (empty($ids)) {
                    return $this->errorResponse('No se indicó ninguna sucursal', 422);
                }
                $result = DB::selectOne(
                    "SELECT $funcion(?::JSONB, " . self::CASTS_AUDIT . ') as result',
                    array_merge([json_encode($ids)], $auditoria)
                );
            } else {
                $result = DB::selectOne(
                    "SELECT $funcion(" . self::CASTS_AUDIT . ') as result',
                    $auditoria
                );
            }

            $r = json_decode($result->result, true);

            // Ya borradas de la base: fuera sus imágenes del disco. La base
            // devuelve los nombres porque ella no puede tocar el sistema de
            // ficheros; es lo mismo que hace la papelera de marcas.
            foreach ($r['data']['ficheros'] ?? [] as $fichero) {
                $this->borrarImagen($fichero);
            }

            sistemaLog('info', "Papelera de sucursales: $nombre", ['data' => $r['data'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', "Error en $nombre de sucursales", ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // LAS IMÁGENES: LA FOTO DEL LOCAL Y LA CAPTURA DEL MAPA
    // ================================================================
    //
    // Dos imágenes por sucursal, cada una en su columna:
    //
    //   campo=foto   una foto del local, de la galería o de la cámara.
    //   campo=mapa   la captura del mapa con el perímetro dibujado. La saca
    //                el navegador de la Maps Static API, porque el mapa se
    //                pinta con imágenes de otro dominio y no se puede volcar
    //                a un canvas.
    //
    // EN LA BASE SÓLO VA EL NOMBRE DEL FICHERO; el fichero vive en
    // storage/app/public/img/sucursales, como el logo de las marcas. Aquí NO
    // se toca la imagen (ni se recorta ni se marca): este servidor no tiene
    // la extensión GD, así que lo que llega es lo que se guarda.

    /** Dónde viven las imágenes de las sucursales. */
    private const CARPETA_IMAGENES = 'img/sucursales';

    /** Los dos campos de imagen, con el sufijo que lleva su fichero. */
    private const CAMPOS_IMAGEN = ['foto' => '_sucfoto', 'mapa' => '_sucmapa'];

    private function borrarImagen(?string $archivo): void
    {
        if (!$archivo) { return; }
        $ruta = storage_path('app/public/' . self::CARPETA_IMAGENES . '/' . $archivo);
        if (is_file($ruta)) { @unlink($ruta); }
    }

    /**
     * Guarda la foto del local o la captura del mapa.
     *
     * Va aparte de editSucursal porque el fichero necesita el id, y al crear
     * todavía no existe: la pantalla guarda primero y sube la imagen después,
     * igual que el logo de una marca.
     */
    public function addFoto(Request $request)
    {
        DB::beginTransaction();
        try {
            $validator = Validator::make($request->all(), [
                'SucursalId'  => 'required|integer',
                'campo'       => 'required|in:foto,mapa',
                'imagen_file' => 'required|file|image|max:10240',
            ], [
                'SucursalId.required'  => 'Falta la sucursal',
                'campo.in'             => 'La imagen debe ser «foto» o «mapa»',
                'imagen_file.required' => 'No se encontró la imagen para guardar',
                'imagen_file.image'    => 'El archivo debe ser una imagen',
                'imagen_file.max'      => 'La imagen no puede superar los 10 MB',
            ]);
            if ($validator->fails()) {
                DB::rollBack();
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $id    = (int) $request->SucursalId;
            $campo = $request->campo;

            $existe = DB::selectOne('SELECT id, foto, mapa_foto FROM ventas.sucursales WHERE id = ?', [$id]);
            if (!$existe) {
                DB::rollBack();
                return $this->errorResponse('Sucursal no encontrada', 404);
            }
            $anterior = $campo === 'foto' ? $existe->foto : $existe->mapa_foto;

            $file      = $request->file('imagen_file');
            $extension = strtolower($file->getClientOriginalExtension() ?: 'png');
            $filename  = $id . self::CAMPOS_IMAGEN[$campo] . '.' . $extension;

            if (!$file->storeAs('public/' . self::CARPETA_IMAGENES, $filename)) {
                DB::rollBack();
                return $this->errorResponse('Error al guardar el archivo', 500);
            }
            $ruta = storage_path('app/public/' . self::CARPETA_IMAGENES . '/' . $filename);
            if (!is_file($ruta) || filesize($ruta) === 0) {
                DB::rollBack();
                return $this->errorResponse('El archivo no se guardó correctamente', 500);
            }

            $result = DB::selectOne(
                'SELECT ventas.fn_sucursales_foto(?::BIGINT, ?::TEXT, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$id, $campo, $filename], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            // La anterior con OTRO nombre (otra extensión) ya no la mira
            // nadie, y sólo después de que la base haya confirmado
            if ($anterior && $anterior !== $filename) {
                $this->borrarImagen($anterior);
            }
            DB::commit();

            sistemaLog('info', 'Imagen de sucursal guardada',
                       ['sucursal_id' => $id, 'campo' => $campo, 'archivo' => $filename]);
            return $this->successResponse([
                'campo'     => $campo,
                'archivo'   => $filename,
                'sucursal'  => $r['data'] ?? null,
                'full_path' => asset('storage/' . self::CARPETA_IMAGENES . '/' . $filename),
            ], $r['message']);

        } catch (QueryException $e) {
            DB::rollBack();
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            sistemaLog('error', 'Error en addFoto (sucursal)',
                       ['message' => $e->getMessage(), 'line' => $e->getLine(),
                        'sucursal_id' => $request->SucursalId ?? null]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Devuelve la imagen pedida (la usa <img src>). */
    public function getFoto($id, $campo)
    {
        try {
            if (!array_key_exists($campo, self::CAMPOS_IMAGEN)) {
                return $this->errorResponse('La imagen debe ser «foto» o «mapa»', 422);
            }

            $columna = $campo === 'foto' ? 'foto' : 'mapa_foto';
            $r = DB::selectOne("SELECT $columna AS archivo FROM ventas.sucursales WHERE id = ?", [(int) $id]);
            if (!$r || !$r->archivo) {
                return $this->errorResponse('La sucursal no tiene esa imagen', 404);
            }

            $ruta = storage_path('app/public/' . self::CARPETA_IMAGENES . '/' . $r->archivo);
            if (!is_file($ruta)) {
                return $this->errorResponse('La imagen no existe en el servidor', 404);
            }
            return response()->file($ruta, [
                'Content-Type'  => mime_content_type($ruta),
                'Cache-Control' => 'public, max-age=31536000',
            ]);
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Quita la imagen: de la ficha y del disco. */
    public function quitarFoto(Request $request, $id, $campo)
    {
        try {
            if (!array_key_exists($campo, self::CAMPOS_IMAGEN)) {
                return $this->errorResponse('La imagen debe ser «foto» o «mapa»', 422);
            }

            $columna = $campo === 'foto' ? 'foto' : 'mapa_foto';
            $antes = DB::selectOne("SELECT $columna AS archivo FROM ventas.sucursales WHERE id = ?", [(int) $id]);
            if (!$antes) {
                return $this->errorResponse('Sucursal no encontrada', 404);
            }

            $result = DB::selectOne(
                'SELECT ventas.fn_sucursales_foto(?::BIGINT, ?::TEXT, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $campo, null], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            $this->borrarImagen($antes->archivo);

            sistemaLog('info', 'Imagen de sucursal quitada', ['sucursal_id' => $id, 'campo' => $campo]);
            return $this->successResponse($r['data'] ?? null, $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en quitarFoto (sucursal)', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
