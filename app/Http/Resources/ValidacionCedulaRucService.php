<?php

namespace App\Http\Resources;

class ValidacionCedulaRucService
{
    const CEDULA = 1;
    const RUC_PERSONA_NATURAL = 2;
    const RUC_SOCIEDAD_PRIVADA = 3;
    const RUC_SOCIEDAD_PUBLICA = 4;

    public static function esIdentificacionValida($identificacion)
    {
        if (self::isNullOrEmpty($identificacion)) {
            return false;
        } else {
            $longitud = strlen($identificacion);
            self::esNumeroIdentificacionValida($identificacion, $longitud);

            if ($longitud === 10) {
                return self::esCedulaValida($identificacion);
            } else if ($longitud === 13) {
                $tercerDigito = (int) substr($identificacion, 2, 1);

                if ($tercerDigito >= 0 && $tercerDigito <= 5) {
                    return self::esRucPersonaNaturalValido($identificacion);
                } else if ($tercerDigito === 6) {
                    return self::esRucSociedadPublicaValido($identificacion);
                } else if ($tercerDigito === 9) {
                    return self::esRucSociedadPrivadaValido($identificacion);
                } else {
                    return false;
                }
            } else {
                return false;
            }
        }
    }

    public static function esCedulaValida($numeroCedula)
    {
        $esIdentificacionValida = self::validacionesPrevias($numeroCedula, 10, self::CEDULA);

        if ($esIdentificacionValida) {
            $ultimoDigito = (int) substr($numeroCedula, 9, 1);
            return self::algoritmoVerificaIdentificacion($numeroCedula, $ultimoDigito, self::CEDULA);
        } else {
            return false;
        }
    }

    public static function esRucValido($numeroRuc)
    {
        return (
            self::esRucPersonaNaturalValido($numeroRuc) ||
            self::esRucSociedadPrivadaValido($numeroRuc) ||
            self::esRucSociedadPublicaValido($numeroRuc)
        );
    }

    public static function esRucPersonaNaturalValido($numeroRuc)
    {
        $esIdentificacionValida = self::validacionesPrevias($numeroRuc, 13, self::RUC_PERSONA_NATURAL);

        if ($esIdentificacionValida) {
            $ultimoDigito = (int) substr($numeroRuc, 9, 1);
            return self::algoritmoVerificaIdentificacion($numeroRuc, $ultimoDigito, self::RUC_PERSONA_NATURAL);
        } else {
            return false;
        }
    }

    public static function esRucSociedadPrivadaValido($numeroRuc)
    {
        $esIdentificacionValida = self::validacionesPrevias($numeroRuc, 13, self::RUC_SOCIEDAD_PRIVADA);
        if ($esIdentificacionValida) {
            $ultimoDigito = (int) substr($numeroRuc, 9, 1);
            return self::algoritmoVerificaIdentificacion($numeroRuc, $ultimoDigito, self::RUC_SOCIEDAD_PRIVADA);
        } else {
            return false;
        }
    }

    public static function esRucSociedadPublicaValido($numeroRuc)
    {
        $esIdentificacionValida = self::validacionesPrevias($numeroRuc, 13, self::RUC_SOCIEDAD_PUBLICA);
        if ($esIdentificacionValida) {
            $ultimoDigito = (int) substr($numeroRuc, 8, 1);
            return self::algoritmoVerificaIdentificacion($numeroRuc, $ultimoDigito, self::RUC_SOCIEDAD_PUBLICA);
        } else {
            return false;
        }
    }

    public static function isNullOrEmpty($contenido)
    {
        return $contenido === null || $contenido === '';
    }

    public static function validacionesPrevias($identificacion, $longitud, $tipoIdentificacion)
    {
        if ($tipoIdentificacion === self::CEDULA) {
            return (
                self::esNumeroIdentificacionValida($identificacion, $longitud) &&
                self::esCodigoProvinciaValido($identificacion) &&
                self::esTercerDigitoValido($identificacion, $tipoIdentificacion)
            );
        } else {
            return (
                self::esNumeroIdentificacionValida($identificacion, $longitud) &&
                self::esCodigoProvinciaValido($identificacion) &&
                self::esTercerDigitoValido($identificacion, $tipoIdentificacion) &&
                self::esCodigoEstablecimientoValido($identificacion)
            );
        }
    }

    public static function esNumeroIdentificacionValida($numeroIdentificacion, $longitud)
    {
        return strlen($numeroIdentificacion) === $longitud && ctype_digit($numeroIdentificacion);
    }

    public static function esCodigoProvinciaValido($numeroCedula)
    {
        $numeroProvincia = (int) substr($numeroCedula, 0, 2);
        return $numeroProvincia > 0 && $numeroProvincia <= 24;
    }

    public static function esCodigoEstablecimientoValido($numeroRuc)
    {
        $ultimosTresDigitos = (int) substr($numeroRuc, 10, 3);
        return $ultimosTresDigitos >= 1;
    }

    public static function esTercerDigitoValido($numeroCedula, $tipoIdentificacion)
    {
        $tercerDigito = (int) substr($numeroCedula, 2, 1);

        if ($tipoIdentificacion === self::CEDULA) {
            return self::esTercerDigitoCedulaValido($tercerDigito);
        }

        if ($tipoIdentificacion === self::RUC_PERSONA_NATURAL) {
            return self::verificarTercerDigitoRucNatural($tercerDigito);
        }

        if ($tipoIdentificacion === self::RUC_SOCIEDAD_PUBLICA) {
            return self::verificarTercerDigitoRucPublica($tercerDigito);
        }

        if ($tipoIdentificacion === self::RUC_SOCIEDAD_PRIVADA) {
            return self::verificarTercerDigitoRucPrivada($tercerDigito);
        }

        return false;
    }

    public static function esTercerDigitoCedulaValido($tercerDigito)
    {
        return !is_nan($tercerDigito) && !($tercerDigito < 0 || $tercerDigito > 5);
    }

    public static function verificarTercerDigitoRucNatural($tercerDigito)
    {
        return $tercerDigito >= 0 && $tercerDigito <= 5;
    }

    public static function verificarTercerDigitoRucPrivada($tercerDigito)
    {
        return $tercerDigito === 9;
    }

    public static function verificarTercerDigitoRucPublica($tercerDigito)
    {
        return $tercerDigito === 6;
    }

    public static function algoritmoVerificaIdentificacion($numeroIdentificacion, $ultimoDigito, $tipoIdentificacion)
    {
        $sumatoria = self::sumarDigitosIdentificacion($numeroIdentificacion, $tipoIdentificacion);

        $digitoVerificador = self::obtenerDigitoVerificador($sumatoria, $tipoIdentificacion);

        return $ultimoDigito === $digitoVerificador;
    }

    public static function sumarDigitosIdentificacion($numeroIdentificacion, $tipoIdentificacion)
    {
        $coeficientes = self::obtenerCoeficientes($tipoIdentificacion);
        $identificacion = str_split($numeroIdentificacion);

        $sumatoriaCocienteIdentificacion = 0;

        foreach ($coeficientes as $posicion => $coeficiente) {
            $resultado = (int) $identificacion[$posicion] * $coeficiente;

            $sumatoria = self::sumatoriaMultiplicacion($resultado, $tipoIdentificacion);

            $sumatoriaCocienteIdentificacion += $sumatoria;
        }

        return $sumatoriaCocienteIdentificacion;
    }

    public static function sumatoriaMultiplicacion($multiplicacionValores, $tipoIdentificacion)
    {
        if ($tipoIdentificacion === self::CEDULA) {
            return $multiplicacionValores >= 10 ? $multiplicacionValores - 9 : $multiplicacionValores;
        } else if ($tipoIdentificacion === self::RUC_PERSONA_NATURAL) {
            $identificacion = str_split((string) $multiplicacionValores);
            $sumatoria = 0;

            foreach ($identificacion as $digito) {
                $sumatoria += (int) $digito;
            }

            return $sumatoria;
        } else {
            return $multiplicacionValores;
        }
    }

    public static function obtenerCoeficientes($tipoIdentificacion)
    {
        if (
            $tipoIdentificacion === self::CEDULA ||
            $tipoIdentificacion === self::RUC_PERSONA_NATURAL
        ) {
            return [2, 1, 2, 1, 2, 1, 2, 1, 2];
        } else if ($tipoIdentificacion === self::RUC_SOCIEDAD_PRIVADA) {
            return [4, 3, 2, 7, 6, 5, 4, 3, 2];
        } else if ($tipoIdentificacion === self::RUC_SOCIEDAD_PUBLICA) {
            return [3, 2, 7, 6, 5, 4, 3, 2];
        } else {
            return null;
        }
    }

    public static function obtenerDigitoVerificador($sumatoria, $tipoIdentificacion)
    {
        $residuo = 0;

        if (
            $tipoIdentificacion === self::CEDULA ||
            $tipoIdentificacion === self::RUC_PERSONA_NATURAL
        ) {
            $residuo = $sumatoria % 10;
            return $residuo === 0 ? 0 : 10 - $residuo;
        } else if (
            $tipoIdentificacion === self::RUC_SOCIEDAD_PUBLICA ||
            $tipoIdentificacion === self::RUC_SOCIEDAD_PRIVADA
        ) {
            $residuo = $sumatoria % 11;
            return $residuo === 0 ? 0 : 11 - $residuo;
        } else {
            return null;
        }
    }
}
