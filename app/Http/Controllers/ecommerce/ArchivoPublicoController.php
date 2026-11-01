<?php

namespace App\Http\Controllers\ecommerce;

use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * Sirve las imágenes y los PDF de la página web.
 *
 * VA SIN TOKEN, y tiene que ser así: lo pide un `<img src>` o un `<a href>` del
 * navegador de un visitante, que no manda cabecera Authorization. Un fichero
 * dentro del grupo con `jwt.auth` no devuelve la imagen: devuelve un 302 al
 * login, y lo que se ve es el icono de imagen rota.
 *
 * NO están en `storage/app/public` ni se publican con un enlace simbólico:
 * pasan por aquí para que el nombre se compruebe antes de tocar el disco.
 *
 *   GET ecommerce/publico/imagenes/{nombre}
 *   GET ecommerce/publico/documentos/{nombre}
 *
 * LAS DOS RUTAS LEEN DE LA MISMA CARPETA, `storage/app/ecommerce/imagenes`.
 * Suena raro que un PDF salga de «imagenes», pero es donde están: el CRM
 * viejo también lo guardaba todo junto en una sola carpeta, y los 194
 * ficheros se copiaron así. Las dos rutas siguen existiendo porque la
 * dirección dice qué es lo que se pide, y eso decide el tipo que se declara
 * y qué extensiones se aceptan.
 *
 * EL NOMBRE SE VALIDA, no se confía. Llega de la dirección, y un `..` por el
 * medio saca del directorio: la expresión sólo admite letras, números, punto y
 * guiones, y la extensión decide el tipo que se declara. `basename` además de
 * la expresión, porque dos barreras cuestan lo mismo que una.
 */
class ArchivoPublicoController extends Controller
{
    use ApiResponder;

    /** Lo que se acepta como nombre de fichero. */
    private const NOMBRE = '/^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/';

    /** Extensión -> tipo que se declara al navegador. */
    private const TIPOS = [
        'jpg'  => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'png'  => 'image/png',
        'webp' => 'image/webp',
        'gif'  => 'image/gif',
        'svg'  => 'image/svg+xml',
        'pdf'  => 'application/pdf',
    ];

    /** Donde están los ficheros de la página web, imágenes y PDF. */
    public const CARPETA = 'ecommerce/imagenes';

    public function imagen($nombre)
    {
        return $this->servir($nombre, ['jpg', 'jpeg', 'png', 'webp', 'gif', 'svg']);
    }

    public function documento($nombre)
    {
        return $this->servir($nombre, ['pdf']);
    }

    /**
     * El fichero, o un 404 limpio.
     *
     * Un fichero que falta NO es un error del servidor: el dato puede haberse
     * copiado de otra máquina sin la carpeta de ficheros, que es justo lo que
     * pasa al traer la base de la oficina. 404 para que el navegador enseñe su
     * imagen rota y no un 500 en el registro cada vez que se abre la página.
     */
    private function servir(string $nombre, array $extensiones)
    {
        $nombre = basename((string) $nombre);

        if (!preg_match(self::NOMBRE, $nombre)) {
            return $this->errorResponse('Fichero no válido', 400);
        }

        $extension = strtolower(pathinfo($nombre, PATHINFO_EXTENSION));
        if (!in_array($extension, $extensiones, true)) {
            return $this->errorResponse('Fichero no válido', 400);
        }

        $ruta = storage_path('app/' . self::CARPETA . '/' . $nombre);
        if (!is_file($ruta)) {
            Log::info('Fichero de la tienda no encontrado', ['fichero' => $nombre]);
            return $this->errorResponse('Fichero no encontrado', 404);
        }

        // Un año de caché: el nombre lo pone el servidor al subirlo y no se
        // reutiliza, así que un fichero con este nombre nunca cambia.
        return response()->file($ruta, [
            'Content-Type'  => self::TIPOS[$extension] ?? 'application/octet-stream',
            'Cache-Control' => 'public, max-age=31536000, immutable',
        ]);
    }
}
