<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Database\QueryException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Tymon\JWTAuth\Facades\JWTAuth;

use App\Http\Controllers\Controller;
use App\Http\Controllers\auth\EmailController;
use App\Http\Resources\ApiResponder;
use App\Models\auth\User;

/**
 * LAS CUENTAS DE LA TIENDA. LA OTRA PUERTA.
 *
 *   POST ecommerce/publico/auth/registro      { nombres, apellidos, email, telefono, identificacion, password }
 *   POST ecommerce/publico/auth/login         { email, password, carrito? }
 *   POST ecommerce/publico/auth/verificar     { email, codigo }
 *   POST ecommerce/publico/auth/reenviar      { email }
 *   POST ecommerce/publico/auth/recuperar     { email }
 *   POST ecommerce/publico/auth/cambiar-clave { email, codigo, password }
 *   GET  ecommerce/publico/auth/yo            (con el token de la tienda)
 *   POST ecommerce/publico/auth/salir         (con el token de la tienda)
 *
 * POR QUÉ NO SE ENTRA POR `/login`, el del CRM: aquél cierra fuera de horario
 * (401 un domingo), tiene un tope de 44 sesiones simultáneas, devuelve los
 * `accesos` del CRM —que no le sirven a la tienda y cuentan cómo está armado
 * por dentro— y, sobre todo, emite un token que vale para TODO el CRM.
 *
 * EL TOKEN DE AQUÍ LLEVA `ambito = tienda`, y el middleware `tienda.auth` no
 * acepta otro. Del otro lado, `usuario.activo` rechaza a las cuentas de tipo
 * 4, así que un cliente no entra al CRM aunque alguien olvide una comprobación.
 *
 * LAS CONTRASEÑAS SE TRATAN AQUÍ, no en la base: `password_hash` y
 * `password_verify`, como el resto del CRM. La base guarda y devuelve el
 * hash; nunca lo calcula ni lo compara.
 *
 * LOS CÓDIGOS TAMBIÉN SE GENERAN AQUÍ y se mandan por correo. Nunca viajan en
 * la respuesta: quien pide un código tiene que ir a buscarlo a su buzón, que
 * es justamente lo que demuestra que el buzón es suyo.
 */
class AuthTiendaController extends Controller
{
    use ApiResponder;

    /** Lo que dura el código de confirmación del correo. */
    private const HORAS_VERIFICACION = 48;

    /** Y el de la contraseña, que es la llave de la cuenta: mucho menos. */
    private const HORAS_RECUPERACION = 2;

    // ================================================================
    // REGISTRARSE
    // ================================================================

    public function registro(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $request->all();

            $email    = $this->correo($d['email'] ?? null);
            $password = (string) ($d['password'] ?? '');

            if ($email === null) {
                return $this->errorResponse('Escribe un correo válido', 422);
            }
            if (strlen($password) < 8) {
                return $this->errorResponse('La contraseña necesita al menos 8 caracteres', 422);
            }

            $codigo = $this->codigo();

            $result = DB::selectOne(
                'SELECT ecommerce.fn_tienda_registrar(
                            ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR,
                            ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::VARCHAR, ?::INTEGER,
                            ?::INET, ?::TEXT, ?::UUID) as result',
                [
                    trim((string) ($d['nombres'] ?? '')),
                    trim((string) ($d['apellidos'] ?? '')),
                    $email,
                    trim((string) ($d['telefono'] ?? '')),
                    trim((string) ($d['identificacion'] ?? '')),
                    password_hash($password, PASSWORD_BCRYPT),
                    $codigo,
                    trim((string) ($d['tipo_identificacion'] ?? 'CC')) ?: 'CC',
                    trim((string) ($d['tipo_cliente'] ?? 'PERSONA')) ?: 'PERSONA',
                    self::HORAS_VERIFICACION,
                    $request->ip(),
                    $request->userAgent(),
                    null,
                ]
            );

            $r = json_decode($result->result, true);
            $usuario = $r['data'] ?? null;

            // El correo se manda DESPUÉS de crear la cuenta y su fallo no la
            // deshace: que el SMTP esté caído no es razón para perder un
            // registro. La tienda ofrece reenviarlo
            $enviado = $this->enviarVerificacion($usuario, $codigo);

            sistemaLog('info', 'Cuenta de tienda creada', ['email' => $email, 'correo_enviado' => $enviado]);

            return $this->successResponse([
                'usuario' => $usuario,
                'token'   => $this->token((int) $usuario['id']),
                'correo_enviado' => $enviado,
            ], $r['message'] ?? 'Cuenta creada');
        });
    }

    // ================================================================
    // ENTRAR Y SALIR
    // ================================================================

    public function login(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $request->all();
            $email    = $this->correo($d['email'] ?? null);
            $password = (string) ($d['password'] ?? '');

            // UN SOLO MENSAJE para «no existe» y «contraseña equivocada»: con
            // dos, cualquiera averigua qué correos tienen cuenta
            $generico = 'El correo o la contraseña no coinciden';

            if ($email === null || $password === '') {
                return $this->errorResponse($generico, 401);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_tienda_credenciales(?::VARCHAR) as result', [$email]);
            $cuenta = json_decode($result->result ?? 'null', true);

            if (!$cuenta || !password_verify($password, $cuenta['hash'] ?? '')) {
                // El mismo tiempo de respuesta que una contraseña buena, para
                // que no se pueda distinguir por lo que tarda
                usleep(random_int(200000, 400000));
                return $this->errorResponse($generico, 401);
            }
            if (!($cuenta['isactive'] ?? false)) {
                return $this->errorResponse('Tu cuenta está desactivada. Escríbenos y la revisamos', 401);
            }

            $id = (int) $cuenta['id'];
            DB::select('SELECT ecommerce.fn_tienda_marcar_entrada(?::BIGINT)', [$id]);

            // El carrito que traía anónimo pasa a ser suyo
            $this->asociarCarrito($d['carrito'] ?? null, $id);

            return $this->successResponse([
                'usuario' => $this->yoDe($id),
                'token'   => $this->token($id),
            ], 'Sesión iniciada');
        });
    }

    /**
     * Cerrar sesión: el token deja de servir.
     *
     * No hay nada que borrar en la base —las cuentas de la tienda no escriben
     * en `sesiones_activas`—, así que esto es sólo invalidar el token.
     */
    public function salir(Request $request)
    {
        return $this->ejecutar(function () {
            try {
                JWTAuth::invalidate(JWTAuth::getToken());
            } catch (Exception $e) {
                // Un token ya caducado o inválido: para quien sale es lo mismo
            }
            return $this->successResponse(null, 'Sesión cerrada');
        });
    }

    /** Los datos de la cuenta con la que se entró. */
    public function yo(Request $request)
    {
        return $this->ejecutar(function () {
            $id = (int) (JWTAuth::parseToken()->authenticate()->id ?? 0);
            return $this->successResponse($this->yoDe($id), 'Tu cuenta');
        });
    }

    // ================================================================
    // EL CORREO
    // ================================================================

    public function verificar(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $request->all();
            $email = $this->correo($d['email'] ?? null);

            if ($email === null || trim((string) ($d['codigo'] ?? '')) === '') {
                return $this->errorResponse('Falta el correo o el código', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_tienda_verificar(?::VARCHAR, ?::VARCHAR) as result',
                [$email, trim((string) $d['codigo'])]
            );
            $r = json_decode($result->result, true);

            return $this->successResponse($r['data'] ?? null, $r['message'] ?? 'Correo confirmado');
        });
    }

    /** Otro código, porque el primero se perdió o caducó. */
    public function reenviar(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $email = $this->correo($request->input('email'));
            if ($email === null) {
                return $this->errorResponse('Escribe un correo válido', 422);
            }

            $codigo = $this->codigo();
            $result = DB::selectOne(
                'SELECT ecommerce.fn_tienda_codigo_verificar(?::VARCHAR, ?::VARCHAR, ?::INTEGER) as result',
                [$email, $codigo, self::HORAS_VERIFICACION]
            );
            $r = json_decode($result->result, true);

            $usuario = $this->yoDe((int) ($r['data']['id'] ?? 0));
            $enviado = $this->enviarVerificacion($usuario, $codigo);

            return $this->successResponse(['correo_enviado' => $enviado],
                                          'Te enviamos un correo nuevo');
        });
    }

    // ================================================================
    // LA CONTRASEÑA
    // ================================================================

    public function recuperar(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $email = $this->correo($request->input('email'));

            // SIEMPRE LO MISMO, exista o no: decir «ese correo no está» es
            // decirle a cualquiera qué correos tienen cuenta
            $mensaje = 'Si ese correo tiene cuenta, te llegará un mensaje';
            if ($email === null) {
                return $this->successResponse(null, $mensaje);
            }

            $codigo = $this->codigo();
            $result = DB::selectOne(
                'SELECT ecommerce.fn_tienda_recuperar_pedir(?::VARCHAR, ?::VARCHAR, ?::INTEGER) as result',
                [$email, $codigo, self::HORAS_RECUPERACION]
            );
            $r = json_decode($result->result, true);

            if (!empty($r['data']['id'])) {
                $usuario = $this->yoDe((int) $r['data']['id']);
                $this->enviarCorreo($usuario, $codigo, 'mail.tienda-recuperar',
                                    'Recupera tu contraseña', self::HORAS_RECUPERACION);
            }

            return $this->successResponse(null, $mensaje);
        });
    }

    public function cambiarClave(Request $request)
    {
        return $this->ejecutar(function () use ($request) {
            $d = $request->all();
            $email    = $this->correo($d['email'] ?? null);
            $password = (string) ($d['password'] ?? '');

            if ($email === null || trim((string) ($d['codigo'] ?? '')) === '') {
                return $this->errorResponse('Falta el correo o el código', 422);
            }
            if (strlen($password) < 8) {
                return $this->errorResponse('La contraseña necesita al menos 8 caracteres', 422);
            }

            $result = DB::selectOne(
                'SELECT ecommerce.fn_tienda_recuperar_cambiar(?::VARCHAR, ?::VARCHAR, ?::VARCHAR) as result',
                [$email, trim((string) $d['codigo']), password_hash($password, PASSWORD_BCRYPT)]
            );
            $r = json_decode($result->result, true);
            $usuario = $r['data'] ?? null;

            // Entra directo: acaba de demostrar que el correo es suyo
            return $this->successResponse([
                'usuario' => $usuario,
                'token'   => $usuario ? $this->token((int) $usuario['id']) : null,
            ], $r['message'] ?? 'Contraseña cambiada');
        });
    }

    // ================================================================
    // LO DE DENTRO
    // ================================================================

    /** El token de la tienda: el mismo JWT, con su ámbito marcado. */
    private function token(int $usuarioId): ?string
    {
        $modelo = User::find($usuarioId);
        if (!$modelo) {
            return null;
        }
        return JWTAuth::claims(['ambito' => 'tienda'])->fromUser($modelo);
    }

    private function yoDe(int $usuarioId): ?array
    {
        if ($usuarioId <= 0) {
            return null;
        }
        $result = DB::selectOne('SELECT ecommerce.fn_tienda_yo(?::BIGINT) as result', [$usuarioId]);
        return json_decode($result->result ?? 'null', true);
    }

    /** Un correo con forma de correo, en minúsculas; null si no lo es. */
    private function correo($valor): ?string
    {
        $email = strtolower(trim((string) ($valor ?? '')));
        return filter_var($email, FILTER_VALIDATE_EMAIL) ? $email : null;
    }

    /** Seis dígitos, con el azar del sistema y no con `rand`. */
    private function codigo(): string
    {
        return str_pad((string) random_int(0, 999999), 6, '0', STR_PAD_LEFT);
    }

    private function enviarVerificacion(?array $usuario, string $codigo): bool
    {
        return $this->enviarCorreo($usuario, $codigo, 'mail.tienda-verificar',
                                   'Confirma tu correo', self::HORAS_VERIFICACION);
    }

    /**
     * El correo con el código.
     *
     * DEVUELVE SI SE PUDO, y nadie se cae si no: con el SMTP caído la cuenta
     * ya está creada y la tienda ofrece reenviar el mensaje.
     */
    private function enviarCorreo(?array $usuario, string $codigo, string $vista,
                                  string $asunto, int $horas): bool
    {
        if (!$usuario || empty($usuario['email'])) {
            return false;
        }

        // DÓNDE VIVE LA TIENDA, para el enlace del correo. Del servidor y no
        // de la petición: si viniera en el cuerpo, cualquiera podría hacer
        // que el correo apunte a su propio sitio
        $tienda = rtrim(env('TIENDA_URL', 'http://192.168.2.173:4201'), '/');

        $datos = (object) [
            'nombre' => $usuario['nombres'] ?? 'Hola',
            'email'  => $usuario['email'],
            'codigo' => $codigo,
            'horas'  => $horas,
            'tienda' => env('TIENDA_NOMBRE', 'Almacenes España'),
            'enlace' => $tienda . '/verificar?email=' . rawurlencode($usuario['email'])
                      . '&codigo=' . rawurlencode($codigo),
        ];

        return (new EmailController())->send_email(
            $usuario['email'], $datos, $asunto . ' - ' . env('APP_NAME'), $vista);
    }

    /** El carrito anónimo que traía pasa a ser del cliente. */
    private function asociarCarrito($token, int $usuarioId): void
    {
        $token = trim((string) ($token ?? ''));
        if ($token === '' || !preg_match('/^[0-9a-f-]{36}$/i', $token)) {
            return;
        }

        try {
            DB::select(
                'SELECT ecommerce.fn_carrito_asociar(?::UUID, (SELECT cliente_id FROM seguridad.users WHERE id = ?::BIGINT))',
                [$token, $usuarioId]
            );
        } catch (Exception $e) {
            // Que el carrito no se enlace no puede impedir entrar
            sistemaLog('warning', 'No se pudo asociar el carrito al entrar', ['message' => $e->getMessage()]);
        }
    }

    /**
     * Los errores de negocio de la base salen con su mensaje.
     *
     * Están escritos para que los lea un cliente («Ese correo ya tiene una
     * cuenta»), así que se enseñan tal cual. Lo demás, en genérico y al
     * registro: quien compra no tiene por qué leer un error de PostgreSQL.
     */
    private function ejecutar(callable $accion)
    {
        try {
            return $accion();
        } catch (QueryException $e) {
            $sqlState = $e->errorInfo[0] ?? null;
            if (in_array($sqlState, ['P0001', 'P0003', 'P0006', 'P0013', 'P0015', 'P0016'], true)) {
                $mensaje = preg_replace('/^.*?ERROR:\s*/s', '', $e->errorInfo[2] ?? '');
                $mensaje = preg_split('/\R\s*(CONTEXT|CONTEXTO|DETALLE|DETAIL|HINT):/', $mensaje)[0];
                return $this->errorResponse(trim($mensaje), 422);
            }
            sistemaLog('error', 'Error en las cuentas de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse('No se pudo completar la operación', 500);
        } catch (Exception $e) {
            sistemaLog('error', 'Error en las cuentas de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse('No se pudo completar la operación', 500);
        } catch (\Throwable $e) {
            // TAMBIÉN LOS `Error`, no sólo las excepciones: una clase mal
            // escrita revienta con un Error, y aquí eso dejaba la cuenta
            // creada y la respuesta en un 500 con la traza entera dentro
            sistemaLog('error', 'Fallo grave en las cuentas de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse('No se pudo completar la operación', 500);
        }
    }
}
