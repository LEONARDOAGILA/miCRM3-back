<?php

namespace App\Http\Controllers\ventas;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use App\Http\Controllers\config\ArchivoController;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;

/**
 * Las notas de un cliente.
 *
 * Lo que hay que saber de él y no es una gestión ni un archivo: cómo le gusta
 * que le llamen, que el gerente de compras sólo atiende los martes, el acuerdo
 * verbal del precio. Son distintas de la `nota` de una gestión: aquélla cuenta
 * qué pasó en una llamada concreta; éstas describen al cliente.
 *
 *   GET    ventas/notaCliente/allNotas?cliente_id=&search=
 *   POST   ventas/notaCliente/addNota
 *   POST   ventas/notaCliente/editNota/{id}
 *   POST   ventas/notaCliente/fijarNota/{id}      { fijada? }  sin fijada, alterna
 *   DELETE ventas/notaCliente/deleteNota/{id}
 */
class NotaClienteController extends Controller
{
    use ApiResponder;

    /** SQLSTATE de las funciones → código HTTP. */
    private const ERRORES_NEGOCIO = [
        'P0001' => 422,  // falta un dato obligatorio
        'P0013' => 404,  // no existe
    ];

    /** La misma carpeta donde van los archivos del cliente. */
    private const CARPETA = 'img/clientes';

    private const CASTS_AUDIT = '?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID';

    /**
     * Lo que se deja pasar del editor.
     *
     * El contenido llega como HTML, así que hay que decidir qué se guarda. La
     * lista es la de ngx-editor y nada más: ni <script>, ni <iframe>, ni <img>
     * con un `onerror`, ni <style>. Angular además sanea al pintar con
     * [innerHTML], pero fiarlo todo al navegador deja la base sucia, y de ahí
     * salen los informes y las exportaciones.
     */
    private const ETIQUETAS_PERMITIDAS =
        '<p><br><strong><b><em><i><u><s><strike><code><pre><blockquote>'
        . '<h1><h2><h3><h4><h5><h6><ul><ol><li><hr><a><sub><sup><span><div><img>'
        // Las tablas del editor (ver esquemaNotas.ts en el front). Sin esto el
        // usuario escribe una tabla y al guardar le queda el texto en fila.
        . '<table><thead><tbody><tfoot><tr><td><th><colgroup><col><caption>';

    /**
     * Las propiedades de css que se dejan pasar dentro de un style.
     *
     * strip_tags conserva TODOS los atributos de las etiquetas que deja, así
     * que hasta ahora el style entraba tal cual. Con el color bastaba, pero el
     * editor ya manda también la letra y el tamaño por ahí (ver esquemaNotas.ts),
     * y un style sin filtrar es una rendija cómoda: position:fixed para tapar la
     * pantalla, o un url(...) que se trae un pixel de seguimiento de fuera.
     *
     * Lista blanca, no negra: lo que no esté aquí se cae. Es la única forma que
     * no hay que ampliar cada vez que alguien inventa una propiedad nueva.
     *
     * Cada una está porque algo la usa:
     *   · color, background-color ... los dos botones de color de la barra
     *   · text-align ............... alinear (el párrafo lo guarda así)
     *   · font-family, font-size ... los desplegables de letra y tamaño
     *   · font-weight, font-style,
     *     text-decoration .......... lo que llega al pegar de Word
     *   · width .................... el ancho de columna de las tablas, que
     *                                prosemirror-tables guarda en el <col>
     */
    private const ESTILOS_PERMITIDOS = [
        'color', 'background-color', 'text-align',
        'font-family', 'font-size', 'font-weight', 'font-style',
        'text-decoration', 'width',
    ];

    /**
     * De dónde puede venir una imagen de una nota.
     *
     * Sólo de nuestro propio endpoint. Así se cae todo lo demás:
     *
     *   · las data: en base64 que mete el navegador al pegar una captura, que
     *     harían la fila enorme y viajarían enteras cada vez que se listan,
     *   · y las de fuera, que además de romperse cuando el otro servidor las
     *     quita, son un pixel de seguimiento gratis dentro del CRM.
     */
    private const RUTA_IMAGEN = 'ventas/archivoCliente/ver/';

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

    /**
     * Deja el HTML en lo que se puede guardar.
     *
     * strip_tags quita las etiquetas que no están en la lista, pero no toca los
     * atributos, así que un <a onclick="…"> sobreviviría: por eso se barren
     * después todos los on* y cualquier href/src que apunte a javascript:.
     */
    /**
     * Deja en cada style sólo las propiedades permitidas.
     *
     * Se reescribe el atributo entero en vez de buscar lo malo y quitarlo: así
     * lo que sale está hecho aquí, declaración por declaración, y no queda nada
     * del original que se haya pasado por alto.
     *
     * Un style que se queda sin nada se va completo, para no dejar style=""
     * sembrado por toda la nota.
     */
    private function limpiarEstilos(string $html): string
    {
        $resultado = preg_replace_callback(
            '/\sstyle\s*=\s*("([^"]*)"|\'([^\']*)\')/i',
            function ($m) {
                // Una de las dos comillas casó; la otra viene vacía o sin poner
                $bruto = ($m[2] ?? '') !== '' ? $m[2] : ($m[3] ?? '');

                // Las entidades se deshacen ANTES de partir por el punto y coma,
                // porque «&quot;» lleva uno dentro.
                //
                // Sin esto, «font-family: Georgia, &quot;Times New Roman&quot;,
                // serif» se partía en tres y sólo sobrevivía «font-family:
                // Georgia, &quot»: el navegador normaliza las comillas simples de
                // una familia a comillas dobles, así que a una letra con el nombre
                // de dos palabras le pasaba siempre.
                $bruto = html_entity_decode($bruto, ENT_QUOTES | ENT_HTML5, 'UTF-8');
                $buenas = [];

                foreach (explode(';', $bruto) as $declaracion) {
                    $partes = explode(':', $declaracion, 2);
                    if (count($partes) !== 2) {
                        continue;
                    }

                    $propiedad = strtolower(trim($partes[0]));
                    $valor = trim($partes[1]);

                    if (!in_array($propiedad, self::ESTILOS_PERMITIDOS, true)) {
                        continue;
                    }
                    if ($valor === '' || mb_strlen($valor) > 120) {
                        continue;
                    }
                    // url() se trae algo de fuera; expression() lo ejecutaba el
                    // IE viejo; la barra invertida sirve para disfrazar las dos
                    if (preg_match('/url\s*\(|expression|javascript|@import|\\\\/i', $valor)) {
                        continue;
                    }

                    // Y se vuelven a poner al escribir el atributo: la comilla
                    // doble lo rompería, y el & suelto dejaría una entidad a
                    // medias. Así «font-family: "Times New Roman"» se conserva.
                    $valor = htmlspecialchars($valor, ENT_COMPAT | ENT_HTML5, 'UTF-8');

                    $buenas[] = $propiedad . ': ' . $valor;
                }

                return $buenas
                    ? ' style="' . implode('; ', $buenas) . '"'
                    : '';
            },
            $html
        );

        // preg_replace_callback devuelve null si la expresión falla; antes de
        // dejar la nota sin estilos, mejor dejarla como estaba
        return $resultado ?? $html;
    }

    private function limpiarHtml(?string $html): string
    {
        // Primero fuera los elementos CON SU CONTENIDO. strip_tags sólo quita las
        // etiquetas, así que un <script>alert(1)</script> dejaría «alert(1)»
        // escrito en la nota: inofensivo, pero basura que el usuario no puso.
        $limpio = preg_replace('/<(script|style|iframe|object|embed)\b[^>]*>.*?<\/\1>/is', '', (string) $html);
        $limpio = preg_replace('/<(script|style|iframe|object|embed)\b[^>]*\/?>/i', '', (string) $limpio);

        $limpio = strip_tags($limpio, self::ETIQUETAS_PERMITIDAS);
        // Atributos que ejecutan algo: onclick, onerror, onload…
        $limpio = preg_replace('/\son[a-z]+\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)/i', '', $limpio);
        // Y del style, sólo las propiedades de la lista blanca
        $limpio = $this->limpiarEstilos($limpio);
        // Enlaces e imágenes que ejecutan: javascript:, vbscript:, data:text/html
        $limpio = preg_replace('/\s(href|src)\s*=\s*("|\')?\s*(javascript|vbscript|data)\s*:[^"\'>]*("|\')?/i', '', $limpio);

        // Las imágenes que no sean nuestras se van enteras.
        //
        // Se permite <img>, pero sólo apuntando a RUTA_IMAGEN. Así se cae todo lo
        // demás: las data: en base64 que mete el navegador al pegar una captura
        // —que harían la fila enorme y viajarían enteras cada vez que se listan—
        // y las de fuera, que además de romperse cuando el otro servidor las
        // quita, son un píxel de seguimiento gratis dentro del CRM.
        $limpio = preg_replace_callback('/<img\b[^>]*>/i', function ($m) {
            return str_contains($m[0], self::RUTA_IMAGEN) ? $m[0] : '';
        }, $limpio);
        return trim($limpio);
    }

    /**
     * El mismo contenido sin etiquetas: es lo que se busca y lo que se enseña
     * como resumen en la lista.
     *
     * Lo calcula el servidor y no el navegador porque es dato derivado: con dos
     * sitios decidiéndolo, un día dejarían de decir lo mismo y la búsqueda
     * empezaría a no encontrar notas que sí existen.
     */
    private function aTextoPlano(?string $html): string
    {
        // Las celdas se separan antes de quitar etiquetas: si no, una tabla queda
        // como «EneroFebreroMarzo» y nadie la encuentra buscando «Febrero»
        $html = preg_replace('/\<\/(td|th)\>/i', ' · ', (string) $html);
        $html = preg_replace('/\<\/tr\>/i', ' ', (string) $html);

        // Los saltos de bloque se vuelven espacios, o «fin.Siguiente» quedaría pegado
        $texto = preg_replace('/<(br|\/p|\/div|\/li|\/h[1-6]|hr)[^>]*>/i', ' ', (string) $html);
        $texto = strip_tags($texto);
        $texto = html_entity_decode($texto, ENT_QUOTES | ENT_HTML5, 'UTF-8');
        $texto = preg_replace('/\s+/u', ' ', $texto);
        // Una tabla con celdas vacías deja «Mes · · · · · ·», que ni se busca ni
        // se lee: los separadores seguidos se juntan en uno y los de los extremos
        // se van
        $texto = preg_replace('/(?:\s*·\s*){2,}/u', ' · ', $texto);
        $texto = trim($texto, " ·\t\n\r");
        return trim($texto);
    }

    // ================================================================
    // LISTAR
    // ================================================================

    public function allNotas(Request $request)
    {
        try {
            $clienteId = (int) $request->query('cliente_id');
            if (!$clienteId) {
                return $this->errorResponse('Debe indicar el cliente', 422);
            }
            $busca = trim((string) $request->query('search', '')) ?: null;

            $result = DB::selectOne(
                'SELECT ventas.fn_notas_clientes_listar(?::BIGINT, ?::VARCHAR) as result',
                [$clienteId, $busca]
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allNotas', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al obtener las notas', 500);
        }
    }

    // ================================================================
    // GUARDAR
    // ================================================================

    public function addNota(Request $request)
    {
        return $this->guardar($request, null);
    }

    public function editNota(Request $request, $id)
    {
        return $this->guardar($request, (int) $id);
    }

    private function guardar(Request $request, ?int $id)
    {
        try {
            $reglas = [
                'titulo'    => 'required|string|min:3|max:150',
                'contenido' => 'nullable|string|max:200000',
                'color'     => 'nullable|string|in:gris,azul,verde,amarillo,rojo,morado',
                'fijada'    => 'nullable|boolean',
            ];
            if ($id === null) { $reglas['cliente_id'] = 'required|integer'; }

            $validator = Validator::make($this->datosDe($request), $reglas, [
                'titulo.required'     => 'El título de la nota es obligatorio',
                'titulo.min'          => 'El título debe tener al menos 3 caracteres',
                'cliente_id.required' => 'Debe indicar el cliente',
                'color.in'            => 'Ese color de etiqueta no es válido',
                'contenido.max'       => 'La nota es demasiado larga',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $html  = $this->limpiarHtml($d['contenido'] ?? null);
            $texto = $this->aTextoPlano($html);

            $result = DB::selectOne(
                'SELECT ventas.fn_notas_clientes_guardar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::TEXT, ?::TEXT, '
                . '?::VARCHAR, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id,
                    isset($d['cliente_id']) ? (int) $d['cliente_id'] : null,
                    $d['titulo'],
                    $html ?: null,
                    $texto ?: null,
                    $d['color'] ?? 'gris',
                    array_key_exists('fijada', $d) ? (bool) $d['fijada'] : false,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Nota de cliente guardada', ['nota_id' => $r['data']['id'] ?? null, 'cliente_id' => $d['cliente_id'] ?? null]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'nota de cliente rechazada', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al guardar la nota', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al guardar la nota', 500);
        }
    }

    // ================================================================
    // FIJAR
    // ================================================================

    /** Sin `fijada` en el cuerpo, alterna lo que tenga. */
    public function fijarNota(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);
            $fijada = array_key_exists('fijada', $d) ? (bool) $d['fijada'] : null;

            $result = DB::selectOne(
                'SELECT ventas.fn_notas_clientes_fijar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $fijada], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'fijarNota rechazada', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al fijar la nota', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al fijar la nota', 500);
        }
    }

    // ================================================================
    // IMÁGENES DE LA NOTA
    // ================================================================

    /**
     * Sube una imagen para incrustarla en una nota y devuelve su enlace.
     *
     * Sube y registra en una sola llamada, al revés que los archivos del
     * cliente: aquí no hay nada que rellenar después —ni nombre, ni
     * descripción— y el editor necesita la url en el acto para ponerla donde
     * está el cursor.
     *
     * Queda como un archivo del cliente con origen 'nota': así tiene una fila
     * que se puede listar, contar y borrar —y el borrado se lleva el fichero—,
     * pero no ensucia la pestaña de Archivos, que enseña los documentos.
     */
    public function subirImagen(Request $request)
    {
        try {
            if (!$request->hasFile('imagen') || !$request->file('imagen')->isValid()) {
                return $this->errorResponse('No se recibió la imagen. Si es muy grande, revise upload_max_filesize y post_max_size en php.ini', 422);
            }

            $clienteId = (int) $request->input('cliente_id');
            if (!$clienteId) {
                return $this->errorResponse('Debe indicar el cliente', 422);
            }
            $existe = DB::selectOne('SELECT id FROM ventas.clientes WHERE id = ? AND deleted_at IS NULL', [$clienteId]);
            if (!$existe) {
                return $this->errorResponse('El cliente no existe o está en la papelera', 404);
            }

            $fichero   = $request->file('imagen');
            $extension = strtolower($fichero->getClientOriginalExtension());
            // Sólo imágenes: esto va dentro de un <img>, y cualquier otra cosa
            // ahí sale rota en vez de dar un error que se entienda
            if (!in_array($extension, ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'avif'], true)) {
                return $this->errorResponse('Sólo se pueden insertar imágenes (jpg, png, gif, webp)', 422);
            }

            $base   = Str::slug(pathinfo($fichero->getClientOriginalName(), PATHINFO_FILENAME)) ?: 'imagen';
            $nombre = $clienteId . '_nota-' . substr($base, 0, 40) . '-' . date('Ymd-His') . '-' . Str::lower(Str::random(6)) . '.' . $extension;

            if (!$fichero->storeAs('public/' . self::CARPETA, $nombre)) {
                return $this->errorResponse('No se pudo guardar la imagen en el servidor', 500);
            }
            $ruta = storage_path('app/public/' . self::CARPETA . '/' . $nombre);
            if (!file_exists($ruta) || filesize($ruta) === 0) {
                if (file_exists($ruta)) { @unlink($ruta); }
                return $this->errorResponse('La imagen llegó vacía o se cortó la subida. Inténtalo de nuevo.', 422);
            }

            $result = DB::selectOne(
                'SELECT ventas.fn_archivos_clientes_guardar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::TEXT, ?::VARCHAR, '
                . '?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::BIGINT, ?::INTEGER, ?::BOOLEAN, ?::VARCHAR, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    null,
                    $clienteId,
                    substr($fichero->getClientOriginalName(), 0, 150),
                    'Imagen de una nota',
                    $nombre,
                    ArchivoController::tipoPorExtension($extension),
                    $extension,
                    $fichero->getClientMimeType(),
                    $fichero->getSize(),
                    null,
                    true,
                    'nota',
                    // Sin gestion: una imagen de nota no cuelga de ninguna
                    null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            $id = $r['data']['id'] ?? null;

            sistemaLog('info', 'Imagen de nota subida', ['archivo_id' => $id, 'cliente_id' => $clienteId]);
            return $this->successResponse([
                'id'  => $id,
                // Relativa: la pantalla le pone delante la base del API, y así
                // cambiar de dominio no deja las notas apuntando al viejo
                'url' => self::RUTA_IMAGEN . $id,
            ], 'Imagen subida');

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'subirImagen rechazada', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al subir la imagen de la nota', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al subir la imagen', 500);
        }
    }

    /**
     * Trae una imagen de otra página y la guarda como propia.
     *
     * Es lo que hace falta al pegar en una nota algo copiado de una web: las
     * imágenes llegan como enlaces a ese otro servidor, y el navegador no las
     * puede descargar (se lo impide el CORS del sitio de origen). O las trae el
     * servidor, o se pierden.
     *
     * Traer una URL que manda el usuario es justo lo que se llama SSRF, así que
     * va con candados:
     *
     *   · sólo http y https —nada de file://, ftp:// ni gopher://—,
     *   · el destino no puede ser una IP privada, local o de enlace: si no,
     *     cualquiera podría usar el CRM para mirar lo que hay en la red interna
     *     o en los metadatos del propio servidor,
     *   · sin seguir redirecciones, que es por donde se cuela lo anterior,
     *   · tope de tamaño y de tiempo, y
     *   · lo que llegue tiene que ser de verdad una imagen.
     */
    public function traerImagen(Request $request)
    {
        try {
            $validator = Validator::make($this->datosDe($request), [
                'cliente_id' => 'required|integer',
                'url'        => 'required|string|max:2048',
            ], [
                'cliente_id.required' => 'Debe indicar el cliente',
                'url.required'        => 'Falta la dirección de la imagen',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $clienteId = (int) $d['cliente_id'];
            $url = trim($d['url']);

            $existe = DB::selectOne('SELECT id FROM ventas.clientes WHERE id = ? AND deleted_at IS NULL', [$clienteId]);
            if (!$existe) {
                return $this->errorResponse('El cliente no existe o está en la papelera', 404);
            }

            [$ok, $motivo] = $this->urlSegura($url);
            if (!$ok) {
                return $this->errorResponse($motivo, 422);
            }

            [$datos, $mime, $error] = $this->descargar($url);
            if ($error) {
                return $this->errorResponse($error, 422);
            }

            $extension = self::EXT_POR_MIME[$mime] ?? null;
            if (!$extension) {
                return $this->errorResponse('Lo que hay en esa dirección no es una imagen', 422);
            }

            $base   = Str::slug(pathinfo(parse_url($url, PHP_URL_PATH) ?? '', PATHINFO_FILENAME)) ?: 'imagen';
            $nombre = $clienteId . '_nota-' . substr($base, 0, 40) . '-' . date('Ymd-His') . '-' . Str::lower(Str::random(6)) . '.' . $extension;

            if (Storage::put('public/' . self::CARPETA . '/' . $nombre, $datos) === false) {
                return $this->errorResponse('No se pudo guardar la imagen en el servidor', 500);
            }

            $result = DB::selectOne(
                'SELECT ventas.fn_archivos_clientes_guardar(?::BIGINT, ?::BIGINT, ?::VARCHAR, ?::TEXT, ?::VARCHAR, '
                . '?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::BIGINT, ?::INTEGER, ?::BOOLEAN, ?::VARCHAR, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    null,
                    $clienteId,
                    substr(basename(parse_url($url, PHP_URL_PATH) ?? 'imagen'), 0, 150),
                    'Imagen de una nota (traída de ' . parse_url($url, PHP_URL_HOST) . ')',
                    $nombre,
                    ArchivoController::tipoPorExtension($extension),
                    $extension,
                    $mime,
                    strlen($datos),
                    null,
                    true,
                    'nota',
                    // Sin gestion: una imagen de nota no cuelga de ninguna
                    null,
                ], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            $id = $r['data']['id'] ?? null;

            sistemaLog('info', 'Imagen de nota traída por url', ['archivo_id' => $id, 'cliente_id' => $clienteId, 'origen' => $url]);
            return $this->successResponse(['id' => $id, 'url' => self::RUTA_IMAGEN . $id], 'Imagen traída');

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al traer la imagen', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('No se pudo traer esa imagen', 422);
        }
    }

    /** Mime de imagen → extensión. Lo que no esté aquí no se guarda. */
    private const EXT_POR_MIME = [
        'image/jpeg' => 'jpg',
        'image/jpg'  => 'jpg',
        'image/png'  => 'png',
        'image/gif'  => 'gif',
        'image/webp' => 'webp',
        'image/bmp'  => 'bmp',
        'image/avif' => 'avif',
    ];

    /** Cuánto se deja traer de fuera. */
    private const MAX_BYTES_IMAGEN = 10485760;  // 10 MB

    /**
     * ¿Se puede ir a buscar ahí?
     *
     * Devuelve [true, null] o [false, por qué]. Rechaza lo que no sea http/https
     * y cualquier destino que resuelva a una dirección privada, local o de
     * enlace: ésa es la puerta por la que un SSRF llega a la red interna o a los
     * metadatos de la nube.
     */
    private function urlSegura(string $url): array
    {
        $partes = parse_url($url);
        if (!$partes || !isset($partes['scheme'], $partes['host'])) {
            return [false, 'Esa dirección no es válida'];
        }
        if (!in_array(strtolower($partes['scheme']), ['http', 'https'], true)) {
            return [false, 'Sólo se pueden traer imágenes por http o https'];
        }

        $ips = @gethostbynamel($partes['host']);
        if (!$ips && filter_var($partes['host'], FILTER_VALIDATE_IP)) { $ips = [$partes['host']]; }
        if (!$ips) {
            return [false, 'No se pudo resolver ese servidor'];
        }

        foreach ($ips as $ip) {
            if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
                return [false, 'Esa dirección apunta a la red interna y no se puede traer'];
            }
        }

        return [true, null];
    }

    /** Descarga con tope de tamaño y de tiempo. Devuelve [datos, mime, error]. */
    private function descargar(string $url): array
    {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            // Sin redirecciones: una redirección a 127.0.0.1 se saltaría urlSegura
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT        => 15,
            CURLOPT_MAXFILESIZE    => self::MAX_BYTES_IMAGEN,
            CURLOPT_USERAGENT      => 'miCRM3',
        ]);
        $datos = curl_exec($ch);
        $mime  = strtolower(explode(';', (string) curl_getinfo($ch, CURLINFO_CONTENT_TYPE))[0]);
        $http  = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $fallo = curl_error($ch);
        curl_close($ch);

        if ($datos === false || $fallo) { return [null, null, 'No se pudo descargar esa imagen']; }
        if ($http >= 300) { return [null, null, 'Ese servidor respondió ' . $http]; }
        if (strlen($datos) > self::MAX_BYTES_IMAGEN) { return [null, null, 'Esa imagen pesa más de 10 MB']; }

        // Lo que diga la cabecera no basta: se mira el contenido
        $real = @getimagesizefromstring($datos);
        if (!$real) { return [null, null, 'Lo que hay en esa dirección no es una imagen']; }

        return [$datos, $real['mime'] ?? $mime, null];
    }

    // ================================================================
    // ELIMINAR
    // ================================================================

    public function deleteNota(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ventas.fn_notas_clientes_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );
            $r = json_decode($result->result, true);
            sistemaLog('info', 'Nota de cliente eliminada', ['nota_id' => $id]);
            return $this->successResponse($r['data'], $r['message']);

        } catch (QueryException $e) {
            [$mensaje, $codigo] = $this->traducirErrorPostgres($e);
            sistemaLog($codigo >= 500 ? 'error' : 'warning', 'deleteNota rechazada', ['sqlstate' => $e->errorInfo[0] ?? null, 'message' => $e->getMessage()]);
            return $this->errorResponse($mensaje, $codigo);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al eliminar la nota', ['message' => $e->getMessage(), 'line' => $e->getLine()]);
            return $this->errorResponse('Ocurrió un error al eliminar la nota', 500);
        }
    }
}
