<?php

namespace App\Services;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Throwable;

/**
 * Los datos de un RUC, consultados al SRI.
 *
 * ES EL HERMANO DE [[RegistroCivilService]], y la diferencia está en la
 * fuente: aquélla rasca una página de terceros que tarda diez segundos;
 * ésta llama al SERVICIO del propio SRI —el mismo que usa su página de
 * «Consulta de RUC»— y contesta en una décima de segundo con JSON limpio.
 *
 * DEVUELVE MÁS QUE EL NOMBRE. La razón social es lo que va a la ficha, pero
 * de paso vienen el estado del contribuyente (ACTIVO, SUSPENDIDO, PASIVO),
 * si es contribuyente fantasma y el régimen. Eso se pasa a la pantalla
 * porque a quien está creando un cliente le importa saber que está a punto
 * de facturarle a un RUC suspendido.
 *
 * SIGUE SIENDO UNA AYUDA: si el SRI no contesta, se dice y la ficha se
 * escribe a mano.
 */
class SriService
{
    /** El mismo servicio que consume la página de consulta de RUC del SRI. */
    private const URL = 'https://srienlinea.sri.gob.ec/sri-catastro-sujeto-servicio-internet/rest/ConsolidadoContribuyente/obtenerPorNumerosRuc?=&ruc=';

    /** Contesta en ~100 ms; con 10 segundos se cubre un mal día. */
    private const SEGUNDOS_ESPERA = 10;

    /**
     * Un día, no un mes como las cédulas: el nombre de una persona no cambia,
     * pero el estado de un RUC sí —hoy activo, mañana suspendido—.
     */
    private const HORAS_CACHE_ENCONTRADO = 24;
    private const MINUTOS_CACHE_VACIO    = 30;

    /**
     * @return array{success: bool, error_code?: string, message?: string, data?: array<string, mixed>}
     */
    public function consultarRuc(string $identificacion): array
    {
        $ruc = preg_replace('/\D/', '', $identificacion) ?? '';

        if (!$this->rucValido($ruc)) {
            return $this->error('IDENTIFICACION_INVALIDA', 'El RUC no es válido');
        }

        $clave = 'sri:ruc:' . $ruc;
        $cacheado = Cache::get($clave);
        if (is_array($cacheado)) {
            return ($cacheado['success'] ?? false)
                ? $this->exito($cacheado['fila'], 'caché')
                : $this->error('NO_ENCONTRADO', 'El SRI no tiene ningún contribuyente con ese RUC');
        }

        try {
            $respuesta = Http::timeout(self::SEGUNDOS_ESPERA)
                ->connectTimeout(5)
                ->withHeaders([
                    'Accept'     => 'application/json',
                    'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
                ])
                ->get(self::URL . $ruc);

            // Un RUC que no existe se contesta con 204 y el cuerpo vacío
            if ($respuesta->status() === 204 || trim($respuesta->body()) === '') {
                Cache::put($clave, ['success' => false], now()->addMinutes(self::MINUTOS_CACHE_VACIO));
                return $this->error('NO_ENCONTRADO', 'El SRI no tiene ningún contribuyente con ese RUC');
            }

            if (!$respuesta->successful()) {
                return $this->error('SERVICIO_NO_DISPONIBLE',
                    'El servicio del SRI no contestó bien (' . $respuesta->status() . ')');
            }

            $json = $respuesta->json();

        } catch (Throwable $e) {
            sistemaLog('warning', 'Consulta de RUC no disponible',
                       ['ruc' => $ruc, 'message' => $e->getMessage()]);
            return $this->error('SERVICIO_NO_DISPONIBLE', 'No se pudo consultar el SRI ahora mismo');
        }

        $fila = is_array($json) ? ($json[0] ?? null) : null;
        if (!is_array($fila) || empty($fila['razonSocial'])) {
            Cache::put($clave, ['success' => false], now()->addMinutes(self::MINUTOS_CACHE_VACIO));
            return $this->error('NO_ENCONTRADO', 'El SRI no tiene ningún contribuyente con ese RUC');
        }

        Cache::put($clave, ['success' => true, 'fila' => $fila], now()->addHours(self::HORAS_CACHE_ENCONTRADO));

        return $this->exito($fila, 'sri');
    }

    /**
     * El RUC, por su forma: trece dígitos, provincia, tipo y establecimiento.
     *
     * NO se exige el dígito verificador, por lo mismo que no lo exige el
     * validador del front: el SRI emitió miles de RUC que no lo cumplen (ver
     * la nota en validacionCedulaRucService). Si el número está mal, el
     * propio SRI contesta que no existe, que es la respuesta de verdad.
     */
    public function rucValido(string $ruc): bool
    {
        if (!preg_match('/^\d{13}$/', $ruc)) { return false; }

        // Los diez primeros todos iguales no es un RUC de nadie
        if (preg_match('/^(\d)\1{9}/', $ruc)) { return false; }

        $provincia = (int) substr($ruc, 0, 2);
        if ($provincia < 1 || ($provincia > 24 && $provincia !== 30)) { return false; }

        $tercero = (int) $ruc[2];
        if ($tercero > 6 && $tercero !== 9) { return false; }

        // Los tres últimos son el establecimiento: 001 o mayor
        return (int) substr($ruc, 10, 3) >= 1;
    }

    /** Lo que de verdad le hace falta a la pantalla, con nombres de aquí. */
    private function exito(array $f, string $fuente): array
    {
        $fechas = $f['informacionFechasContribuyente'] ?? [];
        $estado = strtoupper(trim((string) ($f['estadoContribuyenteRuc'] ?? '')));
        $razon  = trim(preg_replace('/\s+/u', ' ', (string) ($f['razonSocial'] ?? '')) ?? '');

        // De una persona natural, la «razón social» son sus apellidos y
        // nombres de una pieza: se parten para la ficha, que los pide por
        // separado. De una sociedad no hay nada que partir.
        $esPersona = str_contains(mb_strtoupper((string) ($f['tipoContribuyente'] ?? ''), 'UTF-8'), 'NATURAL');
        $nombre = $esPersona ? NombrePersona::separar($razon) : null;

        return [
            'success' => true,
            'data' => [
                'ruc'                  => (string) ($f['numeroRuc'] ?? ''),
                /**
                 * TAL CUAL LA MANDA EL SRI, en mayúsculas.
                 *
                 * No se le dan mayúsculas y minúsculas como a los nombres de
                 * personas: «CONSORCIO … S.A. CONECEL» acabaría en «S.a.», y
                 * además la razón social se imprime como consta en el RUC.
                 */
                'razon_social'         => $razon,

                /* ---- SÓLO EN PERSONAS NATURALES ----
                   Para la ficha de un cliente que no es empresa: ahí no hay
                   razón social que rellenar, hay apellidos y nombres. */
                'apellidos'      => $nombre['apellidos'] ?? null,
                'nombres'        => $nombre['nombres'] ?? null,
                /** false cuando el corte entre apellidos y nombres es dudoso */
                'nombre_seguro'  => $nombre['seguro'] ?? null,
                'nombre_aviso'   => $nombre['aviso'] ?? null,
                'estado'               => $estado,
                /** ACTIVO es el único con el que se factura con tranquilidad */
                'activo'               => $estado === 'ACTIVO',
                'motivo_suspension'    => $f['motivoCancelacionSuspension'] ?? null,
                'tipo_contribuyente'   => $f['tipoContribuyente'] ?? null,
                'regimen'              => $f['regimen'] ?? null,
                'categoria'            => $f['categoria'] ?? null,
                'actividad'            => $f['actividadEconomicaPrincipal'] ?? null,
                'obligado_contabilidad' => ($f['obligadoLlevarContabilidad'] ?? '') === 'SI',
                'agente_retencion'      => ($f['agenteRetencion'] ?? '') === 'SI',
                'contribuyente_especial' => ($f['contribuyenteEspecial'] ?? '') === 'SI',
                /** Dos banderas del SRI que conviene ver ANTES de facturarle a alguien */
                'fantasma'             => ($f['contribuyenteFantasma'] ?? '') === 'SI',
                'transacciones_inexistentes' => ($f['transaccionesInexistente'] ?? '') === 'SI',
                'fecha_inicio'         => $this->soloFecha($fechas['fechaInicioActividades'] ?? null),
                'fecha_cese'           => $this->soloFecha($fechas['fechaCese'] ?? null),
                'fecha_actualizacion'  => $this->soloFecha($fechas['fechaActualizacion'] ?? null),
                /* El primero, suelto: es el que firma, y así la ficha pinta
                   igual lo que acaba de llegar y lo que ya estaba guardado */
                'representante_identificacion' => $this->primerRepresentante($f, 'identificacion'),
                'representante_nombre'         => $this->primerRepresentante($f, 'nombre'),
                'representantes'       => array_map(
                    fn ($r) => [
                        'identificacion' => $r['identificacion'] ?? null,
                        'nombre'         => NombrePersona::capitalizar((string) ($r['nombre'] ?? '')),
                    ],
                    is_array($f['representantesLegales'] ?? null) ? $f['representantesLegales'] : []
                ),
                'fuente'               => $fuente,
            ],
        ];
    }

    /** El primer representante legal, que es el que firma por la empresa. */
    private function primerRepresentante(array $f, string $campo): ?string
    {
        $lista = $f['representantesLegales'] ?? null;
        $uno = is_array($lista) ? ($lista[0] ?? null) : null;
        if (!is_array($uno)) { return null; }

        $valor = trim((string) ($uno[$campo] ?? ''));
        if ($valor === '') { return null; }

        return $campo === 'nombre' ? NombrePersona::capitalizar($valor) : $valor;
    }

    /** «2003-12-29 00:00:00.0» -> «2003-12-29»; lo vacío, nulo. */
    private function soloFecha(?string $fecha): ?string
    {
        $limpia = trim((string) $fecha);
        return $limpia === '' ? null : substr($limpia, 0, 10);
    }

    private function error(string $codigo, string $mensaje): array
    {
        return ['success' => false, 'error_code' => $codigo, 'message' => $mensaje];
    }
}
