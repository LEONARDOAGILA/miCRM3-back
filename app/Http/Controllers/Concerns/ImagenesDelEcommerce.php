<?php

namespace App\Http\Controllers\Concerns;

use Illuminate\Http\UploadedFile;
use Illuminate\Support\Str;

/**
 * LAS IMÁGENES DE LA TIENDA: CATEGORÍAS, MARCAS Y PRODUCTOS.
 *
 * VAN EN `storage/app/public/img/ecommerce`, que es donde el CRM guarda el
 * resto de sus imágenes —usuarios, marcas, productos, sucursales— y se sirven
 * por el enlace `public/storage` que ya existe. No hay controlador que las
 * sirva ni ruta que mantener: el servidor web las entrega como un fichero
 * más, y eso es una pieza menos que se puede romper.
 *
 * EN LA BASE VA SÓLO EL NOMBRE DEL FICHERO. La dirección se arma al leer, en
 * un solo sitio, así que mover el CRM de máquina o pasar de http a https es
 * cambiar APP_URL y nada más. Guardar la dirección entera es lo que dejó el
 * CRM anterior lleno de imágenes rotas apuntando a una máquina que ya no
 * estaba.
 *
 * EL NOMBRE LO PONE EL SERVIDOR, cuarenta caracteres al azar. El de origen
 * puede repetirse («banner.png» lo suben todos) y puede traer acentos,
 * espacios o un `..`, que en una dirección no pintan nada. Como el nombre no
 * se reutiliza, el fichero que sirve esa dirección nunca cambia.
 */
trait ImagenesDelEcommerce
{
    /** Donde se guardan, relativo a `storage/app`. */
    protected function carpetaEcommerce(): string
    {
        return 'public/img/ecommerce';
    }

    /** Lo que se acepta subir. El svg no: es texto y puede traer un <script>. */
    protected function extensionesImagen(): array
    {
        return ['jpg', 'jpeg', 'png', 'webp', 'gif'];
    }

    /** 4 MB. Un banner de 2000px pesa menos; más que esto es una foto sin tocar. */
    protected function pesoMaximoImagen(): int
    {
        return 4194304;
    }

    /** La dirección completa, o null si no hay fichero. */
    protected function urlImagenEcommerce(?string $nombre): ?string
    {
        $nombre = trim((string) $nombre);
        if ($nombre === '') {
            return null;
        }
        return rtrim(config('app.url'), '/') . '/storage/img/ecommerce/' . basename($nombre);
    }

    /**
     * El logo de una marca, que NO está en esta carpeta.
     *
     * Vive en `img/marcas` porque es del catálogo de Inventarios, no de la
     * tienda: la tienda sólo lo usa cuando la marca no tiene una imagen
     * programada en fecha.
     */
    protected function urlLogoDeMarca(?string $nombre): ?string
    {
        $nombre = trim((string) $nombre);
        if ($nombre === '') {
            return null;
        }
        return rtrim(config('app.url'), '/') . '/storage/img/marcas/' . basename($nombre);
    }

    /**
     * Comprueba la imagen y la guarda. Devuelve el nombre del fichero, o un
     * mensaje de error si no vale.
     *
     * SE COMPRUEBA QUE SEA UNA IMAGEN DE VERDAD, no que lo diga la extensión:
     * el nombre y el tipo que manda el navegador los escribe quien sube el
     * fichero. `getimagesize` lee la cabecera del fichero ya guardado en el
     * disco temporal, que es el único que no se puede falsear desde fuera.
     *
     * @return array{0: ?string, 1: ?string}  [nombre, error]
     */
    protected function guardarImagenEcommerce(UploadedFile $archivo): array
    {
        if (!$archivo->isValid()) {
            return [null, 'La imagen llegó incompleta: vuelve a intentarlo'];
        }

        $extension = strtolower($archivo->getClientOriginalExtension());
        if (!in_array($extension, $this->extensionesImagen(), true)) {
            return [null, 'Sólo se aceptan imágenes jpg, png, webp o gif'
                          . ' (el svg no, porque puede traer código dentro)'];
        }

        if ($archivo->getSize() > $this->pesoMaximoImagen()) {
            return [null, 'La imagen pesa ' . round($archivo->getSize() / 1048576, 1)
                          . ' MB y el máximo son 4 MB: guárdala más pequeña antes de subirla'];
        }

        if (@getimagesize($archivo->getRealPath()) === false) {
            return [null, 'El fichero no es una imagen'];
        }

        $nombre = Str::random(40) . '.' . $extension;
        $archivo->move(storage_path('app/' . $this->carpetaEcommerce()), $nombre);

        return [$nombre, null];
    }

    /**
     * Borra el fichero del disco.
     *
     * NO SE LLAMA AL QUITAR UNA FILA, sólo al vaciar la papelera: mientras la
     * fila se pueda restaurar, su imagen tiene que seguir ahí. Y quien llame
     * ya ha comprobado que ninguna otra fila use ese fichero.
     */
    protected function borrarImagenEcommerce(?string $nombre): void
    {
        $nombre = basename(trim((string) $nombre));
        if ($nombre === '' || $nombre === '.' || $nombre === '..') {
            return;
        }

        $ruta = storage_path('app/' . $this->carpetaEcommerce() . '/' . $nombre);
        if (is_file($ruta)) {
            @unlink($ruta);
        }
    }
}
