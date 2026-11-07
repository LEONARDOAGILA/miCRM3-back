<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use App\Http\Controllers\Controller;
use App\Http\Controllers\Concerns\ArchivosDeLaTienda;
use App\Http\Resources\ApiResponder;

/**
 * LA BIBLIOTECA DE IMÁGENES DE LA TIENDA.
 *
 * UNA SOLA CARPETA PARA TODA LA PÁGINA WEB, `storage/app/ecommerce/imagenes`.
 * El fondo de España Motos, los banners, las tarjetas del inicio, los logos
 * del pie y las imágenes metidas dentro del texto de una página informativa
 * salen todas de aquí. Una carpeta por pantalla sonaba más ordenado, pero
 * obligaría a subir otra vez la misma foto para usarla en dos sitios, y es
 * justo lo que se quiere evitar: se sube una vez y se elige donde haga falta.
 *
 * AQUÍ NO SE BORRA. Una imagen puede estar puesta en una pantalla y además
 * citada dentro del HTML de dos páginas, y no hay forma de preguntárselo al
 * HTML con certeza: borrarla dejaría huecos que nadie relaciona con este
 * botón. Quitarla de un sitio se hace en ese sitio; el fichero se queda.
 *
 * EL NOMBRE LO PONE EL SERVIDOR, cuarenta caracteres al azar como el resto de
 * la carpeta. Dos razones: el nombre de origen puede repetirse («banner.png»
 * lo suben todos) y puede traer acentos, espacios o un `..`, que en una
 * dirección no pintan nada. Como el nombre no se reutiliza, el fichero que
 * sirve esa dirección nunca cambia y se puede cachear un año.
 *
 * NO SE FILTRA NI SE PAGINA EN EL SERVIDOR: son ciento y pico y el selector
 * las filtra en la memoria del navegador. Volver a pedirlas en cada tecla
 * haría parpadear la rejilla para enseñar lo mismo recortado.
 *
 *   GET  ecommerce/imagen/listar          -> las imágenes de la carpeta
 *   POST ecommerce/imagen/subir           -> multipart, campo `imagen`
 */
class ImagenController extends Controller
{
    use ApiResponder;
    use ArchivosDeLaTienda;

    /** La misma carpeta que sirve ArchivoPublicoController. */
    private const CARPETA = ArchivoPublicoController::CARPETA;

    /** Lo que se acepta subir. El PDF se sube desde las páginas, no de aquí. */
    private const EXTENSIONES = ['jpg', 'jpeg', 'png', 'webp', 'gif', 'svg'];

    /** 4 MB. Un banner de 2000px pesa menos; más que esto es una foto sin tocar. */
    private const PESO_MAXIMO = 4194304;

    public function __construct()
    {
        $this->middleware('auth:api');
    }

    /**
     * Las imágenes de la carpeta, la última primero.
     *
     * SE LEE EL DISCO, no una tabla. La carpeta es la verdad: los ciento
     * veinte ficheros que ya están vinieron copiados del CRM anterior y nunca
     * pasaron por una tabla de ficheros, así que una tabla paralela empezaría
     * vacía y mintiendo. El día que sean miles habrá que indexarlos; con unos
     * cientos, un listado de directorio tarda menos que la consulta.
     *
     * LOS PDF NO SALEN aunque estén en la misma carpeta: lo que se pide aquí
     * es una imagen para enseñar.
     */
    public function listar()
    {
        try {
            $carpeta = storage_path('app/' . self::CARPETA);
            if (!is_dir($carpeta)) {
                return $this->successResponse([], 'No hay imágenes todavía');
            }

            $imagenes = [];
            foreach (scandir($carpeta) ?: [] as $nombre) {
                if ($nombre === '.' || $nombre === '..') {
                    continue;
                }
                $extension = strtolower(pathinfo($nombre, PATHINFO_EXTENSION));
                if (!in_array($extension, self::EXTENSIONES, true)) {
                    continue;
                }
                $ruta = $carpeta . DIRECTORY_SEPARATOR . $nombre;
                if (!is_file($ruta)) {
                    continue;
                }

                $imagenes[] = [
                    'nombre'    => $nombre,
                    'url'       => $this->urlArchivo($nombre, 'imagenes'),
                    'peso'      => filesize($ruta) ?: 0,
                    'subida'    => date('Y-m-d H:i:s', filemtime($ruta) ?: time()),
                    'extension' => $extension,
                ];
            }

            // La última arriba: lo que se acaba de subir es lo que se busca
            usort($imagenes, fn ($a, $b) => strcmp($b['subida'], $a['subida']));

            return $this->successResponse($imagenes, count($imagenes) . ' imágenes');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listar imágenes de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * Guarda una imagen y devuelve su nombre y su dirección.
     *
     * SE COMPRUEBA QUE SEA UNA IMAGEN DE VERDAD, no que lo diga la extensión:
     * el nombre y el tipo que manda el navegador los escribe quien sube el
     * fichero. `getimagesize` lee la cabecera del fichero ya guardado en el
     * disco temporal, que es el único que no se puede falsear desde fuera.
     *
     * EL SVG ES LA EXCEPCIÓN y por eso no se acepta: es texto, no tiene
     * cabecera que leer, y puede traer un <script> dentro. Para un logo vale
     * un PNG.
     */
    public function subir(Request $request)
    {
        try {
            if (!$request->hasFile('imagen')) {
                return $this->errorResponse('No llegó ninguna imagen', 422);
            }

            $archivo = $request->file('imagen');
            if (!$archivo->isValid()) {
                return $this->errorResponse('La imagen llegó incompleta: vuelve a intentarlo', 422);
            }

            $extension = strtolower($archivo->getClientOriginalExtension());
            if (!in_array($extension, ['jpg', 'jpeg', 'png', 'webp', 'gif'], true)) {
                return $this->errorResponse(
                    'Sólo se aceptan imágenes jpg, png, webp o gif (el svg no, porque puede traer código dentro)',
                    422
                );
            }

            if ($archivo->getSize() > self::PESO_MAXIMO) {
                return $this->errorResponse(
                    'La imagen pesa ' . round($archivo->getSize() / 1048576, 1)
                    . ' MB y el máximo son 4 MB: guárdala más pequeña antes de subirla',
                    422
                );
            }

            $medidas = @getimagesize($archivo->getRealPath());
            if ($medidas === false) {
                return $this->errorResponse('El fichero no es una imagen', 422);
            }

            $nombre = Str::random(40) . '.' . $extension;
            $archivo->move(storage_path('app/' . self::CARPETA), $nombre);

            return $this->successResponse([
                'nombre'    => $nombre,
                'url'       => $this->urlArchivo($nombre, 'imagenes'),
                'ancho'     => $medidas[0] ?? null,
                'alto'      => $medidas[1] ?? null,
                'extension' => $extension,
            ], 'Imagen subida');

        } catch (Exception $e) {
            sistemaLog('error', 'Error al subir una imagen de la tienda', ['message' => $e->getMessage()]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
