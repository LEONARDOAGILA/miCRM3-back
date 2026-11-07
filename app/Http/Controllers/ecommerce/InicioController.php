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
 * LAS SECCIONES DE UN CUERPO DE LA TIENDA (administración).
 *
 * Un cuerpo no es una página: es una LISTA DE SECCIONES que se encienden, se
 * apagan y se reordenan —banner, categorías destacadas, ofertas, mosaico,
 * marcas—. Cada una saca sus datos de otro sitio; aquí se guarda cuáles hay,
 * en qué orden van, qué se lee encima y entre qué fechas se ven.
 *
 * LOS CUERPOS SE ADMINISTRAN EN CuerpoController. Aquí se trabaja DENTRO de
 * uno: `allInicio` sin `cuerpo_id` da el del principal, que es lo que pedía
 * la pantalla cuando sólo había una portada.
 *
 * TODO VA POR EL `id` DE LA SECCIÓN, no por su clave. La clave es única dentro
 * del cuerpo, no en la tabla: cada cuerpo tiene su «banner_principal» y sus
 * «categorias_destacadas», así que una clave sola no dice de cuál se habla.
 *
 * POR ESTA PUERTA NO SE CREAN NI SE BORRAN SECCIONES, y hay dos clases:
 *
 *   · Las CINCO DE FÁBRICA existen porque la tienda sabe pintarlas. Una clave
 *     nueva sin código que la pinte sería un hueco invisible, y una borrada
 *     dejaría a la tienda pidiendo algo que ya no está.
 *   · Las de PRODUCTOS son los escaparates de «Productos por sección»: se
 *     crean y se borran allí —ProductoSeccionController—, y su fila en la
 *     portada va y viene con ellas. Aquí se administran como las otras.
 *
 * `allInicio` las devuelve juntas, en su orden, con `fija` diciendo de cuál
 * de las dos clases es cada una.
 *
 * EL RÓTULO ES LO QUE LEE EL CLIENTE encima de la sección, y se escribe aquí:
 * el texto y su pinta —tamaño, color y letra—. La pinta viaja en CLAVES
 * («grande», «deportiva»), nunca en CSS: la base sólo admite las de su lista,
 * así que por esta puerta no entra nada a la hoja de estilos de la tienda.
 *
 * CADA SECCIÓN DICE DE DÓNDE COME: las de banner, de su galería; las de
 * categorías y marcas, de sus pantallas. Las que todavía esperan a que se
 * traslade la suya lo enseñan tal cual, en vez de fingir que se pueden
 * configurar, y la portada pública ya se salta la sección que no tenga nada
 * que enseñar.
 *
 *   GET  ecommerce/inicio/allInicio?cuerpo_id=3   sin él, el cuerpo principal
 * EL ALTO ES EL AIRE QUE OCUPA la sección, no el tamaño de lo que hay dentro:
 * las fotos y las tarjetas siguen midiendo lo que miden. Forzarles un alto
 * desde aquí las sacaría deformadas, y eso no se arregla luego desde una
 * pantalla de administración.
 *
 * LOS BOTONES DE LA TARJETA LLEVAN FONDO Y LETRA, los dos opcionales. Sin
 * fondo, el de la tienda; sin letra, la que se lea encima del fondo, que la
 * calcula la tienda. Así cambiar un color no obliga a elegir dos, y elegir
 * sólo la letra —el corazón rojo sobre el círculo blanco de siempre— es una
 * sola decisión. Una combinación ilegible se avisa en la pantalla, no se
 * prohíbe: igual que con el color del rótulo.
 *
 *   POST ecommerce/inicio/editSeccion/{id}          { titulo?, subtitulo?, rotulo_tamano?,
 *                                                     rotulo_color?, rotulo_fuente?, alto?,
 *                                                     boton_<b>_color?, boton_<b>_texto?
 *                                                       con <b>: favorito | carrito | whatsapp | tarjeta,
 *                                                     descuento_color?, descuento_texto?,
 *                                                     etiqueta?, etiqueta_color?, etiqueta_texto?,
 *                                                     tarjeta_fondo_color?, tarjeta_borde_color?,
 *                                                     alcance?, activo?, desde?, hasta? }
 *   POST ecommerce/inicio/activarSeccion/{id}       { activo? }; sin ella, alterna
 *   POST ecommerce/inicio/altoSeccion/{id}          { alto }; sólo el alto
 *   POST ecommerce/inicio/imagenSeccion/{id}        multipart: imagen; la de al lado de una sección de productos
 *   DELETE ecommerce/inicio/imagenSeccion/{id}      la quita
 *   POST ecommerce/inicio/ordenarSecciones          { ids: [...], cuerpo_id? }
 *
 * EL ALCANCE dice de dónde saca lo que enseña una sección de categorías o de
 * marcas: `tienda` son las destacadas y las marcas de siempre; `cuerpo`, lo
 * que cuelga de la categoría o de la marca a la que apunta su cuerpo. En el
 * principal, que no apunta a nada, da igual lo que ponga.
 *
 * EL FICHERO DE LA IMAGEN VA POR SU PROPIA PUERTA y no con `editSeccion`:
 * esa guarda todos sus campos sin mirar si vienen, así que un guardado que no
 * mandara la imagen la borraría. Lo demás de la imagen —la disposición, el
 * texto y el enlace— sí va con el resto, porque son campos como los otros.
 */
class InicioController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ImagenesDelEcommerce;

    private const ERRORES_NEGOCIO = [
        'P0001' => 422,   // falta un dato obligatorio
        'P0013' => 404,   // la sección no existe
        'P0015' => 422,   // valor inválido
        'P0016' => 422,   // el orden no trae todas las secciones
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

    private function responder($result)
    {
        $r = json_decode($result->result, true);

        // Lo que ve la tienda cambia con cualquiera de estas acciones
        InicioPublicoController::limpiar();

        return $this->successResponse($this->conUrlDeImagen($r['data'] ?? null),
                                      $r['message'] ?? 'Portada de la tienda');
    }

    /**
     * Le pone a cada sección la dirección de su imagen de al lado.
     *
     * EN LA BASE VA SÓLO EL NOMBRE DEL FICHERO, así que la dirección se arma
     * aquí, en un sitio: mover el CRM de máquina es cambiar APP_URL y nada
     * más. Sin fichero, `url` va en null y la pantalla enseña el hueco.
     */
    private function conUrlDeImagen($data)
    {
        if (!is_array($data)) {
            return $data;
        }

        foreach ($data as &$seccion) {
            if (is_array($seccion) && isset($seccion['imagen']) && is_array($seccion['imagen'])) {
                $seccion['imagen']['url'] = $this->urlImagenEcommerce($seccion['imagen']['archivo'] ?? null);
            }
        }
        unset($seccion);

        return $data;
    }

    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en la portada de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Sin `cuerpo_id`, las del principal: es lo que pedía la pantalla de antes. */
    public function allInicio(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $cuerpo = $request->filled('cuerpo_id') ? (int) $request->input('cuerpo_id') : null;

            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_inicio_listar(?::BIGINT) as result', [$cuerpo]
            )->result, true);
            return $this->successResponse($this->conUrlDeImagen($r['data']), $r['message']);
        });
    }

    public function editSeccion(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            // La lista de tamaños y letras no se repite aquí: la tiene la base,
            // en la columna y en la función que guarda. Copiarla sería tener dos
            // listas que un día dejan de decir lo mismo, y la de aquí no es la
            // que manda. Lo que sí se mira es el largo, para que un campo
            // absurdo no llegue a la base como una consulta enorme.
            $validator = Validator::make($d, [
                'titulo'        => 'nullable|string|max:80',
                'subtitulo'     => 'nullable|string|max:80',
                'rotulo_tamano' => 'nullable|string|max:10',
                'rotulo_color'  => 'nullable|string|max:7',
                'rotulo_fuente' => 'nullable|string|max:10',
                'alto'          => 'nullable|string|max:10',
                // El fondo de los cuatro botones de la tarjeta, en secciones
                // de productos. 7 por «#rrggbb», y la base es quien dice si es
                // un color de verdad.
                'boton_favorito_color' => 'nullable|string|max:7',
                'boton_carrito_color'  => 'nullable|string|max:7',
                'boton_whatsapp_color' => 'nullable|string|max:7',
                'boton_tarjeta_color'  => 'nullable|string|max:7',
                // Y el de su letra. Sin él, la tienda pone la que se lea
                // encima del fondo.
                'boton_favorito_texto' => 'nullable|string|max:7',
                'boton_carrito_texto'  => 'nullable|string|max:7',
                'boton_whatsapp_texto' => 'nullable|string|max:7',
                'boton_tarjeta_texto'  => 'nullable|string|max:7',
                // El cartel del descuento de la esquina, y el fondo y el borde
                // de la tarjeta entera. La letra de la tarjeta no se elige: la
                // calcula la tienda para que se lea encima del fondo.
                'descuento_color'      => 'nullable|string|max:7',
                'descuento_texto'      => 'nullable|string|max:7',
                // La etiqueta de encima del descuento. Lleva TEXTO además de
                // los dos colores: el del descuento lo calcula la tienda de
                // los precios, y éste no sale de ningún dato.
                'etiqueta'             => 'nullable|string|max:30',
                'etiqueta_color'       => 'nullable|string|max:7',
                'etiqueta_texto'       => 'nullable|string|max:7',
                'tarjeta_fondo_color'  => 'nullable|string|max:7',
                'tarjeta_borde_color'  => 'nullable|string|max:7',
                // Cómo se enseña la sección y qué hace la imagen de al lado.
                // El FICHERO no está aquí: va por imagenSeccion().
                'disposicion'          => 'nullable|string|max:12',
                // Cómo se enseña un banner: rotando o en carteles
                'banner_vista'         => 'nullable|string|max:12',
                // Cada cuántos segundos se mueve sola la sección: un banner
                // cambia de imagen y una de productos pasa de tarjeta. El rango
                // lo vuelve a mirar la base (fn_validar_entero): aquí es sólo
                // para que un número absurdo no llegue a la consulta
                'segundos'             => 'nullable|integer|min:2|max:60',
                // En qué forma se pintan las fichas de la sección (hoy sólo
                // las categorías destacadas): círculo o cuadrado
                'forma'                => 'nullable|string|max:10',
                // De dónde salen las categorías o las marcas que enseña:
                // «tienda» o «cuerpo». La lista la tiene la base.
                'alcance'              => 'nullable|string|max:10',
                'imagen_alt'           => 'nullable|string|max:120',
                'imagen_enlace'        => 'nullable|string|max:250',
                'imagen_nueva_pestana' => 'nullable|boolean',
                'activo'        => 'nullable|boolean',
                'desde'         => 'nullable|string|max:30',
                'hasta'         => 'nullable|string|max:30',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_seccion_guardar(?::BIGINT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, json_encode($d)], $this->auditoria($request))
            );

            sistemaLog('info', 'Sección de un cuerpo guardada', ['seccion' => (int) $id]);
            return $this->responder($result);
        });
    }

    public function activarSeccion(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            // Sin `activo`, alterna. Es lo que hace el interruptor de la lista.
            $activo = array_key_exists('activo', $d) && $d['activo'] !== null
                ? filter_var($d['activo'], FILTER_VALIDATE_BOOLEAN) : null;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_seccion_activar(?::BIGINT, ?::BOOLEAN, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    /**
     * Sólo el alto, sin tocar lo demás.
     *
     * `editSeccion` guarda la sección entera —lo que no llegue se queda en
     * NULL—, así que estirar una sección con el ratón desde el modelado por
     * esa puerta le borraría el rótulo. Ésta cambia una cosa sola, como
     * `activarSeccion`.
     */
    public function altoSeccion(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, ['alto' => 'required|string|max:10']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_seccion_alto(?::BIGINT, ?::TEXT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, (string) $d['alto']], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    /**
     * Sube (o reemplaza) la imagen de al lado de una sección de productos.
     *
     * VA POR SU PROPIA PUERTA, no con `editSeccion`: aquélla escribe todos sus
     * campos vengan o no, así que guardar el rótulo borraría la imagen.
     */
    public function imagenSeccion(Request $request, $id)
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
                    'SELECT ecommerce.fn_inicio_seccion_imagen(?::BIGINT, ?::TEXT, '
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

    /** La quita de la sección y borra el fichero. */
    public function quitarImagenSeccion(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_seccion_imagen(?::BIGINT, ?::TEXT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, null], $this->auditoria($request))
            );

            return $this->responderImagen($result, null);
        });
    }

    /**
     * Contesta y borra del disco la imagen que acaba de dejar de usarse.
     *
     * SÓLO SE MIRA `inicio_secciones`: estos ficheros se suben por esta puerta
     * y por ninguna otra, así que nadie más puede estar apuntando al que se
     * va. Y el nombre lo pone el servidor al azar, así que tampoco puede
     * coincidir con uno de otra parte.
     */
    private function responderImagen($result, ?string $nuevo)
    {
        $r = json_decode($result->result, true);
        $anterior = $r['anterior'] ?? null;

        if ($anterior && $anterior !== $nuevo) {
            $enUso = DB::selectOne(
                'SELECT count(*) as n FROM ecommerce.inicio_secciones WHERE imagen = ?', [$anterior]
            );
            if ((int) ($enUso->n ?? 0) === 0) {
                $this->borrarImagenEcommerce($anterior);
            }
        }

        InicioPublicoController::limpiar();

        return $this->successResponse($this->conUrlDeImagen($r['data'] ?? null),
                                      $r['message'] ?? 'Portada de la tienda');
    }

    /**
     * Un banner nuevo en un cuerpo.
     *
     * AQUÍ SÍ SE CREAN SECCIONES, y es la excepción: un banner no es más que
     * una galería de imágenes con su sitio en la página, y la tienda ya sabe
     * pintarlo. Las demás clases de sección siguen sin crearse por esta
     * puerta —las de fábrica porque nacen con el cuerpo, las de productos
     * porque se arman en «Productos por sección»—.
     *
     * Nace APAGADO y sin imágenes: se enciende cuando tenga algo que enseñar.
     */
    public function addBanner(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, [
                'nombre'    => 'required|string|max:100',
                // Sin él, el principal: es donde iban cuando sólo había una portada
                'cuerpo_id' => 'nullable|integer',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_banner_crear(?::BIGINT, ?::TEXT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([isset($d['cuerpo_id']) ? (int) $d['cuerpo_id'] : null,
                             (string) $d['nombre']], $this->auditoria($request))
            );

            sistemaLog('info', 'Banner creado', ['nombre' => (string) $d['nombre']]);
            return $this->responder($result);
        });
    }

    /** Le cambia el nombre. Va a la fila de la portada y a su galería. */
    public function nombreBanner(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, ['nombre' => 'required|string|max:100']);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_banner_nombre(?::BIGINT, ?::TEXT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, (string) $d['nombre']], $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }

    /**
     * Lo borra con sus imágenes.
     *
     * NO HAY PAPELERA, y es a propósito: la papelera de una galería vive
     * dentro de la galería, y aquí la galería también se va. Es la misma
     * forma que «vaciar la papelera» de una galería. La pantalla lo pregunta
     * diciendo cuántas imágenes se llevan por delante.
     */
    public function deleteBanner(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_banner_eliminar(?::BIGINT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Banner de la portada borrado', ['seccion' => (int) $id]);
            return $this->responder($result);
        });
    }

    /**
     * Los escaparates de «Productos por sección» que este cuerpo NO enseña.
     *
     * Con cuántos productos tiene cada uno y en cuántas páginas sale ya: uno
     * vacío se puede añadir, pero la tienda se lo salta, y saberlo antes evita
     * poner una sección que no se va a ver.
     */
    public function escaparatesDisponibles(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $cuerpo = $request->filled('cuerpo_id') ? (int) $request->input('cuerpo_id') : null;

            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_inicio_escaparates_disponibles(?::BIGINT) as result', [$cuerpo]
            )->result, true);
            return $this->successResponse($r['data'], $r['message']);
        });
    }

    /**
     * Enseña un escaparate en este cuerpo, al final y encendido.
     *
     * EL MISMO ESCAPARATE PUEDE ESTAR EN VARIAS PÁGINAS, cada una con su
     * rótulo, sus colores y su sitio: lo que se repite es la fila, no los
     * productos.
     */
    public function addEscaparate(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, [
                'seccion_id' => 'required|integer',
                'cuerpo_id'  => 'nullable|integer',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_escaparate_poner(?::BIGINT, ?::BIGINT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([isset($d['cuerpo_id']) ? (int) $d['cuerpo_id'] : null,
                             (int) $d['seccion_id']], $this->auditoria($request))
            );

            sistemaLog('info', 'Escaparate añadido a un cuerpo',
                       ['seccion' => (int) $d['seccion_id'], 'cuerpo' => $d['cuerpo_id'] ?? null]);
            return $this->responder($result);
        });
    }

    /**
     * Lo quita de ESTA página. No borra el escaparate.
     *
     * Sus productos siguen en «Productos por sección» y se puede volver a
     * poner; lo que se va es la fila, con el rótulo y los colores que eran de
     * esta página.
     */
    public function quitarEscaparate(Request $request, $id)
    {
        return $this->ejecutar(function () use ($request, $id) {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_escaparate_quitar(?::BIGINT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Escaparate quitado de un cuerpo', ['seccion' => (int) $id]);
            return $this->responder($result);
        });
    }

    public function ordenarSecciones(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $this->datosDe($request);

            // El orden es DENTRO de un cuerpo: tienen que venir TODAS las
            // suyas, y la base se queja si falta alguna o si llega una de otro
            $validator = Validator::make($d, [
                'ids'       => 'required|array|min:1',
                'ids.*'     => 'integer',
                'cuerpo_id' => 'nullable|integer',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_inicio_ordenar(?::JSONB, ?::BIGINT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([json_encode(array_map('intval', array_values($d['ids']))),
                             isset($d['cuerpo_id']) ? (int) $d['cuerpo_id'] : null],
                            $this->auditoria($request))
            );
            return $this->responder($result);
        });
    }
}
