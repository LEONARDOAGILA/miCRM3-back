<?php

namespace App\Services;

/**
 * Parte un nombre completo ecuatoriano en APELLIDOS y NOMBRES.
 *
 * EL PROBLEMA. El Registro Civil devuelve un solo texto —«AGILA ASTUDILLO
 * LEONARDO PATRICIO»— sin decir dónde acaban los apellidos. Lo normal son dos
 * y dos, pero hay gente con un solo nombre («PEREZ GUAMAN GUILLERMO») y gente
 * con un solo apellido, así que PARTIR POR LA MITAD NO SIRVE.
 *
 * LO QUE SÍ SE PUEDE RESOLVER BIEN son las partículas: «DE», «DEL», «DE LOS»,
 * «SAN»… nunca van solas, se pegan a la palabra siguiente. Eso convierte
 * «PEREZ GUAMAN GUILLERMO DE JESUS» en cuatro trozos —Perez · Guaman ·
 * Guillermo · de Jesús— y entonces el dos y dos vuelve a valer. Lo mismo con
 * «DE LOS SANTOS MORALES …», donde los tres primeros son UN apellido.
 *
 * LO QUE NO SE PUEDE ADIVINAR se dice. Con tres trozos, «PEREZ GUAMAN
 * GUILLERMO» puede ser dos apellidos y un nombre (lo más común) o un apellido
 * y dos nombres, y no hay forma de saberlo desde el texto. En esos casos se
 * devuelve la lectura más probable y `seguro = false`, para que la pantalla
 * avise de que hay que mirarlo. Es mejor un corte dudoso señalado que uno
 * silencioso.
 */
final class NombrePersona
{
    /**
     * Palabras que no son un apellido ni un nombre por sí solas: se pegan a
     * la siguiente. Van sin tilde y en mayúsculas porque así se comparan.
     */
    private const PARTICULAS = [
        'DE', 'DEL', 'LA', 'LAS', 'LOS', 'Y',
        'DA', 'DAS', 'DO', 'DOS', 'DI', 'DELLA',
        'VAN', 'VON', 'DER', 'DEN', 'LE',
        'SAN', 'SANTA',
        'MC', 'MAC', 'ST',
    ];

    /**
     * Las que además van en MINÚSCULA cuando no abren el campo: «de los
     * Santos», «van der Merwe».
     *
     * «San» y «Santa» no están aquí a propósito: pegan como las demás, pero
     * son parte del apellido y se escriben con mayúscula —«Santa Cruz»—.
     */
    private const MINUSCULAS = [
        'DE', 'DEL', 'LA', 'LAS', 'LOS', 'Y',
        'DA', 'DAS', 'DO', 'DOS', 'DI', 'DELLA',
        'VAN', 'VON', 'DER', 'DEN', 'LE',
    ];

    /**
     * @return array{
     *   nombre_completo: string, apellidos: string, nombres: string,
     *   seguro: bool, aviso: ?string, partes: array<int, string>
     * }
     */
    public static function separar(?string $completo): array
    {
        $unidades = self::unidades((string) $completo);
        $cuantas  = count($unidades);

        $vacio = [
            'nombre_completo' => '',
            'apellidos'       => '',
            'nombres'         => '',
            'seguro'          => false,
            'aviso'           => 'No vino ningún nombre',
            'partes'          => [],
        ];
        if ($cuantas === 0) { return $vacio; }

        // Cuántas unidades son apellidos. En Ecuador son dos salvo cuando no
        // caben: con dos trozos, uno de cada; con uno, no hay nombre que dar.
        [$cuantosApellidos, $seguro, $aviso] = match (true) {
            $cuantas === 1 => [1, false, 'Vino una sola palabra: revisa si es apellido o nombre'],
            $cuantas === 2 => [1, true,  null],
            $cuantas === 3 => [2, false, 'Tres palabras: se leyó como dos apellidos y un nombre, revísalo'],
            $cuantas === 4 => [2, true,  null],
            default        => [2, false, 'Más de cuatro palabras: se tomaron las dos primeras como apellidos, revísalo'],
        };

        $apellidos = array_slice($unidades, 0, $cuantosApellidos);
        $nombres   = array_slice($unidades, $cuantosApellidos);

        return [
            'nombre_completo' => self::capitalizar(implode(' ', $unidades), true),
            'apellidos'       => self::capitalizar(implode(' ', $apellidos), true),
            'nombres'         => self::capitalizar(implode(' ', $nombres), true),
            'seguro'          => $seguro,
            'aviso'           => $aviso,
            // Los trozos ya pegados, por si la pantalla quiere ofrecer mover
            // el corte a mano
            'partes'          => array_map(fn ($u) => self::capitalizar($u, true), $unidades),
        ];
    }

    /**
     * Las palabras del nombre con las partículas ya pegadas a la siguiente.
     *
     * «DE LOS SANTOS MORALES» -> ['DE LOS SANTOS', 'MORALES']
     *
     * @return array<int, string>
     */
    public static function unidades(string $completo): array
    {
        $limpio = trim(preg_replace('/\s+/u', ' ', $completo) ?? '');
        if ($limpio === '') { return []; }

        $unidades = [];
        $pendiente = '';

        foreach (explode(' ', $limpio) as $palabra) {
            if (self::esParticula($palabra)) {
                // Una partícula nunca cierra una unidad: espera a la siguiente
                $pendiente = $pendiente === '' ? $palabra : $pendiente . ' ' . $palabra;
                continue;
            }
            $unidades[] = $pendiente === '' ? $palabra : $pendiente . ' ' . $palabra;
            $pendiente = '';
        }

        // Una partícula suelta al final no es nada por sí misma: se pega a lo
        // último que haya, y si no hay nada, se queda como está
        if ($pendiente !== '') {
            if ($unidades) { $unidades[count($unidades) - 1] .= ' ' . $pendiente; }
            else           { $unidades[] = $pendiente; }
        }

        return $unidades;
    }

    /**
     * «CHUEZ CEDEÑO ANGIE DARLEY» -> «Chuez Cedeño Angie Darley».
     *
     * El Registro Civil devuelve cosas como «Chuez CedeÑo»: se baja todo y se
     * vuelve a subir la primera letra de cada palabra. Las partículas se
     * quedan en minúscula —«de los Santos»— salvo que abran el campo, que es
     * como se escribe en castellano.
     */
    public static function capitalizar(string $texto, bool $particulasEnMinuscula = false): string
    {
        $limpio = trim(preg_replace('/\s+/u', ' ', $texto) ?? '');
        if ($limpio === '') { return ''; }

        $palabras = explode(' ', mb_strtolower($limpio, 'UTF-8'));
        foreach ($palabras as $i => $palabra) {
            $esParticula = $particulasEnMinuscula && $i > 0 && self::vaEnMinuscula($palabra);
            if (!$esParticula) {
                $palabras[$i] = mb_strtoupper(mb_substr($palabra, 0, 1, 'UTF-8'), 'UTF-8')
                              . mb_substr($palabra, 1, null, 'UTF-8');
            }
        }

        return implode(' ', $palabras);
    }

    private static function esParticula(string $palabra): bool
    {
        return in_array(self::sinTildes(mb_strtoupper($palabra, 'UTF-8')), self::PARTICULAS, true);
    }

    private static function vaEnMinuscula(string $palabra): bool
    {
        return in_array(self::sinTildes(mb_strtoupper($palabra, 'UTF-8')), self::MINUSCULAS, true);
    }

    /** Para comparar: «DÍ» y «DI» son la misma partícula. */
    private static function sinTildes(string $texto): string
    {
        return strtr($texto, [
            'Á' => 'A', 'É' => 'E', 'Í' => 'I', 'Ó' => 'O', 'Ú' => 'U', 'Ü' => 'U',
        ]);
    }
}
