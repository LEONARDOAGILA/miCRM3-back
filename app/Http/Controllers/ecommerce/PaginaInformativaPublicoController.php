<?php

namespace App\Http\Controllers\ecommerce;

use Exception;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;

/**
 * Lo que la TIENDA lee de las páginas de texto. SIN TOKEN: esto lo pide un
 * visitante cualquiera desde el navegador, no un usuario del CRM.
 *
 * Va aparte del controlador de administración a propósito. No es sólo que no
 * lleve `auth:api`: devuelve otra cosa. Aquí no salen el estado, el orden, la
 * carpeta ni quién la tocó por última vez —nada de eso le importa a quien lee
 * los términos y condiciones—, y una página OCULTA no existe. Mezclarlo en el
 * mismo controlador acaba en un `if ($publico)` por método y en el descuido de
 * devolver de más por la puerta abierta.
 *
 *   GET ecommerce/publico/paginas/{clave}   una página
 *   GET ecommerce/publico/documentos        el índice de /documentos
 *
 * Las respuestas no se guardan en caché del navegador (`no-cache`): el texto
 * cambia poco, pero cuando cambia es porque legal lo pidió, y esperar a que
 * caduque una caché no es una respuesta aceptable.
 */
class PaginaInformativaPublicoController extends Controller
{
    use ApiResponder;
    use \App\Http\Controllers\Concerns\ArchivosDeLaTienda;

    /**
     * Una página por su clave.
     *
     * Si no existe o está oculta responde 404 y la tienda enseña su propio
     * aviso. Son el mismo caso a propósito: desde fuera no se tiene por qué
     * saber que la página existe pero está apagada.
     */
    public function pagina($clave)
    {
        try {
            $result = DB::selectOne(
                'SELECT ecommerce.fn_paginas_informativas_publica(?::TEXT) as result', [(string) $clave]);

            $data = $result && $result->result ? json_decode($result->result, true) : null;

            if (!$data) {
                return $this->errorResponse('Página no disponible', 404)
                            ->header('Cache-Control', 'no-cache');
            }

            $data['contenido'] = $this->contenidoParaLeer($data['contenido'] ?? []);

            return $this->successResponse($data, 'Página')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar la página informativa', ['clave' => $clave, 'error' => $e->getMessage()]);
            return $this->errorResponse('No se pudo cargar la página', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }

    /** El índice de /documentos: las carpetas con sus páginas visibles. */
    public function documentos()
    {
        try {
            $result = DB::selectOne('SELECT ecommerce.fn_paginas_informativas_listar_publicas() as result');
            $data = json_decode($result->result, true) ?: [];

            return $this->successResponse($data, 'Documentos')
                        ->header('Cache-Control', 'no-cache');

        } catch (Exception $e) {
            Log::error('No se pudo cargar el índice de documentos', ['error' => $e->getMessage()]);
            return $this->errorResponse('No se pudieron cargar los documentos', 500)
                        ->header('Cache-Control', 'no-store');
        }
    }

    /** El contenido con las direcciones de sus ficheros ya puestas. */
    private function contenidoParaLeer(array $c): array
    {
        $c['texto']  = $this->htmlParaLeer($c['texto'] ?? null);
        $c['imagen'] = $this->urlArchivo($c['imagen'] ?? null, 'imagenes');
        $c['pdf']    = $this->urlArchivo($c['pdf'] ?? null, 'documentos');
        $c['desplegables'] = array_map(function ($d) {
            $d['texto'] = $this->htmlParaLeer($d['texto'] ?? null);
            $d['pdf']   = $this->urlArchivo($d['pdf'] ?? null, 'documentos');
            return $d;
        }, $c['desplegables'] ?? []);

        return $c;
    }
}
