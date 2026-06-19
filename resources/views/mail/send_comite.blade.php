<!DOCTYPE html
    PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">

<head>
    <meta content="es" http-equiv="Content-Language" />
    <meta content="text/html; charset=utf-8" http-equiv="Content-Type" />
    <title>Untitled 1</title>
    <style type="text/css">
        .auto-style1 {
            text-align: center;
            color: black;
        }

        #tablaProd {
            border: 1px solid black;
            border-collapse: collapse;
            width: 100%;
            color: black;
        }

        #tablaProd th {
            background-color: #dddddd;
            color: black;
        }
    </style>
</head>

<body>

    <table style="width: 100%">
        <tr>
            <td class="auto-style1"><b>Resumen Solicitud de Crédito</b></td>
        </tr>
    </table>
    <table style="width: 100%">
        <tr>
            <td><b>Almespana Cia. Ltda.</b></td>
        </tr>
    </table>
    <table style="width: 100%">
        <tr>
            <td style="width: 25%"><b>N° Caso:</b></td>
            <td style="width: 25%">{{ $object->caso->id }} </td>

            <td style="width: 25%"><b>Fecha:</b></td>
            <td style="width: 25%">{{ $object->data->cpp_fecha }} </td>
        </tr>

        <tr>
            <td style="width: 25%"><b>Cliente:</b></td>
            <td style="width: 25%">{{ $object->data->ent_nombre_comercial }} </td>

            <td style="width: 25%"><b>Cédula:</b></td>
            <td style="width: 25%">{{ $object->data->cli_codigo }}</td>
        </tr>

    </table>

    <table style="width: 100%">
        <tr>
            <td style="width: 12.5%"><b>Entrada:</b></td>
            <td style="width: 12.5%" colspan="2">{{ $object->data->cpp_entrada }}</td>

            <td style="width: 12.5%"><b>Entrada adicional:</b></td>
            <td style="width: 12.5%" colspan="2">{{ $object->data->cpp_entradaadicional }}</td>

            <td style="width: 12.5%"><b>Contraentrega:</b></td>
            <td style="width: 12.5%" colspan="2">{{ $object->data->cpp_contraentrega }}</td>
        </tr>
    </table>
    <table style="width: 100%">
        <tr>
            <td style="width: 12.5%"><b>Cuotas gratis:</b></td>
            <td style="width: 12.5%" colspan="2">{{ $object->data->cpp_cuotas_gratis }}</td>

            <td style="width: 12.5%"><b># Cuotas:</b></td>
            <td style="width: 12.5%" colspan="2">{{ $object->data->cpp_cuotas }}</td>

            <td style="width: 12.5%"><b>Valor cuota:</b></td>
            <td style="width: 12.5%" colspan="2">{{ $object->data->cpp_valor_cuota }}</td>
        </tr>
    </table>

    <br>

    <table id="tablaProd">
        <thead>
            <tr id="tablaProd">
                <th id="tablaProd" style="width: 10%;">Código</th>
                <th id="tablaProd" style="width: 60%">Descripción</th>
                <th id="tablaProd" style="width: 10%">Cantidad</th>
                <th id="tablaProd" style="width: 10%">PVP</th>
                <th id="tablaProd" style="width: 10%">Total</th>
            </tr>
        </thead>
        <tbody>
            @if (!is_null($object->data))
                @foreach ($object->data->dpedido_proforma as $p)
                    <tr id="tablaProd">
                        <td id="tablaProd" style="width: 10%;">{{ $p->pro_codigo }}</td>
                        <td id="tablaProd" style="width: 60%;">{{ $p->pro_nombre }}</td>
                        <td id="tablaProd" style="width: 10%;">{{ $p->dpp_cantidad }}</td>
                        <td id="tablaProd" style="width: 10%;">{{ $p->dpp_costoprecio }}</td>
                        <td id="tablaProd" style="width: 10%;">{{ $p->dpp_valortotal }}</td>
                    </tr>
                @endforeach
            @else
                <tr id="tablaProd">
                    <td colspan="5">No hay productos.</td>
                </tr>
            @endif

            <tr id="tablaProd">
                <td rowspan="4" colspan="3" style="width: 80%;"></td>
            </tr>

            <tr id="tablaProd">
                <th id="tablaProd" style="width: 10%;">subtotal</th>
                <td style="width: 10%;">{{ $object->data->sub_total_compra }}</td>
            </tr>

            <tr id="tablaProd">
                <th id="tablaProd" style="width: 10%">iva</th>
                <td style="width: 10%">12%</td>
            </tr>

            <tr id="tablaProd">
                <th id="tablaProd" style="width: 10%">total</th>
                <td style="width: 10%">{{ $object->data->total_compra }}</td>
            </tr>
        </tbody>
    </table>

    <br />

    Está seguro que desea aprobar este crédito que fue rechazado por el departamento de fábrica de crédito.

    <p>Si su respuesta es <b>SI</b>, dar click en el siguiente link:</p>

    <a href="{{ $object->linkAprobar }}"> Click si su respuesta es SI</a>

    <br />

    <p>Si su respuesta es <b>NO</b>, dar click en el siguiente link:</p>

    <a href="{{ $object->linkRechazar }}"> Click si su respuesta es NO</a>

    <h5 class="auto-style1">Has recibido este correo electrónico porque han solicitado un crédito en Almespana Cia.
        Ltda.</h5>
    <h5 class="auto-style1">Por favor, no responda a este mensaje.</h5>

</body>

</html>
