<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * EL PIE DE LA TIENDA (ecommerce.pie + pie_columnas + pie_enlaces).
 *
 * La configuración —las redes sociales y la línea de los derechos reservados—
 * es una sola fila. Lo que se administra de verdad son las COLUMNAS: cada una
 * con su título y sus enlaces, que es como se ven abajo del todo en la tienda.
 *
 * DOS FRANJAS (desde el 08/11/2026). Una columna lleva su `zona`: «arriba»
 * son las de siempre y «abajo» las de la franja de debajo, donde hasta ese
 * día había dos galerías de medios de pago escritas en el código de la
 * tienda. Es la misma tabla y la misma puerta: lo único que cambia es dónde
 * salen.
 *
 * SE PARECE AL ENCABEZADO PERO NO ES LO MISMO: allí el segundo nivel es un
 * desplegable que se abre al pasar por encima, y un enlace principal puede no
 * llevar dirección. Aquí la columna es un TÍTULO, nunca un enlace, y todos los
 * enlaces de dentro necesitan dirección: una línea sin ella parecería
 * pinchable y no haría nada.
 *
 * Como en el encabezado, todo devuelve el pie entero: son tres columnas con
 * doce enlaces y cualquier cambio mueve órdenes de otras ramas.
 *
 *   GET    ecommerce/pie/getPie
 *   POST   ecommerce/pie/editPie                 { config }
 *   POST   ecommerce/pie/addColumna              { titulo, activo?, zona? }
 *   POST   ecommerce/pie/editColumna/{id}
 *   DELETE ecommerce/pie/deleteColumna/{id}      se lleva sus enlaces
 *   POST   ecommerce/pie/addEnlace               { columna_id, texto, enlace, … }
 *   POST   ecommerce/pie/editEnlace/{id}
 *   DELETE ecommerce/pie/deleteEnlace/{id}
 *   POST   ecommerce/pie/ordenarColumnas         { ids: [...] }
 *   POST   ecommerce/pie/ordenarEnlaces          { ids: [...] }
 */
class PiePaginaController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;
    use \App\Http\Controllers\Concerns\ImagenesDelEcommerce;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,
        'P0013' => 404,
        'P0015' => 422,
        'P0016' => 422,
        'P0019' => 404,
    ];

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

    private function responder($result, string $porDefecto = 'Pie de página')
    {
        $r = json_decode($result->result, true);

        // Misma razon que en el encabezado: la tienda lee de cache.
        SeccionPublicaController::limpiar();

        return $this->successResponse($this->conUrlDeImagen($r['data'] ?? null),
                                      $r['message'] ?? $porDefecto);
    }

    /**
     * La dirección de la imagen de cada columna.
     *
     * En la base va sólo el nombre del fichero; la pantalla necesita poder
     * enseñarla. Se arma aquí y no en la base porque mover el CRM de máquina
     * no puede dejar direcciones viejas guardadas.
     */
    private function conUrlDeImagen($data)
    {
        if (!is_array($data) || !isset($data['columnas']) || !is_array($data['columnas'])) {
            return $data;
        }

        foreach ($data['columnas'] as &$columna) {
            if (is_array($columna) && isset($columna['imagen']) && is_array($columna['imagen'])) {
                $columna['imagen']['url'] = $this->urlImagenEcommerce($columna['imagen']['archivo'] ?? null);
            }
        }
        unset($columna);

        return $data;
    }

    // ================================================================
    // LA IMAGEN DE UNA COLUMNA
    // ================================================================
    //
    // VA POR SU PROPIA PUERTA, como la imagen de una sección del inicio:
    // `editColumna` escribe todos los campos de la columna, así que meter
    // aquí el fichero haría que renombrarla lo borrara.

    public function imagenColumna(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            if (!$request->hasFile('imagen')) {
                return $this->errorResponse('Hace falta la imagen', 422);
            }

            [$nuevo, $error] = $this->guardarImagenEcommerce($request->file('imagen'));
            if ($error !== null) {
                return $this->errorResponse($error, 422);
            }

            try {
                $result = DB::selectOne(
                    'SELECT ecommerce.fn_pie_columna_imagen(?::BIGINT, ?::VARCHAR, '
                    . self::CASTS_AUDIT . ') as result',
                    array_merge([(int) $id, $nuevo], $this->auditoria($request))
                );
            } catch (QueryException $e) {
                // La fila no llegó a guardarse: el fichero recién subido se
                // quedaría en el disco sin que nada apunte a él
                $this->borrarImagenEcommerce($nuevo);
                throw $e;
            }

            return $this->responderImagen($result, $nuevo);
        });
    }

    /** La quita de la columna y borra el fichero. */
    public function quitarImagenColumna(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_pie_columna_imagen(?::BIGINT, ?::VARCHAR, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, null], $this->auditoria($request))
            );

            return $this->responderImagen($result, null);
        });
    }

    /**
     * Contesta y borra del disco la imagen que acaba de dejar de usarse.
     *
     * SÓLO SE MIRA `pie_columnas`: estos ficheros se suben por esta puerta y
     * por ninguna otra, y el nombre lo pone el servidor al azar, así que no
     * puede coincidir con uno de otra parte.
     */
    private function responderImagen($result, ?string $nuevo)
    {
        $r = json_decode($result->result, true);
        $anterior = $r['data']['anterior'] ?? null;

        if ($anterior && $anterior !== $nuevo) {
            $enUso = DB::selectOne(
                'SELECT count(*) as n FROM ecommerce.pie_columnas WHERE imagen = ?', [$anterior]
            );
            if ((int) ($enUso->n ?? 0) === 0) {
                $this->borrarImagenEcommerce($anterior);
            }
        }

        SeccionPublicaController::limpiar();

        return $this->successResponse($this->conUrlDeImagen($r['data'] ?? null),
                                      $r['message'] ?? 'Pie de página');
    }

    /** El try/catch es el mismo en todos: se escribe una vez. */
    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en el pie de página', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // CONFIGURACIÓN
    // ================================================================

    public function getPie()
    {
        return $this->ejecutar(fn () =>
            $this->responder(DB::selectOne('SELECT ecommerce.fn_pie_obtener() as result')));
    }

    public function editPie(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);
            if (!isset($d['config']) || !is_array($d['config'])) {
                return $this->errorResponse('Falta la configuración del pie', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_pie_modificar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode($d['config'])], $this->auditoria($request))
            );

            sistemaLog('info', 'Pie de la tienda modificado');
            return $this->responder($result);
        });
    }

    // ================================================================
    // COLUMNAS
    // ================================================================

    public function addColumna(Request $request)  { return $this->guardarColumna($request, null); }
    public function editColumna(Request $request, $id) { return $this->guardarColumna($request, (int) $id); }

    private function guardarColumna(Request $request, ?int $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $validator = Validator::make($this->datosDe($request), [
                'titulo' => 'required|string|max:60',
                'activo' => 'nullable|boolean',
                // La imagen que puede llevar la columna en vez de sus enlaces.
                // El FICHERO no está aquí: va por imagenColumna(), porque esta
                // puerta escribe todos sus campos y renombrar la columna lo
                // borraría.
                'imagen_alt'           => 'nullable|string|max:120',
                'imagen_enlace'        => 'nullable|string|max:250',
                'imagen_nueva_pestana' => 'nullable|boolean',
                // En qué franja del pie sale: las de siempre («arriba») o la de
                // debajo, encima de los derechos reservados. Si no viene, la base
                // la deja donde estaba (y una columna nueva, arriba).
                'zona' => 'nullable|string|in:arriba,abajo',
            ], [
                'titulo.required' => 'El título de la columna es obligatorio',
                'titulo.max'      => 'El título no puede superar los 60 caracteres',
                'zona.in'         => 'La columna sólo puede ir arriba o abajo',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ecommerce.fn_pie_columnas_guardar(?::BIGINT, ?::VARCHAR, ?::BOOLEAN, '
                . '?::VARCHAR, ?::VARCHAR, ?::BOOLEAN, ' . self::CASTS_AUDIT . ', ?::TEXT) as result',
                array_merge([
                    $id,
                    $d['titulo'],
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                    $d['imagen_alt'] ?? null,
                    $d['imagen_enlace'] ?? null,
                    array_key_exists('imagen_nueva_pestana', $d) ? (bool) $d['imagen_nueva_pestana'] : null,
                ], $this->auditoria($request), [$d['zona'] ?? null])
            );
            return $this->responder($result);
        });
    }

    public function deleteColumna(Request $request, $id)
    {
        return $this->ejecutar(fn () => $this->responder(DB::selectOne(
            'SELECT ecommerce.fn_pie_columnas_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
            array_merge([(int) $id], $this->auditoria($request)))));
    }

    // ================================================================
    // ENLACES
    // ================================================================

    public function addEnlace(Request $request)  { return $this->guardarEnlace($request, null); }
    public function editEnlace(Request $request, $id) { return $this->guardarEnlace($request, (int) $id); }

    private function guardarEnlace(Request $request, ?int $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $validator = Validator::make($this->datosDe($request), [
                'columna_id'    => ($id === null ? 'required' : 'nullable') . '|integer',
                'texto'         => 'required|string|max:60',
                'enlace'        => 'required|string|max:250',
                'icono'         => 'nullable|string|max:40',
                'activo'        => 'nullable|boolean',
                'nueva_pestana' => 'nullable|boolean',
            ], [
                'columna_id.required' => 'Falta decir en qué columna va',
                'texto.required'      => 'El texto del enlace es obligatorio',
                'enlace.required'     => 'El enlace necesita su dirección',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ecommerce.fn_pie_enlaces_guardar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::VARCHAR, '
                . '?::VARCHAR, ?::BOOLEAN, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id,
                    // Al modificar, la columna la decide la base: mover un
                    // enlace de columna es arrastrarlo, no editarlo.
                    $id === null ? $d['columna_id'] : null,
                    $d['texto'],
                    $d['enlace'],
                    $d['icono'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                    array_key_exists('nueva_pestana', $d) ? (bool) $d['nueva_pestana'] : null,
                ], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    public function deleteEnlace(Request $request, $id)
    {
        return $this->ejecutar(fn () => $this->responder(DB::selectOne(
            'SELECT ecommerce.fn_pie_enlaces_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
            array_merge([(int) $id], $this->auditoria($request)))));
    }

    // ================================================================
    // ORDEN
    // ================================================================

    // ================================================================
    // PAPELERA
    // ================================================================

    /** Un solo cesto: columnas y enlaces, que es como se ve en la pantalla. */
    public function papelera()
    {
        return $this->ejecutar(function () {
            $r = json_decode(DB::selectOne('SELECT ecommerce.fn_pie_papelera_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    /** { tipo: 'columna'|'enlace', id } */
    public function restaurar(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);
            $tipo = $d['tipo'] ?? null;
            $id   = $d['id'] ?? null;

            if (!in_array($tipo, ['columna', 'enlace'], true) || !$id) {
                return $this->errorResponse('No se indicó qué restaurar', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_pie_restaurar(?::TEXT, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$tipo, (int) $id], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    /**
     * Vaciar no tiene vuelta atrás, así que el permiso se comprueba AQUÍ:
     * esconder el botón no impide la llamada.
     */
    public function vaciarPapelera(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            if ($no = $this->exigirPermiso('editPie', 'vaciar',
                        'No tiene permiso para vaciar la papelera del pie')) {
                return $no;
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_pie_papelera_vaciar(' . self::CASTS_AUDIT . ') as result',
                $this->auditoria($request)
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Papelera del pie vaciada', $r['data'] ?? []);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function ordenarColumnas(Request $request) { return $this->ordenar($request, 'columnas'); }
    public function ordenarEnlaces(Request $request)  { return $this->ordenar($request, 'enlaces'); }

    private function ordenar(Request $request, string $que)
    {
        return $this->ejecutar(function () use ($request, $que) {
            $ids = $this->datosDe($request)['ids'] ?? null;
            if (!is_array($ids) || !$ids) {
                return $this->errorResponse('No se indicó el orden nuevo', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_pie_ordenar(?::TEXT, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$que, json_encode(array_values(array_map('intval', $ids)))],
                            $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }
}
