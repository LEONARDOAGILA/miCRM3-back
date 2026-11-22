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
 *   POST   ecommerce/encabezado/logo                       { logo: fichero }
 *   DELETE ecommerce/encabezado/logo                       vuelve al de la tienda
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
    use \App\Http\Controllers\Concerns\ImagenesDelEcommerce;

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

        // En la base va el NOMBRE del fichero del logo; la dirección se arma
        // aquí, como con el resto de imágenes del ecommerce
        if (isset($r['data']) && is_array($r['data'])) {
            $r['data']['logo_url'] = $this->urlImagenEcommerce($r['data']['logo'] ?? null);

            // Y la de cada uno de la lista: la pantalla los enseña en fila con
            // su logo, y sin dirección saldrían todos con el hueco gris
            if (isset($r['data']['encabezados']) && is_array($r['data']['encabezados'])) {
                foreach ($r['data']['encabezados'] as &$uno) {
                    $uno['logo_url'] = $this->urlImagenEcommerce($uno['logo'] ?? null);
                }
                unset($uno);
            }
        }

        // Lo que ve la tienda esta en cache: si no se tira aqui, el cambio
        // tarda hasta diez minutos en salir y parece que no se guardo.
        SeccionPublicaController::limpiar();

        return $this->successResponse($r['data'] ?? null, $r['message'] ?? $porDefecto);
    }

    // ================================================================
    // EL LOGO
    // ================================================================
    //
    // VA POR SU PROPIA PUERTA, no con `editEncabezado`: aquélla reescribe el
    // `config` entero, así que guardar los textos de la franja se llevaría por
    // delante el logo. Por eso vive en su columna y se cambia aparte.

    /** Sube (o reemplaza) el logo del encabezado. */
    public function logo(Request $request)
    {
        try {
            if (!$request->hasFile('logo')) {
                return $this->errorResponse('Hace falta la imagen del logo', 422);
            }

            [$nuevo, $error] = $this->guardarImagenEcommerce($request->file('logo'));
            if ($error !== null) {
                return $this->errorResponse($error, 422);
            }

            try {
                $result = DB::selectOne(
                    'SELECT ecommerce.fn_encabezado_logo(?::BIGINT, ?::TEXT, ' . self::CASTS_AUDIT . ') as result',
                    array_merge([$this->cualPiden($request), $nuevo], $this->auditoria($request))
                );
            } catch (QueryException $e) {
                // La fila no llegó a guardarse: el fichero recién subido se
                // quedaría en el disco sin que nada apunte a él
                $this->borrarImagenEcommerce($nuevo);
                throw $e;
            }

            sistemaLog('info', 'Logo del encabezado cambiado');
            return $this->responderLogo($result, $nuevo);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al cambiar el logo', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Lo quita: la tienda vuelve a pintar el suyo. */
    public function quitarLogo(Request $request)
    {
        try {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_logo(?::BIGINT, ?::TEXT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$this->cualPiden($request), null], $this->auditoria($request))
            );

            sistemaLog('info', 'Logo del encabezado quitado');
            return $this->responderLogo($result, null);

        } catch (Exception $e) {
            sistemaLog('error', 'Error al quitar el logo', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Contesta y borra del disco el logo que acaba de dejar de usarse.
     *
     * Es una sola fila y el nombre del fichero lo pone el servidor al azar, así
     * que nadie más puede estar apuntando al que se va.
     */
    private function responderLogo($result, ?string $nuevo)
    {
        $r = json_decode($result->result, true);
        $anterior = $r['anterior'] ?? null;

        if ($anterior && $anterior !== $nuevo) {
            $this->borrarImagenEcommerce($anterior);
        }

        return $this->responder($result, 'Logo actualizado');
    }

    // ================================================================
    // LOS ENCABEZADOS: UNO POR CAMPAÑA
    // ================================================================
    //
    // Hay los que hagan falta, cada uno con su nombre y sus fechas, y uno
    // marcado como PREDETERMINADO: el que se ve cuando no hay ninguna campaña
    // en fecha. Ése no se apaga ni se borra —la base lo impide—, sólo se
    // cambia por otro.
    //
    // Y CADA UNO LLEVA SU MENÚ: los enlaces cuelgan del encabezado, de modo
    // que el de Navidad puede llevar «REGALOS» sin que asome el resto del
    // año. Las llamadas del menú dicen de cuál se trata —`cualPiden`— y, si
    // no lo dicen, se entiende el predeterminado. Crear un encabezado copia
    // el menú del que se copia, y borrarlo se lleva el suyo.

    /** Uno nuevo, copiando la pinta de otro (el predeterminado si no se dice). */
    public function addEncabezado(Request $request)
    {
        try {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, [
                'nombre'    => 'required|string|max:60',
                'copiar_de' => 'nullable|integer',
            ], [
                'nombre.required' => 'Ponle un nombre al encabezado',
                'nombre.max'      => 'El nombre no puede superar los 60 caracteres',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezados_crear(?::TEXT, ?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$d['nombre'], $d['copiar_de'] ?? null], $this->auditoria($request))
            );

            sistemaLog('info', 'Encabezado creado', ['nombre' => $d['nombre']]);
            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al crear el encabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Su nombre y sus fechas. La pinta va por editEncabezado. */
    public function editDatos(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);

            $validator = Validator::make($d, [
                'nombre' => 'required|string|max:60',
                'desde'  => 'nullable|string|max:30',
                'hasta'  => 'nullable|string|max:30',
                'activo' => 'nullable|boolean',
            ], [
                'nombre.required' => 'Ponle un nombre al encabezado',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezados_guardar(?::BIGINT, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, json_encode([
                    'nombre' => $d['nombre'],
                    'desde'  => $this->fechaONada($d['desde'] ?? null),
                    'hasta'  => $this->fechaONada($d['hasta'] ?? null),
                    'activo' => array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                ])], $this->auditoria($request))
            );

            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al guardar el encabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Encenderlo o apagarlo. Sin «activo», alterna. */
    public function activarEncabezado(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);
            $activo = array_key_exists('activo', $d) && $d['activo'] !== null
                ? filter_var($d['activo'], FILTER_VALIDATE_BOOLEAN) : null;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezados_activar(?::BIGINT, ?::BOOLEAN, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $activo], $this->auditoria($request))
            );

            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al activar el encabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Éste pasa a ser el predeterminado (y se enciende). */
    public function predeterminado(Request $request, $id)
    {
        try {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezados_principal(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            sistemaLog('info', 'Encabezado predeterminado cambiado', ['id' => (int) $id]);
            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al cambiar el predeterminado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Borrarlo. El predeterminado no, y su logo se borra del disco. */
    public function deleteEncabezado(Request $request, $id)
    {
        try {
            $logo = DB::selectOne(
                'SELECT logo FROM ecommerce.encabezado WHERE id = ?::BIGINT', [(int) $id])->logo ?? null;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezados_eliminar(?::BIGINT, ' . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id], $this->auditoria($request))
            );

            // El fichero ya no lo mira nadie: cada encabezado tiene el suyo
            if ($logo) {
                $this->borrarImagenEcommerce($logo);
            }

            sistemaLog('info', 'Encabezado borrado', ['id' => (int) $id]);
            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error al borrar el encabezado', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /** Una fecha del formulario, o null si viene vacía. */
    private function fechaONada($valor): ?string
    {
        $v = is_string($valor) ? trim($valor) : '';
        return $v === '' ? null : $v;
    }

    // ================================================================
    // CONFIGURACIÓN
    // ================================================================

    /**
     * CUÁL de los encabezados se está tocando.
     *
     * Sin él, el PREDETERMINADO, que es el que abre la pantalla: así las
     * llamadas de siempre —las que no sabían que iba a haber varios— siguen
     * valiendo y apuntan al mismo sitio de antes.
     */
    private function cualPiden(Request $request): ?int
    {
        $d = $this->datosDe($request);
        $id = $d['encabezado_id'] ?? $request->query('encabezado_id') ?? $request->query('id');

        return ($id === null || $id === '') ? null : (int) $id;
    }

    public function getEncabezado(Request $request)
    {
        try {
            return $this->responder(DB::selectOne(
                'SELECT ecommerce.fn_encabezado_obtener(?::BIGINT) as result', [$this->cualPiden($request)]));
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
                'SELECT ecommerce.fn_encabezado_modificar(?::BIGINT, ?::JSONB, ' . self::CASTS_AUDIT . ') as result',
                array_merge([$this->cualPiden($request), json_encode($d['config'])], $this->auditoria($request))
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
                // DE QUÉ ENCABEZADO ES. Sin él, el predeterminado; si cuelga de
                // otro enlace, manda el encabezado del padre
                'encabezado_id' => 'nullable|integer',
                'padre_id'      => 'nullable|integer',
                'texto'         => 'required|string|max:60',
                'enlace'        => 'nullable|string|max:250',
                'icono'         => 'nullable|string|max:40',
                'activo'        => 'nullable|boolean',
                'nueva_pestana' => 'nullable|boolean',
                // Píldora al final de la barra roja. La base lo apaga sola si
                // el enlace cuelga de un desplegable o si abre uno.
                'destacado'     => 'nullable|boolean',
                // ENTRE QUÉ FECHAS SALE EN EL MENÚ: «Regalos» del 1 de diciembre
                // al 6 de enero, y se apaga solo. Vacías, sale siempre
                'desde'         => 'nullable|string|max:30',
                'hasta'         => 'nullable|string|max:30',
            ], [
                'texto.required' => 'El texto del enlace es obligatorio',
                'texto.max'      => 'El texto no puede superar los 60 caracteres',
            ]);
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }
            $d = $validator->validated();

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_enlaces_guardar(?::BIGINT, ?::BIGINT, ?::BIGINT, '
                . '?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::BOOLEAN, ?::BOOLEAN, ?::BOOLEAN, '
                . '?::TIMESTAMPTZ, ?::TIMESTAMPTZ, ' . self::CASTS_AUDIT . ') as result',
                array_merge([
                    $id,
                    // Al modificar no se mira: un enlace nace en un encabezado y
                    // se queda en él
                    $this->cualPiden($request),
                    // Al modificar, el padre lo decide la base (no se cambia aquí)
                    $id === null ? ($d['padre_id'] ?? null) : null,
                    $d['texto'],
                    $d['enlace'] ?? null,
                    $d['icono'] ?? null,
                    array_key_exists('activo', $d) ? (bool) $d['activo'] : true,
                    array_key_exists('nueva_pestana', $d) ? (bool) $d['nueva_pestana'] : null,
                    array_key_exists('destacado', $d) ? (bool) $d['destacado'] : false,
                    $this->fechaONada($d['desde'] ?? null),
                    $this->fechaONada($d['hasta'] ?? null),
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
                'SELECT ecommerce.fn_encabezado_enlaces_ordenar(?::BIGINT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([$this->cualPiden($request),
                             json_encode(array_values(array_map('intval', $ids)))],
                            $this->auditoria($request))
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

    /**
     * Mueve un enlace: lo cuelga de otro y lo pone en su sitio.
     *
     * ES LO QUE HACE EL ARRASTRE DE LA REJILLA, y por eso van juntos el padre
     * y la posición: soltar una fila dice las dos cosas a la vez. `ordenar`
     * sigue existiendo para mover dentro de la misma rama sin tocar el padre.
     *
     * `padre_id` vacío lo saca a principal; `antes_de` vacío lo deja el último
     * de sus hermanos.
     */
    public function moverEnlace(Request $request, $id)
    {
        try {
            $d = $this->datosDe($request);
            $aEntero = static fn ($v) => ($v === null || $v === '' || $v === 'null') ? null : (int) $v;

            $result = DB::selectOne(
                'SELECT ecommerce.fn_encabezado_enlaces_mover(?::BIGINT, ?::BIGINT, ?::BIGINT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([(int) $id, $aEntero($d['padre_id'] ?? null), $aEntero($d['antes_de'] ?? null)],
                            $this->auditoria($request))
            );

            sistemaLog('info', 'Enlace del encabezado movido', ['id' => (int) $id]);
            return $this->responder($result);

        } catch (QueryException $e) {
            [$m, $c] = $this->traducirErrorPostgres($e);
            return $this->errorResponse($m, $c);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en moverEnlace', ['message' => $e->getMessage()]);
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

    /** La del encabezado que se está editando: cada uno tiene la suya. */
    public function papelera(Request $request)
    {
        try {
            $r = json_decode(DB::selectOne(
                'SELECT ecommerce.fn_encabezado_enlaces_papelera_listar(?::BIGINT) as result',
                [$this->cualPiden($request)])->result, true);
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
                'SELECT ecommerce.fn_encabezado_enlaces_restaurar(?::BIGINT, ?::JSONB, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([$this->cualPiden($request),
                             json_encode(array_values(array_map('intval', $ids)))],
                            $this->auditoria($request))
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
                'SELECT ecommerce.fn_encabezado_enlaces_papelera_vaciar(?::BIGINT, '
                . self::CASTS_AUDIT . ') as result',
                array_merge([$this->cualPiden($request)], $this->auditoria($request))
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
