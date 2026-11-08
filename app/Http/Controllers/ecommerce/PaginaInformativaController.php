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
 * TODAS LAS PÁGINAS SON IGUALES (desde el 07/11/2026). Antes había una
 * bandera `fija` que la pantalla no podía cambiar y que, en las cuatro que
 * tienen dirección propia en la tienda (/politicas-de-garantia, /conocenos…),
 * impedía borrarlas, impedía moverlas y las dejaba fuera de /documentos. Se
 * quitó: se editan, se mueven, se borran y salen todas en /documentos.
 *
 * LO QUE ESO CUESTA, Y SE ACEPTÓ: esas cuatro quedan en dos direcciones —la
 * suya, completa, y la genérica de sólo texto a la que lleva la lista— y
 * borrar una deja su dirección del menú en la pantalla de error.
 *
 * NO HAY CARPETAS (se quitaron el 07/11/2026). Esto es un CRUD de páginas:
 * una tabla, una ficha y una papelera. Agrupar diez páginas costaba un árbol
 * en la pantalla, una papelera de dos niveles y ocho funciones en la base.
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
 *   POST   ecommerce/paginaInformativa/addImagenPaginaInformativa      { imagen_file }
 *   POST   ecommerce/paginaInformativa/addPdfPaginaInformativa         { pdf_file }
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
        'P0019' => 404,   // no está en la papelera
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

    /**
     * El encabezado y el pie de la tienda, a rehacerse.
     *
     * SE LLAMA EN TODO LO QUE CAMBIA UNA PÁGINA, porque sus enlaces dependen
     * de ella: un enlace del pie o del menú que lleva a una página apagada,
     * borrada o restaurada deja de salir (o vuelve a salir) en la tienda, y
     * eso lo decide ecommerce.fn_secciones_publicas al pintar. Sin esta
     * llamada el cambio tardaría hasta diez minutos en notarse, que es lo que
     * dura la caché de las secciones.
     */
    private function refrescarSeccionesDeLaTienda(): void
    {
        SeccionPublicaController::limpiar();
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
            'activo'                  => 'nullable|boolean',
            'contenido'               => 'required|array',
            'contenido.texto'         => 'required|string',
            'contenido.imagen'        => 'nullable|string|max:500',
            'contenido.imagen_alt'    => 'nullable|string|max:150',
            'contenido.imagen_lado'   => 'nullable|string|in:izquierda,derecha',
            'contenido.pdf'           => 'nullable|string|max:500',
            'contenido.pdf_nombre'    => 'nullable|string|max:150',
            'contenido.pdf_texto'     => 'nullable|string|max:150',
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
            // De qué lado se pinta la imagen en la tienda. Va aquí y no en una
            // columna porque es de la imagen, y la imagen vive en el contenido.
            'imagen_lado' => $c['imagen_lado'] ?? null,
            'pdf'        => $this->nombreDeArchivo($c['pdf'] ?? null),
            // Cómo se llamaba el fichero que subieron. El del disco lleva la
            // fecha y unos caracteres al azar, y eso no se le puede enseñar a
            // nadie: ni al que administra ni al visitante que lo descarga.
            'pdf_nombre' => $c['pdf_nombre'] ?? null,
            // Lo que se lee al lado del icono en la tienda. Vacío, la tienda
            // saca el botón «Descargar PDF» de siempre.
            'pdf_texto'  => $c['pdf_texto'] ?? null,
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
     * La lista, sin el contenido de cada página.
     *
     * SIN PAGINAR: son diez páginas y no van a ser mil. La rejilla las filtra
     * y las ordena en el navegador, que con esta cantidad va más rápido que
     * pedirle al servidor una página de diez filas.
     */
    public function allPaginasInformativas(Request $request)
    {
        try {
            $result = DB::selectOne('SELECT ecommerce.fn_paginas_informativas_listar() as result');
            $r = json_decode($result->result, true);

            // De la lista sólo viene el NOMBRE de la imagen; la miniatura de
            // la rejilla necesita la dirección entera
            $filas = array_map(function ($p) {
                $p['imagen'] = $this->urlArchivo($p['imagen'] ?? null, 'imagenes');
                return $p;
            }, $r['data'] ?? []);

            return $this->successResponse($filas, $r['message'] ?? 'Páginas informativas');

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
                'SELECT ecommerce.fn_paginas_informativas_crear(?::TEXT, ?::VARCHAR, ?::JSONB, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    // Sin clave la saca del título la propia función
                    isset($d['clave']) && $d['clave'] !== '' ? $d['clave'] : null,
                    $d['titulo'],
                    json_encode($this->contenidoParaGuardar($d['contenido'])),
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Página informativa creada', ['titulo' => $d['titulo']]);
            // La tienda tiene que enterarse: sus enlaces dependen de esta página
            $this->refrescarSeccionesDeLaTienda();

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
                'SELECT ecommerce.fn_paginas_informativas_modificar(?::BIGINT, ?::VARCHAR, ?::JSONB, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([
                    (int) $id,
                    $d['titulo'],
                    json_encode($this->contenidoParaGuardar($d['contenido'])),
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);

            sistemaLog('info', 'Página informativa modificada', ['id' => $id]);
            // La tienda tiene que enterarse: sus enlaces dependen de esta página
            $this->refrescarSeccionesDeLaTienda();

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

            // La tienda tiene que enterarse: sus enlaces dependen de esta página
            $this->refrescarSeccionesDeLaTienda();

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
            // La tienda tiene que enterarse: sus enlaces dependen de esta página
            $this->refrescarSeccionesDeLaTienda();

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

    /** Un solo cesto: la papelera es una lista plana de páginas. */
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

            // La tienda tiene que enterarse: sus enlaces dependen de esta página
            $this->refrescarSeccionesDeLaTienda();

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
            // La tienda tiene que enterarse: sus enlaces dependen de esta página
            $this->refrescarSeccionesDeLaTienda();

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
    // LA IMAGEN DE LA PÁGINA
    // ================================================================

    /**
     * Sube la imagen de una página.
     *
     * VA APARTE DE GUARDAR, como el logo de una marca: un fichero no viaja en
     * un JSON, y partirlo en dos llamadas es más simple que mandar el
     * formulario entero como FormData cada vez que se toca una coma del texto.
     *
     * AQUÍ NO SE GUARDA NADA EN LA BASE. Esto deja el fichero en disco y
     * devuelve su nombre; quien decide si esa página lleva esa imagen es
     * `editPaginaInformativa`, con el contenido completo. Así una imagen
     * subida y luego descartada no cambia la página: se queda un fichero
     * suelto, que es mucho menos malo que una página apuntando a algo que el
     * usuario no llegó a confirmar.
     *
     * El nombre lleva la hora: la misma página puede cambiar de imagen y el
     * navegador tiene que enterarse. Con un nombre fijo por página, el
     * `<img>` seguiría enseñando la vieja hasta que alguien vacíe la caché.
     */
    public function addImagenPaginaInformativa(Request $request)
    {
        try {
            $validator = Validator::make($request->all(), [
                'imagen_file' => 'required|file|image|mimes:jpg,jpeg,png,webp|max:10240',
            ], [
                'imagen_file.required' => 'No se encontró la imagen para guardar',
                'imagen_file.image'    => 'El archivo debe ser una imagen',
                'imagen_file.mimes'    => 'La imagen debe ser jpg, png o webp',
                'imagen_file.max'      => 'La imagen no puede superar los 10 MB',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $file      = $request->file('imagen_file');
            $extension = strtolower($file->getClientOriginalExtension() ?: 'jpg');
            // La base sólo admite estas cuatro (fn_paginas_informativas_contenido_validar)
            if (!in_array($extension, ['jpg', 'jpeg', 'png', 'webp'], true)) {
                $extension = 'jpg';
            }
            $nombre = 'pagina_' . date('YmdHis') . '_' . bin2hex(random_bytes(3)) . '.' . $extension;

            if (!$file->storeAs(ArchivoPublicoController::CARPETA, $nombre)) {
                return $this->errorResponse('Error al guardar el archivo', 500);
            }

            $ruta = storage_path('app/' . ArchivoPublicoController::CARPETA . '/' . $nombre);
            if (!is_file($ruta) || filesize($ruta) === 0) {
                return $this->errorResponse('El archivo no se guardó correctamente', 500);
            }

            sistemaLog('info', 'Imagen de página informativa subida', ['imagen' => $nombre]);

            return $this->successResponse([
                'imagen'    => $nombre,
                'full_path' => $this->urlArchivo($nombre, 'imagenes'),
            ], 'Imagen subida');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en addImagenPaginaInformativa', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // ================================================================
    // EL PDF DE LA PÁGINA
    // ================================================================

    /**
     * Sube el PDF de una página.
     *
     * LO MISMO QUE LA IMAGEN, y por los mismos motivos: deja el fichero en
     * disco y devuelve su nombre, y quien decide si esa página lleva ese
     * documento es el guardado, con el contenido entero.
     *
     * HASTA HOY EL PDF NO SE PODÍA TOCAR. Venía heredado del CRM viejo: el
     * editor lo enseñaba y lo devolvía tal cual, sin poder cambiarlo ni
     * quitarlo. Ahora se sube desde la ficha de la página.
     *
     * SE DEVUELVE TAMBIÉN `pdf_nombre`, que es cómo se llamaba el fichero que
     * eligieron. El del disco lleva la fecha y seis caracteres al azar —dos
     * páginas no pueden pisarse, y el navegador tiene que enterarse al
     * cambiarlo—, así que es el nombre original el que se enseña y el que se
     * descarga. Se limpia aquí: llega del navegador y acaba en una pantalla.
     *
     * 15 MB, no 20: el servidor acepta 20 (upload_max_filesize) y si el
     * fichero llega justo en el límite PHP lo corta ANTES de que Laravel vea
     * nada, y la respuesta sería un error raro en vez de «es muy grande».
     */
    public function addPdfPaginaInformativa(Request $request)
    {
        try {
            $validator = Validator::make($request->all(), [
                'pdf_file' => 'required|file|mimes:pdf|max:15360',
            ], [
                'pdf_file.required' => 'No se encontró el documento para guardar',
                'pdf_file.mimes'    => 'El documento debe ser un PDF',
                'pdf_file.max'      => 'El documento no puede superar los 15 MB',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $file   = $request->file('pdf_file');
            $nombre = 'pagina_' . date('YmdHis') . '_' . bin2hex(random_bytes(3)) . '.pdf';

            if (!$file->storeAs(ArchivoPublicoController::CARPETA, $nombre)) {
                return $this->errorResponse('Error al guardar el archivo', 500);
            }

            $ruta = storage_path('app/' . ArchivoPublicoController::CARPETA . '/' . $nombre);
            if (!is_file($ruta) || filesize($ruta) === 0) {
                return $this->errorResponse('El archivo no se guardó correctamente', 500);
            }

            sistemaLog('info', 'PDF de página informativa subido', ['pdf' => $nombre]);

            return $this->successResponse([
                'pdf'        => $nombre,
                'pdf_nombre' => $this->nombreVisibleDePdf($file->getClientOriginalName()),
                'full_path'  => $this->urlArchivo($nombre, 'documentos'),
            ], 'Documento subido');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en addPdfPaginaInformativa', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * El nombre que eligió el usuario, en condiciones de enseñarse.
     *
     * Viene del navegador, así que no se confía: se queda sólo con el nombre
     * (sin carpetas), se quitan los caracteres de control y los que podrían
     * cerrar una etiqueta, y se recorta a lo que admite la base. Sin nombre
     * utilizable, null: la pantalla ya sabe poner «Documento.pdf».
     */
    private function nombreVisibleDePdf(?string $original): ?string
    {
        $nombre = basename(trim((string) $original));
        $nombre = preg_replace('/[\x00-\x1F\x7F<>"]+/u', '', $nombre);
        $nombre = trim(preg_replace('/\s+/u', ' ', (string) $nombre));

        if ($nombre === '' || $nombre === '.' || $nombre === '..') {
            return null;
        }
        // mb_substr y no substr: cortar por bytes parte una tilde por la mitad
        return mb_substr($nombre, 0, 150);
    }
}
