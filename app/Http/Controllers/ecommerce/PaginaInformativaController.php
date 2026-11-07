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
 * Las PÁGINAS DE TEXTO de la tienda (ecommerce.paginas_informativas).
 *
 * Términos y condiciones, políticas de datos, garantías, «Conócenos». Son
 * páginas que cambian dos veces al año pero que tienen que poder cambiarse sin
 * tocar código ni volver a publicar la tienda, porque las escribe quien las
 * escribe —legal, no sistemas— y porque llevan fecha.
 *
 * DOS CLASES DE PÁGINA:
 *
 *   · Las FIJAS tienen una dirección propia en la tienda (/politicas-de-garantia,
 *     /conocenos). No se borran ni se meten en carpeta: si se borrase, esa
 *     dirección quedaría en un error que desde aquí no se entendería. Se
 *     ocultan.
 *   · Las demás viven en una CARPETA y salen listadas juntas en /documentos
 *     de la tienda.
 *
 * LA CLAVE ES LA DIRECCIÓN. La tienda pide `publico/paginas/{clave}`, y el
 * menú del encabezado guarda esa misma clave en sus enlaces. Por eso se fija
 * al crear y ya no se cambia: cambiarla rompería los enlaces de fuera, que no
 * sabemos cuáles son.
 *
 * Mismo esquema que el resto de la casa: la lógica vive en las funciones
 * ecommerce.fn_paginas_informativas_* (validaciones, auditoría, transacción) y
 * aquí sólo se valida la entrada, se llama con el contexto del usuario y se
 * traduce la respuesta. Lo único propio de este controlador son las
 * DIRECCIONES DE LOS FICHEROS, que la base no guarda (ver ArchivosDeLaTienda).
 *
 *   GET    ecommerce/paginaInformativa/allPaginasInformativas
 *   GET    ecommerce/paginaInformativa/findByIdPaginaInformativa/{id}
 *   GET    ecommerce/paginaInformativa/findByClavePaginaInformativa/{clave}
 *   POST   ecommerce/paginaInformativa/addPaginaInformativa
 *   POST   ecommerce/paginaInformativa/editPaginaInformativa/{id}
 *   POST   ecommerce/paginaInformativa/activarPaginaInformativa/{id}   { activo? }; sin ella, alterna
 *   POST   ecommerce/paginaInformativa/ordenarPaginasInformativas      { ids: [...] }
 *   DELETE ecommerce/paginaInformativa/deletePaginaInformativa/{id}    a la papelera
 *   GET    ecommerce/paginaInformativa/papelera
 *   POST   ecommerce/paginaInformativa/restaurar                       { ids: [...] }
 *   DELETE ecommerce/paginaInformativa/vaciarPapelera                  (permiso «vaciar»)
 *
 *   GET    ecommerce/paginaInformativa/grupos
 *   POST   ecommerce/paginaInformativa/addGrupo
 *   POST   ecommerce/paginaInformativa/editGrupo/{id}
 *   POST   ecommerce/paginaInformativa/ordenarGrupos                   { ids: [...] }
 *   POST   ecommerce/paginaInformativa/restaurarGrupo/{id}
 *   DELETE ecommerce/paginaInformativa/deleteGrupo/{id}                se lleva sus páginas
 */
class PaginaInformativaController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\AccesoDeLaPantalla;
    use \App\Http\Controllers\Concerns\ArchivosDeLaTienda;

    /**
     * SQLSTATE que usan las funciones del módulo para las reglas de negocio.
     * Son errores del usuario, no fallos del servidor: se responden como 4xx.
     */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0006' => 409,   // esa clave o ese nombre ya existen
        'P0013' => 404,   // no existe
        'P0015' => 422,   // valor inválido
        'P0016' => 422,   // la carpeta indicada no existe
        'P0019' => 404,   // no está en la papelera
        'P0021' => 409,   // es fija: no se borra
    ];

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    /** La pantalla del menú, para los permisos del perfil. */
    private const PANTALLA = 'allPaginasInformativas';

    public function __construct()
    {
        $this->middleware('auth:api');
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
            'clave'                   => 'nullable|string|max:50|regex:/^[a-z0-9_-]+$/',
            'titulo'                  => 'required|string|min:2|max:120',
            'grupo_id'                => 'nullable|integer',
            'activo'                  => 'nullable|boolean',
            'contenido'               => 'required|array',
            'contenido.texto'         => 'required|string',
            'contenido.imagen'        => 'nullable|string|max:500',
            'contenido.imagen_alt'    => 'nullable|string|max:150',
            'contenido.pdf'           => 'nullable|string|max:500',
            'contenido.desplegables'  => 'nullable|array|max:6',
        ];
    }

    private function mensajes(): array
    {
        return [
            'titulo.required'    => 'El título es obligatorio',
            'titulo.min'         => 'El título debe tener al menos 2 caracteres',
            'titulo.max'         => 'El título no puede superar los 120 caracteres',
            'clave.regex'        => 'La dirección sólo admite letras sin tilde, números, guiones y guiones bajos',
            'contenido.required' => 'La página necesita contenido',
            'contenido.texto.required' => 'La página necesita texto',
            'contenido.desplegables.max' => 'No caben más de 6 desplegables en una página',
        ];
    }

    // ---------- Las direcciones de los ficheros ----------

    /** El contenido como lo recibe quien lo lee: con las direcciones puestas. */
    private function contenidoParaLeer(?array $c): array
    {
        $c = $c ?: [];
        $c['texto']      = $this->htmlParaLeer($c['texto'] ?? null);
        $c['imagen']     = $this->urlArchivo($c['imagen'] ?? null, 'imagenes');
        $c['pdf']        = $this->urlArchivo($c['pdf'] ?? null, 'documentos');
        $c['desplegables'] = array_map(function ($d) {
            $d['texto'] = $this->htmlParaLeer($d['texto'] ?? null);
            $d['pdf']   = $this->urlArchivo($d['pdf'] ?? null, 'documentos');
            return $d;
        }, $c['desplegables'] ?? []);

        return $c;
    }

    /** Y el camino inverso, antes de guardarlo. */
    private function contenidoParaGuardar(array $c): array
    {
        $limpio = [
            'texto'      => $this->htmlParaGuardar($c['texto'] ?? ''),
            'imagen'     => $this->nombreDeArchivo($c['imagen'] ?? null),
            'imagen_alt' => $c['imagen_alt'] ?? null,
            'pdf'        => $this->nombreDeArchivo($c['pdf'] ?? null),
            'desplegables' => [],
        ];

        foreach (($c['desplegables'] ?? []) as $d) {
            $limpio['desplegables'][] = [
                'titulo' => $d['titulo'] ?? '',
                'texto'  => $this->htmlParaGuardar($d['texto'] ?? ''),
                'pdf'    => $this->nombreDeArchivo($d['pdf'] ?? null),
                'boton'  => $d['boton'] ?? null,
            ];
        }

        return $limpio;
    }

    /** Una página tal como sale de la base, con sus ficheros ya resueltos. */
    private function paginaParaLeer(?array $p): ?array
    {
        if ($p === null) {
            return null;
        }
        // El listado no trae contenido (son cientos de kB de HTML para nada)
        if (array_key_exists('contenido', $p)) {
            $p['contenido'] = $this->contenidoParaLeer($p['contenido']);
        }
        return $p;
    }

    // ================================================================
    // LAS PÁGINAS
    // ================================================================

    /**
     * Todo lo que necesita la pantalla de un tirón: las páginas y las carpetas.
     *
     * Van juntas y no en dos llamadas porque la pantalla no sirve de nada con
     * la mitad: las páginas se pintan DENTRO de su carpeta, y pedirlas aparte
     * sólo añade un estado intermedio en el que la lista está a medias.
     */
    public function allPaginasInformativas(Request $request)
    {
        try {
            $paginas = DB::selectOne('SELECT ecommerce.fn_paginas_informativas_listar() as result');
            $grupos  = DB::selectOne('SELECT ecommerce.fn_paginas_informativas_grupos_listar() as result');

            $p = json_decode($paginas->result, true);
            $g = json_decode($grupos->result, true);

            return $this->successResponse([
                'paginas' => $p['data'] ?? [],
                'grupos'  => $g['data'] ?? [],
            ], 'Páginas informativas');

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allPaginasInformativas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdPaginaInformativa($id)
    {
        try {
            $result = DB::selectOne('SELECT ecommerce.fn_paginas_informativas_obtener(?::BIGINT) as result', [(int) $id]);
            $r = json_decode($result->result, true);

            return $this->successResponse($this->paginaParaLeer($r['data']), $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByIdPaginaInformativa', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Por la clave, que es como la enlaza el menú y como la pide la tienda. */
    public function findByClavePaginaInformativa($clave)
    {
        try {
            $result = DB::selectOne('SELECT ecommerce.fn_paginas_informativas_buscar(?::TEXT) as result', [(string) $clave]);
            $r = json_decode($result->result, true);

            return $this->successResponse($this->paginaParaLeer($r['data']), $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en findByClavePaginaInformativa', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function addPaginaInformativa(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_crear(?::TEXT, ?::VARCHAR, ?::JSONB, ?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    // Sin clave la saca del título la propia función
                    isset($d['clave']) && $d['clave'] !== '' ? $d['clave'] : null,
                    $d['titulo'],
                    json_encode($this->contenidoParaGuardar($d['contenido'])),
                    $d['grupo_id'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Página informativa creada', ['titulo' => $d['titulo']]);
            return $this->successResponse($this->paginaParaLeer($r['data']), $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en addPaginaInformativa', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function editPaginaInformativa(Request $request, $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request), $this->reglas(), $this->mensajes());
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            // La clave NO se manda: es la dirección de la página y se queda
            // como nació. Si llega una, se ignora sin decir nada.
            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_modificar(?::BIGINT, ?::VARCHAR, ?::JSONB, ?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    $d['titulo'],
                    json_encode($this->contenidoParaGuardar($d['contenido'])),
                    $d['grupo_id'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Página informativa modificada', ['id' => $id]);
            return $this->successResponse($this->paginaParaLeer($r['data']), $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editPaginaInformativa', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** La palanca de la lista: sin `activo` en el cuerpo, alterna. */
    public function activarPaginaInformativa(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);

            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            return $this->successResponse($this->paginaParaLeer($r['data']), $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en activarPaginaInformativa', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** El orden que se ve en la tienda; llega la lista entera arrastrada. */
    public function ordenarPaginasInformativas(Request $request)
    {
        try {
            $ids = $this->datosDe($request)['ids'] ?? null;
            if (!is_array($ids) || !$ids) {
                return $this->errorResponse('No se indicó el orden nuevo', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values(array_map('intval', $ids)))], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en ordenarPaginasInformativas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function deletePaginaInformativa(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Página informativa a la papelera', ['id' => $id]);
            return $this->successResponse($this->paginaParaLeer($r['data']), $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deletePaginaInformativa', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // PAPELERA
    // ================================================================

    /** Un solo cesto: carpetas y páginas, que es como se ve en la pantalla. */
    public function papelera()
    {
        try {
            $result = DB::selectOne('SELECT ecommerce.fn_paginas_informativas_papelera_listar() as result');
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en papelera de páginas informativas', ['message' => $e->getMessage()]);
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
                'SELECT ecommerce.fn_paginas_informativas_restaurar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values(array_map('intval', $ids)))], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en restaurar páginas informativas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Vaciar no tiene vuelta atrás, así que el permiso se comprueba AQUÍ y no
     * sólo escondiendo el botón: esconderlo no impide la llamada.
     *
     * La base devuelve los ficheros de lo que borró y es este método quien los
     * quita del disco: la base no toca ficheros, y si la transacción se
     * deshiciera los ficheros ya no estarían.
     */
    public function vaciarPapelera(Request $request)
    {
        try {
            if ($no = $this->exigirPermiso(self::PANTALLA, 'vaciar',
                        'No tiene permiso para vaciar la papelera de páginas informativas')) {
                return $no;
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_papelera_vaciar(' . self::CASTS_AUDIT . ') as result',
                $this->auditoria($request)
            );
            $r = json_decode($result->result, true);

            foreach (($r['data']['ficheros'] ?? []) as $fichero) {
                $this->borrarArchivo($fichero);
            }

            sistemaLog('info', 'Papelera de páginas informativas vaciada', $r['data'] ?? []);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al vaciar la papelera de páginas informativas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Borra un fichero de la tienda; se calla si ya no está.
     *
     * Imágenes y PDF viven en la MISMA carpeta (ver ArchivoPublicoController):
     * es como lo guardaba el CRM viejo y como se copiaron los 194 ficheros.
     */
    private function borrarArchivo(?string $nombre): void
    {
        $nombre = $this->nombreDeArchivo($nombre);
        if (!$nombre) { return; }

        $ruta = storage_path('app/' . ArchivoPublicoController::CARPETA . '/' . $nombre);
        if (is_file($ruta)) { @unlink($ruta); }
    }

    // ================================================================
    // LAS CARPETAS
    // ================================================================

    public function grupos()
    {
        try {
            $result = DB::selectOne('SELECT ecommerce.fn_paginas_informativas_grupos_listar() as result');
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en grupos de páginas informativas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function addGrupo(Request $request)
    {
        return $this->guardarGrupo($request, null);
    }

    public function editGrupo(Request $request, $id)
    {
        return $this->guardarGrupo($request, (int) $id);
    }

    /** Crear y modificar una carpeta sólo se diferencian en el id. */
    private function guardarGrupo(Request $request, ?int $id)
    {
        try {
            $validator = Validator::make($this->datosDe($request),
                ['nombre' => 'required|string|min:2|max:60'],
                ['nombre.required' => 'El nombre de la carpeta es obligatorio',
                 'nombre.min'      => 'El nombre debe tener al menos 2 caracteres',
                 'nombre.max'      => 'El nombre no puede superar los 60 caracteres']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $nombre = $validator->validated()['nombre'];

            $sql = $id === null
                ? 'SELECT ecommerce.fn_paginas_informativas_grupos_crear(?::VARCHAR, ' . self::CASTS_AUDIT . ') as result'
                : 'SELECT ecommerce.fn_paginas_informativas_grupos_modificar(?::BIGINT, ?::VARCHAR, ' . self::CASTS_AUDIT . ') as result';

            $argumentos = $id === null ? [$nombre] : [$id, $nombre];

            $result = DB::selectOne($sql, array_merge($argumentos, $this->auditoria($request)));
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al guardar la carpeta de páginas', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function ordenarGrupos(Request $request)
    {
        try {
            $ids = $this->datosDe($request)['ids'] ?? null;
            if (!is_array($ids) || !$ids) {
                return $this->errorResponse('No se indicó el orden nuevo', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_grupos_ordenar(?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_values(array_map('intval', $ids)))], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en ordenarGrupos', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Borrar una carpeta se lleva sus páginas; lo dice el mensaje. */
    public function deleteGrupo(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_grupos_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Carpeta de páginas a la papelera', ['id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteGrupo', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function restaurarGrupo(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_grupos_restaurar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en restaurarGrupo', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
