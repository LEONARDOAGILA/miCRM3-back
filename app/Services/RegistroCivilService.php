<?php

namespace App\Services;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Throwable;

/**
 * Los nombres de una cédula, consultados a ecuadorlegalonline.
 *
 * POR QUÉ ESTÁ EN EL SERVIDOR Y NO EN EL NAVEGADOR: esa página no manda
 * cabeceras CORS, así que un `fetch` desde Angular lo corta el navegador
 * antes de salir. Además, desde aquí se puede cachear, poner un plazo y
 * traducir el HTML a algo que la pantalla entienda.
 *
 * ES UNA AYUDA, NO UNA FUENTE DE VERDAD. La página es de un tercero y se
 * puede caer, cambiar o tardar; por eso hay plazo corto, nunca se lanza una
 * excepción hacia arriba y la ficha del cliente sigue dejando escribir los
 * nombres a mano. Si esto deja de funcionar, lo único que se pierde es que
 * el campo se rellene solo.
 *
 * LO QUE DEVUELVE LA PÁGINA es un trozo de HTML con el nombre completo en un
 * solo texto; partirlo en apellidos y nombres es otro problema, y lo resuelve
 * [[NombrePersona]].
 */
class RegistroCivilService
{
    /** Lo que la propia página llama al pulsar «Consultar» (visto en su red). */
    private const URL = 'https://www.ecuadorlegalonline.com/modulo/consultar-cedula.php';
    private const PAGINA = 'https://www.ecuadorlegalonline.com/consultas/registro-civil/consultar-cedulas/';

    /**
     * MEDIDO: la página tarda entre 10 y 11 segundos cuando encuentra la
     * cédula, y unos 3 cuando no. Con 8 se cortaban TODAS las buenas.
     *
     * Por eso lo encontrado se guarda un mes: se paga una vez por cédula. Y
     * por eso la pantalla no espera con el formulario bloqueado, sino que
     * avisa de que está consultando y deja seguir escribiendo.
     */
    private const SEGUNDOS_ESPERA   = 15;
    private const SEGUNDOS_CONEXION = 5;

    /** Lo encontrado no cambia; lo no encontrado puede ser una cédula recién hecha. */
    private const HORAS_CACHE_ENCONTRADO = 24 * 30;
    private const MINUTOS_CACHE_VACIO    = 30;

    /**
     * @return array{
     *   success: bool, error_code?: string, message?: string,
     *   data?: array{identificacion: string, cedula: string, nombre_completo: string,
     *                apellidos: string, nombres: string, seguro: bool, aviso: ?string,
     *                partes: array<int, string>, fuente: string}
     * }
     */
    public function consultar(string $identificacion): array
    {
        $digitos = preg_replace('/\D/', '', $identificacion) ?? '';

        // Un RUC de persona natural son su cédula y «001» detrás: se consulta
        // con los diez primeros. El de una sociedad no tiene cédula detrás.
        if (strlen($digitos) === 13) {
            if (in_array($digitos[2] ?? '', ['6', '9'], true)) {
                return $this->error('ES_EMPRESA',
                    'Ese RUC es de una sociedad, no de una persona: el Registro Civil sólo devuelve cédulas');
            }
            $digitos = substr($digitos, 0, 10);
        }

        if (!$this->cedulaValida($digitos)) {
            return $this->error('IDENTIFICACION_INVALIDA', 'La cédula no es válida');
        }

        $clave = 'registro_civil:cedula:' . $digitos;
        $cacheado = Cache::get($clave);
        if (is_array($cacheado)) {
            return $cacheado['success']
                ? $this->exito($identificacion, $digitos, $cacheado['nombre'], 'caché')
                : $this->error('NO_ENCONTRADO', 'No hay ninguna cédula con ese número');
        }

        try {
            $respuesta = Http::asForm()
                ->timeout(self::SEGUNDOS_ESPERA)
                ->connectTimeout(self::SEGUNDOS_CONEXION)
                ->withHeaders([
                    // La página rechaza lo que no parezca su propio formulario
                    'User-Agent'       => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
                    'X-Requested-With' => 'XMLHttpRequest',
                    'Referer'          => self::PAGINA,
                    'Accept'           => '*/*',
                    'Accept-Language'  => 'es-EC,es;q=0.9',
                ])
                ->post(self::URL, ['name' => $digitos, 'tipo' => 'I']);

            if (!$respuesta->successful()) {
                return $this->error('SERVICIO_NO_DISPONIBLE',
                    'El servicio del Registro Civil no contestó bien (' . $respuesta->status() . ')');
            }

            $nombre = $this->nombreDelHtml($respuesta->body(), $digitos);

        } catch (Throwable $e) {
            // Se cae, tarda, no hay internet: no es un error del CRM
            sistemaLog('warning', 'Consulta de cédula no disponible',
                       ['cedula' => $digitos, 'message' => $e->getMessage()]);
            return $this->error('SERVICIO_NO_DISPONIBLE',
                'No se pudo consultar el Registro Civil ahora mismo');
        }

        if ($nombre === null) {
            Cache::put($clave, ['success' => false], now()->addMinutes(self::MINUTOS_CACHE_VACIO));
            return $this->error('NO_ENCONTRADO', 'No hay ninguna cédula con ese número');
        }

        Cache::put($clave, ['success' => true, 'nombre' => $nombre], now()->addHours(self::HORAS_CACHE_ENCONTRADO));

        return $this->exito($identificacion, $digitos, $nombre, 'ecuadorlegalonline');
    }

    // ================================================================
    // AYUDANTES
    // ================================================================

    /**
     * El nombre que viene en el HTML de la respuesta.
     *
     * La respuesta es una tabla con una fila por coincidencia: la cédula en
     * `ci0` y el nombre en `name0`. El nombre está DOS VECES —en el enlace,
     * dentro del parámetro `na=`, y en el `<strong>`—; se prefiere el del
     * parámetro porque viene sin entidades HTML de por medio.
     *
     * Cuando no hay nadie con esa cédula, la página contesta con el cuerpo
     * vacío: eso es un «no encontrado», no un error.
     */
    private function nombreDelHtml(string $html, string $cedula): ?string
    {
        $html = trim($html);
        if ($html === '') { return null; }

        // Por si algún día devuelve varias filas: la que lleve esta cédula
        $trozo = $html;
        if (preg_match_all('#<tr\b.*?</tr>#is', $html, $filas) && count($filas[0]) > 1) {
            foreach ($filas[0] as $fila) {
                if (str_contains(preg_replace('/\s+/', '', $fila) ?? '', $cedula)) { $trozo = $fila; break; }
            }
        }

        $limpio = str_replace('&amp;', '&', $trozo);

        if (preg_match('/[?&]na=([^"&\']+)/', $limpio, $m)) {
            $nombre = urldecode($m[1]);
        } elseif (preg_match('#<strong[^>]*>(.*?)</strong>#is', $limpio, $m)) {
            $nombre = html_entity_decode(strip_tags($m[1]), ENT_QUOTES | ENT_HTML5, 'UTF-8');
        } else {
            return null;
        }

        $nombre = trim(preg_replace('/\s+/u', ' ', $nombre) ?? '');

        // «No se encontró», «Sin resultados»… no son un nombre
        if ($nombre === '' || mb_strlen($nombre) < 3 || preg_match('/no (se )?(encontr|existe)/iu', $nombre)) {
            return null;
        }

        return $nombre;
    }

    /**
     * La cédula ecuatoriana: diez dígitos, provincia válida y dígito
     * verificador (módulo 10).
     *
     * Se comprueba AQUÍ para no salir a internet por una cédula mal escrita,
     * que es lo que pasa mientras el usuario todavía está tecleando.
     */
    public function cedulaValida(string $cedula): bool
    {
        if (!preg_match('/^\d{10}$/', $cedula)) { return false; }

        // Los diez dígitos iguales no son una cédula: 2222222222 cumple
        // provincia, tercer dígito y módulo 10 —es la única repetición que lo
        // hace—, y aun así nadie la tiene. La misma regla está en el
        // validador del front; aquí se repite para no salir a internet por
        // un número que se escribió para salir del paso.
        if (preg_match('/^(\d)\1{9}$/', $cedula)) { return false; }

        $provincia = (int) substr($cedula, 0, 2);
        if ($provincia < 1 || ($provincia > 24 && $provincia !== 30)) { return false; }
        if ((int) $cedula[2] > 5) { return false; }   // 6 y 9 son RUC, no cédula

        $suma = 0;
        for ($i = 0; $i < 9; $i++) {
            $valor = (int) $cedula[$i] * ($i % 2 === 0 ? 2 : 1);
            $suma += $valor > 9 ? $valor - 9 : $valor;
        }
        $verificador = (10 - ($suma % 10)) % 10;

        return $verificador === (int) $cedula[9];
    }

    private function exito(string $identificacion, string $cedula, string $nombre, string $fuente): array
    {
        $partes = NombrePersona::separar($nombre);

        return [
            'success' => true,
            'data' => [
                'identificacion'  => $identificacion,
                'cedula'          => $cedula,
                'nombre_completo' => $partes['nombre_completo'],
                'apellidos'       => $partes['apellidos'],
                'nombres'         => $partes['nombres'],
                'seguro'          => $partes['seguro'],
                'aviso'           => $partes['aviso'],
                'partes'          => $partes['partes'],
                'fuente'          => $fuente,
            ],
        ];
    }

    private function error(string $codigo, string $mensaje): array
    {
        return ['success' => false, 'error_code' => $codigo, 'message' => $mensaje];
    }
}
