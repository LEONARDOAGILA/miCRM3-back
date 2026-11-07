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
 * EL ENCABEZADO DE LA TIENDA (ecommerce.encabezado + encabezado_enlaces).
 *
 * Dos cosas en una pantalla:
 *
 *   · LA CONFIGURACIÓN: la franja de arriba (el aviso de los meses sin
 *     intereses), el aviso de crédito directo y las frases que van rotando
 *     dentro del buscador. Es una sola fila: no hay varios encabezados entre
 *     los que elegir, así que no hay listado ni papelera para esto.
 *   · EL MENÚ: enlaces de dos niveles. Un principal con desplegables no lleva
 *     dirección propia —sólo abre el desplegable—, y eso lo decide la base al
 *     servir la tienda, no el que lo configura.
 *
 * TODO DEVUELVE EL ENCABEZADO ENTERO, también crear, borrar y ordenar. Es un
 * árbol pequeño (seis enlaces) y en la pantalla cualquier cambio puede mover
 * otras ramas: devolver sólo lo tocado obligaría al front a recomponer el
 * árbol a mano y a equivocarse en los órdenes.
 *
 *   GET    ecommerce/encabezado/getEncabezado
 *   POST   ecommerce/encabezado/editEncabezado             { config }
 *   POST   ecommerce/encabezado/addEnlace                  { padre_id?, texto, enlace?, icono?, … }
 *   POST   ecommerce/encabezado/editEnlace/{id}
 *   POST   ecommerce/encabezado/activarEnlace/{id}         { activo? }; sin ella, alterna
 *   POST   ecommerce/encabezado/ordenarEnlaces             { ids: [...] }
 *   DELETE ecommerce/encabezado/deleteEnlace/{id}          se lleva sus desplegables
 *   GET    ecommerce/encabezado/papelera
 *   POST   ecommerce/encabezado/restaurar                  { ids: [...] }
 *   DELETE ecommerce/encabezado/vaciarPapelera             (permiso «vaciar»)
 */
class EncabezadoController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0013' => 404,   // no existe
        'P0015' => 422,   // valor inválido
        'P0016' => 422,   // el padre indicado no sirve
        'P0019' => 404,   // no está en la papelera
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    private const PANTALLA = 'editEncabezado';

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

    /** Lo que devuelven casi todas: el encabezado entero. */
    private function responder($result, string $porDefecto = 'Encabezado')
    {
        $r = json_decode($result->result, true);

        // Lo que ve la tienda esta en cache: si no se tira aqui, el cambio
        // tarda hasta diez minutos en salir y parece que no se guardo.
        SeccionPublicaController::limpiar();

        return $this->successResponse($r['data'] ?? null, $r['message'] ?? $porDefecto);
    }

    // ================================================================
    // CONFIGURACIÓN
    // ================================================================

    public function getEncabezado()
    {
        try {
            return $this->responder(DB::selectOne('SELECT ecommerce.fn_encabezado_obtener() as result'));
        } catch (Exception $e) {
            sistemaLog('error', 'Error en getEncabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function editEncabezado(Request $request)
    {
        try {
            $d = $this->datosDe($request);
            if (!isset($d['config']) || !is_array($d['config'])) {
                return $this->errorResponse('Falta la configuración del encabezado', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_modificar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode($d['config'])], $this->auditoria($request))
            );

            sistemaLog('info', 'Encabezado de la tienda modificado');
            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editEncabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // LOS ENLACES DEL MENÚ
    // ================================================================

    public function addEnlace(Request $request)
    {
        return $this->guardarEnlace($request, null);
    }

    public function editEnlace(Request $request, $id)
    {
        return $this->guardarEnlace($request, (int) $id);
    }

    /** Crear y modificar sólo se diferencian en el id (y en que el padre se fija al crear). */
    private function guardarEnlace(Request $request, ?int $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), [
                'padre_id'      => 'nullable|integer',
                'texto'         => 'required|string|max:60',
                'enlace'        => 'nullable|string|max:250',
                'icono'         => 'nullable|string|max:40',
                'activo'        => 'nullable|boolean',
                'nueva_pestana' => 'nullable|boolean',
            ], [
                'texto.required' => 'El texto del enlace es obligatorio',
                'texto.max'      => 'El texto no puede superar los 60 caracteres',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_enlaces_guardar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::VARCHAR, '
                . '?::VARCHAR, ?::BOOLEAN, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id,
                    // Al modificar, el padre lo decide la base (no se cambia aquí)
                    $id === null ? ($d['padre_id'] ?? null) : null,
                    $d['texto'],
                    $d['enlace'] ?? null,
                    $d['icono'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                    array_key_exists('nueva_pestana', $d) ? (bool) $d['nueva_pestana'] : null,
                ], $this->auditoria($request))
            );

            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al guardar un enlace del encabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function activarEnlace(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);
            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_enlaces_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, array_key_exists('activo', $d) ? (bool) $d['activo'] : null],
                            $this->auditoria($request))
            );
            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarEnlace', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function ordenarEnlaces(Request $request)
    {
        try {
            $ids = $this->datosDe($request)['ids'] ?? null;
            if (!is_array($ids) || !$ids) {
                return $this->errorResponse('No se indicó el orden nuevo', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_enlaces_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values(array_map('intval', $ids)))], $this->auditoria($request))
            );
            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en ordenarEnlaces', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function deleteEnlace(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_enlaces_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteEnlace', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // PAPELERA
    // ================================================================

    public function papelera()
    {
        try {
            $r = json_decode(
                DB::selectOne('SELECT ecommerce.fn_encabezado_enlaces_papelera_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en la papelera del encabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function restaurar(Request $request)
    {
        try {
            $ids = $this->datosDe($request)['ids'] ?? null;
            if (!is_array($ids) || !$ids) {
                return $this->errorResponse('No se indicó qué restaurar', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_enlaces_restaurar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values(array_map('intval', $ids)))], $this->auditoria($request))
            );
            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al restaurar enlaces del encabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** No tiene vuelta atrás: el permiso se comprueba aquí, no escondiendo el botón. */
    public function vaciarPapelera(Request $request)
    {
        try {
            if ($no = $this->exigirPermiso(self::PANTALLA, 'vaciar',
                        'No tiene permiso para vaciar la papelera del encabezado')) {
                return $no;
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_enlaces_papelera_vaciar(' . self::CASTS_AUDIT . ') as result',
                $this->auditoria($request)
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Papelera del encabezado vaciada', $r['data'] ?? []);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al vaciar la papelera del encabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
