<?php

namespace App\Http\Controllers\Concerns;

/**
 * Las direcciones de los ficheros de la página web (imágenes y PDF).
 *
 * EN LA BASE NO SE GUARDA NINGUNA DIRECCIÓN COMPLETA. El CRM viejo guardaba
 * esto dentro del dato:
 *
 *     "pdf": "http://192.168.1.146:8009/api/public/pagina-web/documentos/5IMB….pdf"
 *
 * y eso ya estaba roto en la práctica: apunta a UNA máquina, así que al abrir
 * el mismo CRM desde otra, la imagen no aparece. Mover el servidor de sitio, o
 * pasar de http a https, obligaba a repasar la base entera.
 *
 * Ahora se guarda lo mínimo que identifica al fichero:
 *
 *   · en los campos propios (`imagen`, `pdf`), SÓLO EL NOMBRE;
 *   · dentro del HTML, `imagenes/x.png` o `documentos/y.pdf`, porque ahí un
 *     mismo texto puede llevar de los dos y hace falta saber cuál es cuál.
 *
 * La dirección se arma al LEER y se deshace al GUARDAR, aquí y en un solo
 * sitio. Si el servidor cambia de nombre, cambia APP_URL y ya está.
 */
trait ArchivosDeLaTienda
{
    /** Lo que va delante de todo fichero público de la tienda. */
    protected function baseDeArchivos(): string
    {
        return rtrim(config('app.url'), '/') . '/ecommerce/publico';
    }

    /** La dirección completa de un fichero, o null si no hay fichero. */
    protected function urlArchivo(?string $nombre, string $carpeta): ?string
    {
        $nombre = trim((string) $nombre);
        if ($nombre === '') {
            return null;
        }
        return $this->baseDeArchivos() . '/' . $carpeta . '/' . ltrim($nombre, '/');
    }

    /**
     * El HTML con las direcciones puestas: `src="imagenes/x.png"` pasa a
     * `src="http://…/ecommerce/publico/imagenes/x.png"`.
     *
     * Sólo toca lo que empieza por nuestras dos carpetas: un enlace a otro
     * sitio (https://almacenesespana.ec) se queda como está.
     */
    protected function htmlParaLeer(?string $html): ?string
    {
        if ($html === null || $html === '') {
            return $html;
        }
        return preg_replace(
            '#\b(src|href)="(imagenes|documentos)/#i',
            '$1="' . $this->baseDeArchivos() . '/$2/',
            $html
        );
    }

    /**
     * El camino inverso, al guardar. Quita cualquier servidor que venga
     * delante de nuestras carpetas, venga de donde venga:
     *
     *   · el que acaba de poner htmlParaLeer,
     *   · el que escribió el editor al subir una imagen,
     *   · y el del CRM viejo (…/api/public/pagina-web/…), por si alguien pega
     *     un texto de la página anterior.
     */
    protected function htmlParaGuardar(?string $html): ?string
    {
        if ($html === null || $html === '') {
            return $html;
        }
        // Primero la forma vieja, que lleva su propio prefijo de ruta
        $html = preg_replace(
            '#\b(src|href)="https?://[^"\s]*?/api/public/pagina-web/(imagenes|documentos)/#i',
            '$1="$2/',
            $html
        );
        return preg_replace(
            '#\b(src|href)="https?://[^"\s]*?/ecommerce/publico/(imagenes|documentos)/#i',
            '$1="$2/',
            $html
        );
    }

    /** De un nombre o de una dirección completa, el nombre del fichero. */
    protected function nombreDeArchivo($valor): ?string
    {
        $valor = trim((string) $valor);
        if ($valor === '') {
            return null;
        }
        // Se queda con lo último: vale tanto «x.png» como «http://…/imagenes/x.png»
        $valor = (string) parse_url($valor, PHP_URL_PATH) ?: $valor;
        return basename($valor) ?: null;
    }
}
