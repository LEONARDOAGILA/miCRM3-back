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
 * CRUD de productos (inventarios.productos) y su galería de imágenes.
 *
 * Mismo esquema que ventas\ClienteController: la lógica vive en las funciones
 * PL/pgSQL inventarios.fn_productos_*; aquí se valida la entrada, se llama a
 * la función con el contexto del usuario y se traduce la respuesta. Lo único
 * que se hace aquí y no allí es tocar el disco.
 *
 * LOS FICHEROS SE BORRAN SIEMPRE DESPUÉS de que la base confirme. Las
 * funciones devuelven el nombre de lo que hay que quitar precisamente para
 * eso: borrar antes dejaría la fila apuntando a nada si la transacción se cae.
 *
 *   GET    inventarios/producto/allProductos?page&per_page&search&marca_id&categoria_id
 *   GET    inventarios/producto/listProductos[?activos=0]
 *   GET    inventarios/producto/findByIdProducto/{id}        incluye la galería
 *   POST   inventarios/producto/addProducto
 *   POST   inventarios/producto/editProducto/{id}
 *   POST   inventarios/producto/activarProducto/{id}         { activo? }; sin ella, alterna
 *   DELETE inventarios/producto/deleteProducto/{id}
 *
 *   GET    inventarios/producto/imagenes/{id}                la galería de un producto
 *   POST   inventarios/producto/addImagen                    { ProductoId, imagen_file }
 *   POST   inventarios/producto/imagenPrincipal/{idImagen}
 *   POST   inventarios/producto/ordenarImagenes/{id}         { ids: [...] }
 *   DELETE inventarios/producto/deleteImagen/{idImagen}
 *   GET    inventarios/producto/getImagen/{idImagen}         (pública, la usa <img src>)
 */
class ProductoController extends Controller
{
    use ApiResponder;

    /** Dónde viven las imágenes dentro de storage/app/public. */
    private const CARPETA_IMAGENES = 'img/productos';

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0006' => 409,   // código o código de barras duplicado
        'P0013' => 404,   // el producto no existe
        'P0014' => 409,   // tiene dependencias
        'P0015' => 422,   // valor inválido
        'P0016' => 422,   // la marca o la categoría no existen
    ];

    public function __construct()
    {
        // getImagen va suelta (la pide <img src> sin cabeceras); el resto, con token
        $this->middleware('auth:api')->except(['getImagen']);
    }

    // ================================================================
    // AYUDANTES
    // ================================================================

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

    /** Los veintiún datos de la ficha, con sus castes, en el orden de las funciones. */
    private const CASTS_DATOS = '
        ?::VARCHAR,   -- p_codigo
        ?::VARCHAR,   -- p_nombre
        ?::VARCHAR,   -- p_codigo_barras
        ?::TEXT,      -- p_descripcion
        ?::BIGINT,    -- p_marca_id
        ?::BIGINT,    -- p_categoria_id
        ?::VARCHAR,   -- p_modelo
        ?::VARCHAR,   -- p_unidad
        ?::NUMERIC,   -- p_costo
        ?::NUMERIC,   -- p_precio
        ?::NUMERIC,   -- p_iva_porcentaje
        ?::BOOLEAN,   -- p_maneja_stock
        ?::NUMERIC,   -- p_stock_minimo
        ?::NUMERIC,   -- p_stock_maximo
        ?::BOOLEAN,   -- p_maneja_serie
        ?::INTEGER,   -- p_garantia_meses
        ?::NUMERIC,   -- p_peso_kg
        ?::NUMERIC,   -- p_alto_cm
        ?::NUMERIC,   -- p_ancho_cm
        ?::NUMERIC,   -- p_profundidad_cm
        ?::BOOLEAN,   -- p_activo
    ';

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

    private function reglas(): array
    {
        return [
            'codigo'         => 'required|string|min:2|max:30',
            'nombre'         => 'required|string|min:3|max:150',
            'codigo_barras'  => 'nullable|string|max:50',
            'descripcion'    => 'nullable|string|max:4000',
            'marca_id'       => 'nullable|integer',
            'categoria_id'   => 'nullable|integer',
            'modelo'         => 'nullable|string|max:80',
            'unidad'         => 'nullable|string|max:15',
            'costo'          => 'nullable|numeric|min:0',
            'precio'         => 'nullable|numeric|min:0',
            'iva_porcentaje' => 'nullable|numeric|min:0|max:100',
            'maneja_stock'   => 'nullable|boolean',
            'stock_minimo'   => 'nullable|numeric|min:0',
            'stock_maximo'   => 'nullable|numeric|min:0',
            'maneja_serie'   => 'nullable|boolean',
            'garantia_meses' => 'nullable|integer|min:0|max:600',
            'peso_kg'        => 'nullable|numeric|min:0',
            'alto_cm'        => 'nullable|numeric|min:0',
            'ancho_cm'       => 'nullable|numeric|min:0',
            'profundidad_cm' => 'nullable|numeric|min:0',
            'activo'         => 'nullable|boolean',
        ];
    }

    private function mensajes(): array
    {
        return [
            'codigo.required'    => 'El código del producto es obligatorio',
            'codigo.min'         => 'El código debe tener al menos 2 caracteres',
            'nombre.required'    => 'El nombre del producto es obligatorio',
            'nombre.min'         => 'El nombre debe tener al menos 3 caracteres',
            'costo.min'          => 'El costo no puede ser negativo',
            'precio.min'         => 'El precio no puede ser negativo',
            'iva_porcentaje.max' => 'El IVA no puede superar el 100%',
            'garantia_meses.max' => 'La garantía no puede superar los 600 meses',
        ];
    }

    /** Un número o null: el formulario manda '' cuando el campo se deja vacío. */
    private function num($v)
    {
        return ($v === null || $v === '') ? null : $v;
    }

    /** Los datos de la ficha en el orden de las funciones. */
    private function parametros(array $d): array
    {
        return [
            $d['codigo'],
            $d['nombre'],
            $this->num($d['codigo_barras'] ?? null),
            $this->num($d['descripcion'] ?? null),
            $this->num($d['marca_id'] ?? null),
            $this->num($d['categoria_id'] ?? null),
            $this->num($d['modelo'] ?? null),
            $this->num($d['unidad'] ?? null) ?? 'UNIDAD',
            $this->num($d['costo'] ?? null) ?? 0,
            $this->num($d['precio'] ?? null) ?? 0,
            $this->num($d['iva_porcentaje'] ?? null) ?? 15,
            array_key_exists('maneja_stock', $d) ? (bool) $d['maneja_stock'] : true,
            $this->num($d['stock_minimo'] ?? null) ?? 0,
            $this->num($d['stock_maximo'] ?? null),
            array_key_exists('maneja_serie', $d) ? (bool) $d['maneja_serie'] : false,
            $this->num($d['garantia_meses'] ?? null) ?? 0,
            $this->num($d['peso_kg'] ?? null),
            $this->num($d['alto_cm'] ?? null),
            $this->num($d['ancho_cm'] ?? null),
            $this->num($d['profundidad_cm'] ?? null),
            array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
        ];
    }

    /** Borra una imagen de storage por su nombre; se calla si ya no está. */
    private function borrarImagen(?string $archivo): void
    {
        if (!$archivo) { return; }
        $ruta = storage_path('app/public/' . self::CARPETA_IMAGENES . '/' . $archivo);
        if (is_file($ruta)) { @unlink($ruta); }
    }

    // ================================================================
    // LISTAR
    // ================================================================

    public function allProductos(Request $request)
    {
        try {
            $marca     = $request->input('marca_id');
            $categoria = $request->input('categoria_id');

            $result = DB::selectOne(
                'SELECT inventarios.fn_productos_listar_paginado(?::INTEGER, ?::INTEGER, ?::TEXT, ?::BIGINT, ?::BIGINT) as result',
                [(int) $request->input('page', 1),
                 (int) $request->input('per_page', 15),
                 (string) $request->input('search', ''),
                 ($marca === null || $marca === '') ? null : (int) $marca,
                 ($categoria === null || $categoria === '') ? null : (int) $categoria]
            );
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'], 500);
            }
            return $this->successResponse($r, 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allProductos', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function listProductos(Request $request)
    {
        try {
            $soloActivos = $request->input('activos', '1') !== '0';
            $result = DB::selectOne('SELECT inventarios.fn_productos_listar(?::BOOLEAN) as result', [$soloActivos]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listProductos', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdProducto($id)
    {
        try {
            $result = DB::selectOne('SELECT inventarios.fn_productos_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdProducto', ['message' => $e->getMessage(), 'producto_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addProducto(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_productos_crear(' . self::CASTS_DATOS . self::CASTS_AUDIT . ') as result',
                array_merge($this->parametros($d), $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Producto creado', ['producto_id' => $r['data']['id'] ?? null, 'codigo' => $r['data']['codigo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'addProducto rechazado',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addProducto', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al crear el producto', 500);
        }
    }

    public function editProducto(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT inventarios.fn_productos_modificar(?::BIGINT, ' . self::CASTS_DATOS . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->parametros($d), $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Producto actualizado', ['producto_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'editProducto rechazado',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'producto_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editProducto', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'producto_id' => $id]);
            return $this->errorResponse('Ocurrió un error al actualizar el producto', 500);
        }
    }

    public function activarProducto(Request $request, $id)
    {
        try {
            // El booleano con filter_var: "false" en texto es true a secas
            $activo = $request->exists('activo') && $request->input('activo') !== null && $request->input('activo') !== ''
                ? filter_var($request->input('activo'), FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE)
                : null;

            $result = DB::selectOne(
                'SELECT inventarios.fn_productos_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'], ($r['error_code'] ?? '') === 'NO_EXISTE' ? 404 : 500);
            }

            sistemaLog('info', 'Producto activado/desactivado', ['producto_id' => $id, 'activo' => $r['data']['activo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarProducto', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'producto_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cambiar el estado del producto', 500);
        }
    }

    /**
     * Baja de verdad, con su galería.
     *
     * El ON DELETE CASCADE se lleva las filas de las imágenes; los ficheros
     * los quita esto, con la lista que devuelve la función y SÓLO después de
     * que la base haya confirmado.
     */
    public function deleteProducto(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_productos_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            foreach (($r['data']['archivos'] ?? []) as $archivo) {
                $this->borrarImagen($archivo);
            }

            sistemaLog('info', 'Producto eliminado', ['producto_id' => $id, 'imagenes' => count($r['data']['archivos'] ?? [])]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteProducto rechazado',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'producto_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteProducto', ['message' => $e->getMessage(), 'line' => $e->getLine(), 'producto_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar el producto', 500);
        }
    }

    // ================================================================
    // LA GALERÍA
    // ================================================================

    public function imagenes($id)
    {
        try {
            $result = DB::selectOne('SELECT inventarios.fn_productos_imagenes(?::BIGINT) as result', [(int) $id]);
            return $this->successResponse(json_decode($result->result, true), 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en imagenes (producto)', ['message' => $e->getMessage(), 'producto_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Añade una imagen a la galería.
     *
     * NO SE PROCESA LA IMAGEN: en este servidor no está activada la extensión
     * GD, así que el fichero se guarda tal cual llega. Si hay que
     * redimensionar, se hace en el navegador antes de subirlo.
     *
     * El nombre lleva un identificador único y no un correlativo: con dos
     * personas subiendo a la vez, un `producto_3.jpg` calculado contando las
     * que hay pisaría el fichero de la otra.
     */
    public function addImagen(Request $request)
    {
        DB::beginTransaction();
        try {
            $validator = Validator::make($request->all(), [
                'ProductoId'  => 'required|integer',
                'imagen_file' => 'required|file|image|max:10240',
            ], [
                'ProductoId.required'  => 'Falta el producto',
                'imagen_file.required' => 'No se encontró la imagen para guardar',
                'imagen_file.image'    => 'El archivo debe ser una imagen',
                'imagen_file.max'      => 'La imagen no puede superar los 10 MB',
            ]);
            if ($validator->fails()) {
                DB::rollBack();
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $productoId = (int) $request->ProductoId;
            if (!DB::selectOne('SELECT id FROM inventarios.productos WHERE id = ?', [$productoId])) {
                DB::rollBack();
                return $this->errorResponse('Producto no encontrado', 404);
            }

            $file      = $request->file('imagen_file');
            $extension = strtolower($file->getClientOriginalExtension() ?: 'jpg');
            $filename  = $productoId . '_' . Str::lower(Str::random(10)) . '.' . $extension;

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
                'SELECT inventarios.fn_productos_imagen_agregar(?::BIGINT, ?::VARCHAR, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$productoId, $filename, $file->getClientOriginalName()], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            DB::commit();

            sistemaLog('info', 'Imagen de producto guardada', ['producto_id' => $productoId, 'archivo' => $filename]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            DB::rollBack();
            $this->borrarImagen($filename ?? null);   // la fila no entró: el fichero sobra
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            DB::rollBack();
            $this->borrarImagen($filename ?? null);
            sistemaLog('error', 'Error en addImagen (producto)',
                       ['message' => $e->getMessage(), 'line' => $e->getLine(), 'producto_id' => $request->ProductoId ?? null]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function imagenPrincipal(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_productos_imagen_principal(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en imagenPrincipal', ['message' => $e->getMessage(), 'imagen_id' => $id]);
            return $this->errorResponse('Ocurrió un error al marcar la imagen principal', 500);
        }
    }

    public function ordenarImagenes(Request $request, $id)
    {
        try {
            $d   = $this->datosDe($request);
            $ids = $d['ids'] ?? [];
            if (!is_array($ids)) {
                return $this->errorResponse('Se esperaba la lista de imágenes en el orden nuevo', 422);
            }

            $result = DB::selectOne(
                'SELECT inventarios.fn_productos_imagenes_ordenar(?::BIGINT, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, json_encode(array_values(array_map('strval', $ids)))], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en ordenarImagenes', ['message' => $e->getMessage(), 'producto_id' => $id]);
            return $this->errorResponse('Ocurrió un error al ordenar la galería', 500);
        }
    }

    public function deleteImagen(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT inventarios.fn_productos_imagen_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            $this->borrarImagen($r['data']['archivo'] ?? null);

            sistemaLog('info', 'Imagen de producto eliminada', ['imagen_id' => $id, 'archivo' => $r['data']['archivo'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteImagen', ['message' => $e->getMessage(), 'imagen_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar la imagen', 500);
        }
    }

    /** Sirve el fichero de una imagen. Pública: la pide <img src>, que no manda cabeceras. */
    public function getImagen($id)
    {
        try {
            $r = DB::selectOne('SELECT archivo FROM inventarios.productos_imagenes WHERE id = ?', [(int) $id]);
            if (!$r || !$r->archivo) {
                return $this->errorResponse('La imagen no existe', 404);
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
}
