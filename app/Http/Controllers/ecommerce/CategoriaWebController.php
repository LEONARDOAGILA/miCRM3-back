<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * LAS CATEGORÍAS DE LA TIENDA (ecommerce.categorias_web).
 *
 * El árbol es el del catálogo (inventarios.categorias). Lo que se administra
 * aquí es sólo lo que la tienda hace DISTINTO con él: qué ramas no salen y con
 * qué nombre se enseñan.
 *
 * AQUÍ NO SE CREA, NI SE BORRA, NI SE REORDENA una categoría: eso es de
 * Inventarios. Mezclarlo daría dos sitios para cambiar el árbol y dos formas
 * de dejarlo inconsistente.
 *
 * LA LISTA TRAE EL PORQUÉ DE CADA ESTADO, que es lo que la hace útil: no es lo
 * mismo «la apagaste» que «no tiene ninguna categoría de producto debajo»,
 * porque la primera se arregla aquí y la segunda en el catálogo.
 *
 *   GET  ecommerce/categoriaWeb/allCategoriasWeb
 *   POST ecommerce/categoriaWeb/editCategoriaWeb/{id}   { oculta?, nombre_web? }
 */
class CategoriaWebController extends Controller
{
    use ApiResponder;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,
        'P0013' => 404,
        'P0015' => 422,
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

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

    /** El árbol entero con su estado. Son treinta y tres: no hay que paginar. */
    public function allCategoriasWeb()
    {
        try {
            $r = json_decode(DB::selectOne('SELECT ecommerce.fn_categorias_web_listar() as result')->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allCategoriasWeb', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function editCategoriaWeb(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);

            $result = DB::selectOne(
                'SELECT ecommerce.fn_categorias_web_guardar(?::BIGINT, ?::BOOLEAN, ?::VARCHAR, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    array_key_exists('oculta', $d) ? (bool) $d['oculta'] : false,
                    isset($d['nombre_web']) && trim((string) $d['nombre_web']) !== ''
                        ? trim((string) $d['nombre_web']) : null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            // Lo que ve la tienda cambia: si no se tira la caché, el cambio
            // tarda hasta diez minutos en salir y parece que no se guardó.
            CategoriaWebPublicoController::limpiar();

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editCategoriaWeb', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
