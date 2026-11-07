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
 * CRUD de proformas (ventas.proformas + ventas.proformas_detalle).
 *
 * Es el primer DOCUMENTO del sistema, no un catálogo, y eso se nota en tres
 * sitios de este controlador:
 *
 *   · SE GUARDA ENTERO DE UNA VEZ. No hay rutas para añadir o quitar una
 *     línea: la pantalla manda la cabecera y la lista completa de líneas, y
 *     ventas.fn_proformas_guardar lo deja todo en una transacción. Media
 *     proforma guardada no es nada.
 *
 *   · LOS IMPORTES NO SE CREEN. Llegan en el jsonb porque la rejilla los
 *     calcula para que el usuario los vea, pero la función los recalcula a
 *     partir de cantidad, precio, descuento e IVA. Aquí no se validan los
 *     totales: se ignoran.
 *
 *   · TIENE CICLO DE VIDA, no una casilla de activo. El estado se cambia por
 *     su propia ruta, que es la que conoce las transiciones permitidas.
 *
 * Como en el resto del sistema, la lógica vive en las funciones de base y
 * aquí sólo se valida la entrada y se traduce la respuesta.
 *
 *   GET    ventas/proforma/allProformas            ?page&per_page&search&estado&filtros
 *   GET    ventas/proforma/resumenProformas        contadores por estado
 *   GET    ventas/proforma/findByIdProforma/{id}   el documento completo
 *   GET    ventas/proforma/condicionesCliente/{id} la foto del cliente y con qué se le vende
 *   GET    ventas/proforma/clientePorIdentificacion/{cedula}   lo mismo, buscando por cédula o RUC
 *   GET    ventas/proforma/buscarProducto          ?texto&limite  (la rejilla, al teclear un código)
 *   POST   ventas/proforma/addProforma             { cliente_id, ..., detalle:[...] }
 *   POST   ventas/proforma/editProforma/{id}
 *   POST   ventas/proforma/estadoProforma/{id}     { estado, motivo? }
 *   POST   ventas/proforma/renovarProforma/{id}    { validez_dias? }
 *   POST   ventas/proforma/duplicarProforma/{id}
 *   DELETE ventas/proforma/deleteProforma/{id}
 *   GET    ventas/proforma/papelera
 *   POST   ventas/proforma/restaurarProformas      { ids:[..] }
 *   POST   ventas/proforma/eliminarDefinitivo      { ids:[..] }
 *   POST   ventas/proforma/vaciarPapelera
 */
class ProformaController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;
    // El traductor del modelo de filtros de ag-Grid, compartido con las demás
    // pantallas que paginan en el servidor
    use \App\Http\Controllers\Concerns\FiltrosDeColumna;

    /**
     * Por qué columnas deja filtrar la rejilla, y de qué tipo es cada una.
     *
     * ES UNA LISTA BLANCA: el nombre acaba dentro de una consulta, y lo que no
     * esté aquí se tira en silencio. Tiene que cuadrar con lo que mira
     * ventas.fn_proformas_listar_paginado.
     */
    private const COLUMNAS_FILTRABLES = [
        'id'                     => 'numero',
        'lineas'                 => 'numero',
        'validez_dias'           => 'numero',
        'dias_credito'           => 'numero',
        'descuento_porcentaje'   => 'numero',
        'subtotal'               => 'numero',
        'descuento_total'        => 'numero',
        'iva_total'              => 'numero',
        'total'                  => 'numero',
        'numero'                 => 'texto',
        'cliente_nombre'         => 'texto',
        'cliente_identificacion' => 'texto',
        'vendedor_nombre'        => 'texto',
        'estado'                 => 'texto',
        'forma_pago'             => 'texto',
        'observaciones'          => 'texto',
        'created_by'             => 'texto',
        'updated_by'             => 'texto',
        // Las fechas se filtran como texto sobre lo que se ve en la rejilla
        'fecha'                  => 'texto',
        'fecha_vence'            => 'texto',
        'created_at'             => 'texto',
        'updated_at'             => 'texto',
    ];

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato, o un número fuera de rango
        'P0007' => 409,   // el estado del documento no permite eso
        'P0016' => 404,   // el cliente, el producto o la proforma no existen
    ];

    /** Los estados a los que se puede pedir pasar (las reglas las pone la base) */
    private const ESTADOS = 'BORRADOR,ENVIADA,APROBADA,RECHAZADA,VENCIDA,ANULADA';

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    public function __construct()
    {
        $this->middleware('auth:api');
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

    private function usuarioId(): ?int
    {
        $u = auth('api')->user();
        return isset($u->id) ? (int) $u->id : null;
    }

    /**
     * Lo que se admite de la cabecera y de cada línea.
     *
     * De los importes SÓLO se valida lo que el usuario escribe —cantidad,
     * precio, descuento, IVA—. subtotal, base y total pueden venir en el
     * jsonb y se ignoran: los pone la base.
     */
    private function reglas(): array
    {
        return [
            'cliente_id'           => 'required|integer|min:1',
            'vendedor_usuario_id'  => 'nullable|integer|min:1',
            'sucursal_id'          => 'nullable|integer|min:1',
            'bodega_id'            => 'nullable|integer|min:1',
            'fecha'                => 'nullable|date',
            'validez_dias'         => 'nullable|integer|min:0|max:365',
            'forma_pago'           => 'nullable|string|max:20',
            'dias_credito'         => 'nullable|integer|min:0|max:3650',
            'descuento_porcentaje' => 'nullable|numeric|min:0|max:100',
            'moneda'               => 'nullable|string|size:3',
            'observaciones'        => 'nullable|string|max:4000',
            'condiciones'          => 'nullable|string|max:4000',

            'detalle'                        => 'required|array|min:1|max:500',
            'detalle.*.producto_id'          => 'nullable|integer|min:1',
            'detalle.*.codigo'               => 'nullable|string|max:50',
            'detalle.*.descripcion'          => 'nullable|string|max:500',
            'detalle.*.unidad'               => 'nullable|string|max:20',
            'detalle.*.cantidad'             => 'required|numeric|gt:0|max:99999999',
            'detalle.*.precio_unitario'      => 'nullable|numeric|min:0|max:99999999',
            'detalle.*.descuento_porcentaje' => 'nullable|numeric|min:0|max:100',
            'detalle.*.iva_porcentaje'       => 'nullable|numeric|min:0|max:100',
            'detalle.*.observacion'          => 'nullable|string|max:255',
        ];
    }

    private function mensajes(): array
    {
        return [
            'cliente_id.required' => 'Hay que decir a qué cliente se le hace la proforma',
            'cliente_id.integer'  => 'El cliente de la proforma no es válido',
            'fecha.date'          => 'La fecha de la proforma no es válida',
            'validez_dias.max'    => 'Los días de validez no pueden pasar de 365',
            'validez_dias.min'    => 'Los días de validez no pueden ser negativos',
            'moneda.size'         => 'La moneda son tres letras (USD)',
            'dias_credito.max'    => 'Los días de crédito no pueden pasar de 3650',
            'descuento_porcentaje.min' => 'El descuento no puede ser negativo',
            'descuento_porcentaje.max' => 'El descuento no puede pasar del 100 %',

            'detalle.required' => 'La proforma no tiene ninguna línea',
            'detalle.array'    => 'Las líneas de la proforma no llegaron bien',
            'detalle.min'      => 'La proforma no tiene ninguna línea',
            'detalle.max'      => 'Una proforma no puede pasar de 500 líneas',

            // Las de las líneas no pueden decir en qué línea es —Laravel las
            // numera desde cero, y «la línea 0» no significa nada para quien
            // está mirando la rejilla—, así que se dicen sin número: el campo
            // que falla se queda marcado en la propia celda.
            'detalle.*.cantidad.required'        => 'Hay una línea sin cantidad',
            'detalle.*.cantidad.numeric'         => 'La cantidad tiene que ser un número',
            'detalle.*.cantidad.gt'              => 'La cantidad tiene que ser mayor que cero',
            'detalle.*.precio_unitario.numeric'  => 'El precio tiene que ser un número',
            'detalle.*.precio_unitario.min'      => 'El precio no puede ser negativo',
            'detalle.*.descuento_porcentaje.numeric' => 'El descuento de la línea tiene que ser un número',
            'detalle.*.descuento_porcentaje.min' => 'El descuento de una línea no puede ser negativo',
            'detalle.*.descuento_porcentaje.max' => 'El descuento de una línea no puede pasar del 100 %',
            'detalle.*.iva_porcentaje.numeric'   => 'El IVA de la línea tiene que ser un número',
            'detalle.*.iva_porcentaje.min'       => 'El IVA de una línea no puede ser negativo',
            'detalle.*.iva_porcentaje.max'       => 'El IVA de una línea no puede pasar del 100 %',
            'detalle.*.descripcion.max'          => 'La descripción de una línea no puede pasar de 500 caracteres',
            'detalle.*.codigo.max'               => 'El código de una línea no puede pasar de 50 caracteres',
            'detalle.*.observacion.max'          => 'La observación de una línea no puede pasar de 255 caracteres',
        ];
    }

    /**
     * Parte lo validado en los dos jsonb que espera la función.
     *
     * Las claves que NO vengan se quedan fuera a propósito: la función
     * distingue entre «no me lo mandaste» —y entonces hereda del cliente, o
     * deja lo que había— y «me lo mandaste vacío», que es quitarlo.
     *
     * @return array{0: string, 1: string} [cabecera, detalle] ya en JSON
     */
    private function partirEnJson(array $d): array
    {
        $cabecera = $d;
        unset($cabecera['detalle']);

        // Las líneas, sólo con lo que la base usa. Así da igual lo que de más
        // traiga la rejilla (totales calculados, banderas de la pantalla, el
        // id de la fila): no llega a la función y no puede confundirla.
        $campos = ['producto_id', 'codigo', 'descripcion', 'unidad', 'cantidad',
                   'precio_unitario', 'descuento_porcentaje', 'iva_porcentaje', 'observacion'];

        $detalle = array_map(function ($linea) use ($campos) {
            $limpia = [];
            foreach ($campos as $c) {
                if (array_key_exists($c, $linea) && $linea[$c] !== null && $linea[$c] !== '') {
                    $limpia[$c] = $linea[$c];
                }
            }
            return $limpia;
        }, $d['detalle']);

        return [json_encode($cabecera), json_encode(array_values($detalle))];
    }

    // ================================================================
    // LISTAR
    // ================================================================

    /**
     * El listado paginado de la rejilla.
     *
     * El alcance lo pone la base con el usuario del token: quien no es
     * administrador ve las proformas de los vendedores que tiene a cargo.
     */
    public function allProformas(Request $request)
    {
        try {
            // El filtro rápido por estado de los botones de arriba. Lo que no
            // esté en la lista se ignora y se devuelven todas: es menos
            // molesto que un error por algo que el usuario no escribió.
            $estado = strtoupper(trim((string) $request->input('estado', '')));
            if (!in_array($estado, explode(',', self::ESTADOS), true)) {
                $estado = null;
            }

            // Los filtros de la cabecera de la rejilla. Se aplican AQUÍ y no en
            // el navegador: la pantalla pagina en el servidor, así que ag-Grid
            // sólo tiene quince filas y filtrando por su cuenta buscaría
            // dentro de quince.
            $filtros = $this->filtrosDeColumna($request->input('filtros'), self::COLUMNAS_FILTRABLES);

            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_listar_paginado(?::INTEGER, ?::INTEGER, ?::TEXT, ?::TEXT, ?::BIGINT, ?::JSONB) as result',
                [
                    max(1, (int) $request->input('page', 1)),
                    max(1, (int) $request->input('per_page', 15)),
                    (string) $request->input('search', ''),
                    $estado,
                    $this->usuarioId(),
                    json_encode((object) $filtros),
                ]
            );
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar', 500);
            }

            return $this->successResponse($r, 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allProformas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Cuántas hay en cada estado y cuánto suman, con el mismo alcance. */
    public function resumenProformas(Request $request)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_proformas_resumen(?::BIGINT) as result', [$this->usuarioId()]);
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'] ?? [], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en resumenProformas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdProforma($id)
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_proformas_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'La proforma no existe',
                                            ($r['error_code'] ?? '') === 'P0016' ? 404 : 500);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdProforma', ['message' => $e->getMessage(), 'proforma_id' => $id]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Al escoger el cliente: su foto y con qué condiciones se le vende.
     *
     * Una sola vuelta para rellenar media cabecera. Contesta 200 incluso
     * cuando el cliente no existe —con `success: false` dentro— sólo si la
     * base lo dice así; aquí se traduce a 404, que es lo que la pantalla
     * espera para un id que no está.
     */
    public function condicionesCliente($clienteId)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_cliente_condiciones(?::BIGINT) as result', [(int) $clienteId]);
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'El cliente no existe', 404);
            }
            return $this->successResponse($r['data'], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en condicionesCliente', ['message' => $e->getMessage(), 'cliente_id' => $clienteId]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Lo mismo, pero buscando por la CÉDULA O EL RUC.
     *
     * Es por donde busca la pantalla cuando se teclea la identificación en el
     * campo del cliente: el vendedor tiene delante la cédula, no el id con el
     * que el sistema guarda al cliente. Devuelve lo mismo que
     * condicionesCliente más un `encontrado`, así que da igual si se llegó
     * por aquí o por la lupa.
     */
    public function clientePorIdentificacion($identificacion)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_cliente_por_identificacion(?::TEXT) as result',
                [(string) $identificacion]
            );
            $r = json_decode($result->result, true);

            // SIEMPRE 200, con `encontrado` dentro. Que no exista un cliente
            // con esa cédula NO es un error: es el resultado normal de
            // teclearla mal o de que todavía no esté dado de alta. Con un 404,
            // el AuthInterceptor saca un toast rojo que además dice algo que
            // no es («el recurso fue eliminado»). Mismo trato que las
            // consultas al SRI y al Registro Civil.
            if (!($r['success'] ?? false)) {
                return $this->successResponse([
                    'encontrado' => false,
                    'motivo'     => $r['error_code'] ?? 'DESCONOCIDO',
                    'mensaje'    => $r['message'] ?? 'No hay ningún cliente con esa identificación',
                ], 'La solicitud ha tenido éxito');
            }

            return $this->successResponse(['encontrado' => true] + $r['data'],
                                          'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en clientePorIdentificacion',
                       ['message' => $e->getMessage(), 'identificacion' => $identificacion]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Lo que usa la rejilla cuando se teclea un código y se pulsa Enter.
     *
     * Si hay uno que coincide exacto viene con `exacto: true` y la línea se
     * rellena sola; si no, vienen los parecidos para ofrecerlos.
     */
    public function buscarProducto(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_producto_buscar(?::TEXT, ?::INTEGER) as result',
                [(string) $request->input('texto', ''), (int) $request->input('limite', 10)]
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'] ?? ['exacto' => false, 'productos' => []],
                                          'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en buscarProducto', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * El catálogo paginado, para el selector de productos de la rejilla.
     *
     * No se usa el de inventarios a propósito: ése no devuelve el
     * iva_porcentaje —que es lo que la línea necesita para calcularse— y sí
     * devuelve el costo y la descripción larga en HTML, que aquí no pintan
     * nada. Esto viene con la forma de una línea, igual que buscarProducto.
     */
    public function productos(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_productos_paginado(?::INTEGER, ?::INTEGER, ?::TEXT, ?::BIGINT, ?::BIGINT) as result',
                [
                    max(1, (int) $request->input('page', 1)),
                    max(1, (int) $request->input('per_page', 10)),
                    (string) $request->input('search', ''),
                    $request->filled('categoria_id') ? (int) $request->input('categoria_id') : null,
                    $request->filled('marca_id')     ? (int) $request->input('marca_id')     : null,
                ]
            );
            $r = json_decode($result->result, true);

            if (isset($r['success']) && $r['success'] === false) {
                return $this->errorResponse($r['message'] ?? 'No se pudo listar el catálogo', 500);
            }
            return $this->successResponse($r, 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en productos de proformas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // ESCRIBIR
    // ================================================================

    public function addProforma(Request $request)
    {
        return $this->guardar($request, null);
    }

    public function editProforma(Request $request, $id)
    {
        return $this->guardar($request, (int) $id);
    }

    /**
     * El tronco común de crear y modificar.
     *
     * Son la misma llamada con p_id nulo o no: en un documento lo único que
     * cambia es que la primera vez se saca un número de la secuencia.
     */
    private function guardar(Request $request, ?int $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            [$cabecera, $detalle] = $this->partirEnJson($validator->validated());

            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_guardar(?::BIGINT, ?::JSONB, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$id, $cabecera, $detalle], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', $id === null ? 'Proforma creada' : 'Proforma actualizada',
                       ['proforma_id' => $r['data']['id'] ?? $id, 'numero' => $r['data']['numero'] ?? null]);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'Guardar proforma rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'proforma_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al guardar la proforma',
                       ['message' => $e->getMessage(), 'line' => $e->getLine(), 'proforma_id' => $id]);
            return $this->errorResponse('Ocurrió un error al guardar la proforma', 500);
        }
    }

    /**
     * Enviar, aprobar, rechazar o anular.
     *
     * Las transiciones que valen las decide la base; aquí sólo se comprueba
     * que el estado pedido exista. El motivo es obligatorio al rechazar, y
     * eso también lo exige la función —no sólo la pantalla—.
     */
    public function estadoProforma(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), [
                'estado' => 'required|string|in:' . self::ESTADOS,
                'motivo' => 'nullable|string|max:2000',
            ], [
                'estado.required' => 'No se dijo a qué estado pasar',
                'estado.in'       => 'Ese estado no existe',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_cambiar_estado(?::BIGINT, ?::TEXT, ?::TEXT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $d['estado'], $d['motivo'] ?? null], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Proforma cambiada de estado', ['proforma_id' => $id, 'estado' => $d['estado']]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'estadoProforma rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'proforma_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en estadoProforma',
                       ['message' => $e->getMessage(), 'line' => $e->getLine(), 'proforma_id' => $id]);
            return $this->errorResponse('Ocurrió un error al cambiar el estado de la proforma', 500);
        }
    }

    /** Una vencida con fecha de hoy y los mismos precios. */
    public function renovarProforma(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), [
                'validez_dias' => 'nullable|integer|min:0|max:365',
            ], [
                'validez_dias.max' => 'Los días de validez no pueden pasar de 365',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_renovar(?::BIGINT, ?::INTEGER, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $d['validez_dias'] ?? null], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Proforma renovada', ['proforma_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en renovarProforma', ['message' => $e->getMessage(), 'proforma_id' => $id]);
            return $this->errorResponse('Ocurrió un error al renovar la proforma', 500);
        }
    }

    /** Otro documento igual, en borrador y con su propio número. */
    public function duplicarProforma(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_duplicar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Proforma duplicada',
                       ['origen_id' => $id, 'nueva_id' => $r['data']['id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en duplicarProforma', ['message' => $e->getMessage(), 'proforma_id' => $id]);
            return $this->errorResponse('Ocurrió un error al duplicar la proforma', 500);
        }
    }

    public function deleteProforma(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_proformas_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Proforma enviada a la papelera', ['proforma_id' => $id]);
            return $this->successResponse($r['data'] ?? null, $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteProforma rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage(), 'proforma_id' => $id]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteProforma', ['message' => $e->getMessage(), 'proforma_id' => $id]);
            return $this->errorResponse('Ocurrió un error al eliminar la proforma', 500);
        }
    }

    // ================================================================
    // PAPELERA DE RECICLAJE
    // ================================================================
    //
    // «Eliminar» es un borrado lógico: sale del listado y de los informes, y
    // desde la papelera se restaura o se borra de verdad. Las líneas se van
    // con el documento, que para eso la clave ajena es ON DELETE CASCADE.
    //
    // Una proforma APROBADA no se puede eliminar: es lo que el cliente
    // aceptó. Si la operación se cayó, se anula; eso lo dice la base.

    public function papelera()
    {
        try {
            $result = DB::selectOne('SELECT ventas.fn_proformas_papelera_listar() as result');
            $r = json_decode($result->result, true);
            return $this->successResponse($r ?? [], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de proformas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al listar la papelera', 500);
        }
    }

    /** Saca de la papelera una o varias. Body: { ids: [..] } */
    public function restaurarProformas(Request $request)
    {
        return $this->accionPapelera($request, 'ventas.fn_proformas_restaurar', 'restaurarProformas');
    }

    public function eliminarDefinitivo(Request $request)
    {
        // ESTO NO TIENE VUELTA ATRÁS: hace falta el permiso «vaciar», que es
        // otro distinto de «papelera». Se comprueba AQUÍ y no sólo en el
        // front: esconder el botón no es un permiso.
        if ($no = $this->exigirPermiso('allProformas', 'vaciar',
                'No tiene permiso para eliminar definitivamente proformas')) {
            return $no;
        }

        return $this->accionPapelera($request, 'ventas.fn_proformas_eliminar_definitivo', 'eliminarDefinitivo');
    }

    public function vaciarPapelera(Request $request)
    {
        if ($no = $this->exigirPermiso('allProformas', 'vaciar',
                'No tiene permiso para vaciar la papelera de proformas')) {
            return $no;
        }

        return $this->accionPapelera($request, 'ventas.fn_proformas_papelera_vaciar', 'vaciarPapelera', false);
    }

    /** El tronco común de restaurar / eliminar definitivo / vaciar. */
    private function accionPapelera(Request $request, string $funcion, string $nombre, bool $conIds = true)
    {
        try {
            $auditoria = $this->auditoria($request);

            if ($conIds) {
                $validator = Validator::make($request->all(), [
                    'ids'   => 'required|array|min:1|max:500',
                    'ids.*' => 'integer',
                ], [
                    'ids.required' => 'No se indicó ninguna proforma',
                ]);
                if ($validator->fails()) {
                    return $this->errorResponse($validator->errors()->first(), 422);
                }
                $result = DB::selectOne(
                    "SELECT {$funcion}(?::JSONB, " . self::CASTS_AUDIT . ") as result",
                    array_merge([json_encode(array_map('intval', $validator->validated()['ids']))], $auditoria)
                );
            } else {
                $result = DB::selectOne("SELECT {$funcion}(" . self::CASTS_AUDIT . ") as result", $auditoria);
            }
            $r = json_decode($result->result, true);

            if (!($r['success'] ?? false)) {
                return $this->errorResponse($r['message'] ?? 'No se pudo completar la operación', 409);
            }

            sistemaLog('info', 'Papelera de proformas: ' . $nombre, ['data' => $r['data'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', $nombre . ' rechazada',
                       ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en ' . $nombre, ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al procesar la papelera', 500);
        }
    }
}
