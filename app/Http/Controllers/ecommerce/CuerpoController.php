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
 * LOS CUERPOS DE LA TIENDA (administración).
 *
 * Un cuerpo es una página hecha de secciones. UNO ES EL PRINCIPAL y es el que
 * sale al abrir la tienda; los demás son páginas que se llegan por su
 * dirección:
 *
 *     Inicio      principal              /
 *     Movilidad   categoría Movilidad    /movilidad
 *     Bajaj       marca Bajaj            /bajaj
 *     Navidad     suelto                 /navidad
 *
 * A QUÉ APUNTA UN CUERPO ES LO QUE HACE QUE LOS ENLACES SALGAN SOLOS: si un
 * cuerpo dice «yo soy la categoría Movilidad», el clic en Movilidad —en el
 * menú, en las destacadas, en el mosaico— lleva a /movilidad en vez de al
 * catálogo filtrado. La categoría o la marca sin cuerpo sigue yendo a /shop.
 *
 * LAS SECCIONES DE CADA CUERPO SE ADMINISTRAN EN InicioController, que trabaja
 * dentro de uno. Aquí se crean los cuerpos, se dice cuál es el principal y se
 * borran.
 *
 * UN CUERPO NUEVO NACE CON LAS SECCIONES DE FÁBRICA APAGADAS, copiadas del
 * principal y cada banner con su propia galería: así se enciende lo que haga
 * falta en vez de empezar con una página en blanco.
 *
 *   GET    ecommerce/cuerpo/allCuerpos
 *   POST   ecommerce/cuerpo/addCuerpo             { nombre, ruta, categoria_id?, marca_id?,
 *                                                   titulo?, descripcion?, catalogo?, activo? }
 *   POST   ecommerce/cuerpo/editCuerpo/{id}       lo mismo
 *   POST   ecommerce/cuerpo/activarCuerpo/{id}    { activo? }; sin ella, alterna
 *   POST   ecommerce/cuerpo/principalCuerpo/{id}  lo pone de entrada de la tienda
 *   DELETE ecommerce/cuerpo/deleteCuerpo/{id}     a la papelera, con sus secciones
 *   GET    ecommerce/cuerpo/papelera
 *   POST   ecommerce/cuerpo/restaurarCuerpo/{id}
 *   DELETE ecommerce/cuerpo/vaciarPapelera        borra de verdad lo que haya ahí
 *
 * SE LIMPIAN LAS DOS CACHÉS PÚBLICAS: la de las páginas (sus secciones) y la
 * del MENÚ DE CATEGORÍAS, que es donde viaja a dónde lleva cada categoría. Si
 * sólo se limpiara la primera, la página nueva existiría y el menú seguiría
 * mandando al catálogo de siempre hasta diez minutos después.
 */
class CuerpoController extends Controller
{
    use ApiResponder;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0013' => 404,   // no existe
        'P0015' => 422,   // valor inválido, o algo que no se puede hacer
        'P0019' => 422,   // no está en la papelera
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    /** Lo que se guarda de un cuerpo, en los dos sentidos. */
    private const REGLAS = [
        'nombre'       => 'required|string|max:100',
        // Minúsculas, números y guiones: es lo que va en la barra del
        // navegador. La base vuelve a mirarlo y además comprueba que no sea
        // una pantalla de la tienda (/shop, /cart…).
        'ruta'         => 'required|string|max:60',
        // A una o a la otra, nunca a las dos. Lo dice la base.
        'categoria_id' => 'nullable|integer',
        'marca_id'     => 'nullable|integer',
        'titulo'       => 'nullable|string|max:120',
        'descripcion'  => 'nullable|string|max:4000',
        'catalogo'     => 'nullable|boolean',
        'activo'       => 'nullable|boolean',
    ];

    public function __construct()
    {
        $this->middleware('auth:api');
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

    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en los cuerpos de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Contesta y tira las dos cachés públicas.
     *
     * La de las páginas porque sus secciones pueden haber cambiado de sitio, y
     * la del menú de categorías porque cada categoría lleva ahí a dónde va: a
     * su página si tiene, y al catálogo filtrado si no.
     */
    private function responder($result)
    {
        $r = json_decode($result->result, true);

        InicioPublicoController::limpiar();
        CategoriaWebPublicoController::limpiar();

        return $this->successResponse($r['data'] ?? null, $r['message'] ?? 'Cuerpos de la tienda');
    }

    public function allCuerpos()
    {
        return $this->ejecutar(function () {
            $r = json_decode(DB::selectOne('SELECT ecommerce.fn_cuerpos_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function addCuerpo(Request $request)
    {
        return $this->guardar($request, null);
    }

    public function editCuerpo(Request $request, $id)
    {
        return $this->guardar($request, (int) $id);
    }

    /** Una sola puerta en la base: sin id, uno nuevo. */
    private function guardar(Request $request, ?int $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, self::REGLAS);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_cuerpos_guardar(?::BIGINT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([$id, json_encode($d)], $this->auditoria($request))
            );

            sistemaLog('info', $id === null ? 'Cuerpo creado' : 'Cuerpo guardado',
                       ['nombre' => (string) ($d['nombre'] ?? ''), 'id' => $id]);
            return $this->responder($result);
        });
    }

    public function activarCuerpo(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            // Sin `activo`, alterna. Es lo que hace el interruptor de la lista.
            $activo = array_key_exists('activo', $d) && $d['activo'] !== null
                ? filter_var($d['activo'], FILTER_VALIDATE_BOOLEAN) : null;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_cuerpos_activar(?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    /** El que sale al abrir la tienda. El de antes deja de serlo. */
    public function principalCuerpo(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_cuerpos_principal(?::BIGINT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Cuerpo principal cambiado', ['id' => (int) $id]);
            return $this->responder($result);
        });
    }

    /** A la papelera, con sus secciones. El principal no se puede borrar. */
    public function deleteCuerpo(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_cuerpos_eliminar(?::BIGINT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Cuerpo enviado a la papelera', ['id' => (int) $id]);
            return $this->responder($result);
        });
    }

    public function papelera()
    {
        return $this->ejecutar(function () {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_cuerpos_papelera_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    public function restaurarCuerpo(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_cuerpos_restaurar(?::BIGINT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Cuerpo restaurado', ['id' => (int) $id]);
            return $this->responder($result);
        });
    }

    /**
     * Vacía la papelera ENTERA: borra de verdad los cuerpos que haya ahí con
     * sus secciones y las galerías de sus banners. No lleva ids, como el resto
     * de las papeleras de la casa: es un botón, no una selección.
     */
    public function vaciarPapelera(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_cuerpos_papelera_vaciar(' . self::CASTS_AUDIT . ') as result',
                $this->auditoria($request)
            );

            sistemaLog('info', 'Papelera de cuerpos vaciada');
            return $this->responder($result);
        });
    }
}
