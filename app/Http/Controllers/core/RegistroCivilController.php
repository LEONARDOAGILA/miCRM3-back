<?php

namespace App\Http\Controllers\core;

use Exception;
use Illuminate\Http\Request;
use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use App\Services\RegistroCivilService;
use App\Services\SriService;

/**
 * Los nombres de una cédula, para no teclearlos a mano.
 *
 * Está en `config` porque no es de ventas: lo usa la ficha del cliente, pero
 * sirve igual para la del empleado o la de un proveedor. La lógica vive en
 * App\Services\RegistroCivilService; aquí sólo se traduce a HTTP.
 *
 * SIEMPRE CONTESTA 200, también cuando no encuentra la cédula o cuando la
 * página de terceros se cae. No es un descuido: el interceptor del front
 * saca un toast rojo ante CUALQUIER error HTTP, y esto es una ayuda
 * opcional —que una cédula no exista o que la fuente esté caída no es una
 * avería del CRM—. Lo que pasó va dentro, en `encontrado` y `motivo`, y la
 * pantalla decide qué decir y sigue dejando escribir a mano.
 *
 * Un 500 sí es un 500: ahí sí hay algo roto en casa.
 *
 *   GET config/registroCivil/consultarCedula/{identificacion}   personas (Registro Civil)
 *   GET config/registroCivil/consultarRuc/{ruc}                empresas y RUC (SRI)
 */
class RegistroCivilController extends Controller
{
    use ApiResponder;

    public function __construct(
        private readonly RegistroCivilService $registroCivil,
        private readonly SriService $sri,
    ) {
        $this->middleware('auth:api');
    }

    public function consultarCedula(Request $request, string $identificacion)
    {
        try {
            $r = $this->registroCivil->consultar($identificacion);

            if ($r['success'] ?? false) {
                return $this->successResponse(
                    ['encontrado' => true, 'motivo' => null, 'mensaje' => null] + $r['data'],
                    'La solicitud ha tenido éxito'
                );
            }

            return $this->successResponse([
                'encontrado'     => false,
                'motivo'         => $r['error_code'] ?? 'DESCONOCIDO',
                'mensaje'        => $r['message'] ?? 'No se pudo consultar',
                'identificacion' => $identificacion,
            ], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en consultarCedula',
                       ['message' => $e->getMessage(), 'line' => $e->getLine(), 'cedula' => $identificacion]);
            return $this->errorResponse('Ocurrió un error al consultar la cédula', 500);
        }
    }

    /**
     * La razón social y el estado de un RUC, del SRI.
     *
     * Es lo que la ficha necesita cuando el cliente es una EMPRESA: ahí no
     * hay cédula que consultar, y el Registro Civil no tiene razones
     * sociales. Vale igual para el RUC de una persona natural, que en el SRI
     * sale con sus apellidos y nombres como razón social.
     *
     * Mismo trato que la consulta de cédulas: siempre 200 y lo que pasó va
     * dentro.
     */
    public function consultarRuc(Request $request, string $ruc)
    {
        try {
            $r = $this->sri->consultarRuc($ruc);

            if ($r['success'] ?? false) {
                return $this->successResponse(
                    ['encontrado' => true, 'motivo' => null, 'mensaje' => null] + $r['data'],
                    'La solicitud ha tenido éxito'
                );
            }

            // EL SRI SE CAYÓ: se intenta el Registro Civil, que al menos da el
            // nombre. Sólo cuando el SRI no contestó —si dijo que ese RUC no
            // existe, no hay nada que reintentar en otro sitio—.
            if (($r['error_code'] ?? '') === 'SERVICIO_NO_DISPONIBLE') {
                $respaldo = $this->respaldoRegistroCivil($ruc);
                if ($respaldo !== null) { return $this->successResponse($respaldo, 'La solicitud ha tenido éxito'); }
            }

            return $this->successResponse([
                'encontrado' => false,
                'motivo'     => $r['error_code'] ?? 'DESCONOCIDO',
                'mensaje'    => $r['message'] ?? 'No se pudo consultar',
                'ruc'        => $ruc,
            ], 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en consultarRuc',
                       ['message' => $e->getMessage(), 'line' => $e->getLine(), 'ruc' => $ruc]);
            return $this->errorResponse('Ocurrió un error al consultar el RUC', 500);
        }
    }

    /**
     * El plan B del RUC: el nombre, desde el Registro Civil.
     *
     * Un RUC de persona natural es su cédula más «001», así que con los diez
     * primeros se puede preguntar por el titular. De una sociedad —tercer
     * dígito 9— no: esos diez dígitos no son la cédula de nadie, y ahí no hay
     * respaldo que valga.
     *
     * Lo que sale de aquí va MARCADO como degradado: trae el nombre y nada
     * más, no el estado ni el régimen, y la pantalla no debe guardarlo como
     * si fueran datos del SRI.
     *
     * @return array<string, mixed>|null null cuando tampoco por aquí se puede
     */
    private function respaldoRegistroCivil(string $ruc): ?array
    {
        $digitos = preg_replace('/\D/', '', $ruc) ?? '';
        if (strlen($digitos) !== 13 || in_array($digitos[2] ?? '', ['6', '9'], true)) {
            return null;       // sociedad: el Registro Civil no sabe de ellas
        }

        $rc = $this->registroCivil->consultar(substr($digitos, 0, 10));
        if (!($rc['success'] ?? false)) { return null; }

        $d = $rc['data'];

        return [
            'encontrado' => true,
            'motivo'     => null,
            'mensaje'    => 'El SRI no contestó: el nombre viene del Registro Civil, sin los datos tributarios',
            /** Lo que se pudo traer por el camino largo, y nada más */
            'degradado'  => true,
            'ruc'        => $digitos,
            'razon_social' => mb_strtoupper($d['nombre_completo'], 'UTF-8'),
            /* El Registro Civil sí sabe partir el nombre: eso se aprovecha */
            'apellidos'     => $d['apellidos'],
            'nombres'       => $d['nombres'],
            'nombre_seguro' => $d['seguro'],
            'nombre_aviso'  => $d['aviso'],
            'estado'     => null,
            'activo'     => null,
            'motivo_suspension' => null,
            'tipo_contribuyente' => null,
            'regimen'    => null,
            'categoria'  => null,
            'actividad'  => null,
            'obligado_contabilidad'  => false,
            'agente_retencion'       => false,
            'contribuyente_especial' => false,
            'fantasma'   => false,
            'transacciones_inexistentes' => false,
            'fecha_inicio' => null,
            'fecha_cese'   => null,
            'fecha_actualizacion' => null,
            'representante_identificacion' => null,
            'representante_nombre' => null,
            'representantes' => [],
            'fuente'     => 'registro-civil',
        ];
    }
}
