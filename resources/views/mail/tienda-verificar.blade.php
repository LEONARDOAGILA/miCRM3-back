<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Confirma tu correo</title>
</head>
{{--
    EL CORREO DE CONFIRMACIÓN DE UNA CUENTA DE LA TIENDA.

    SIN LOGO EMBEBIDO, al revés que los correos del CRM: aquéllos incrustan un
    fichero del servidor y si ese fichero se mueve, el correo sale roto. Aquí
    manda el texto.

    LLEVA EL CÓDIGO Y EL ENLACE: el enlace es lo cómodo, y el código es lo que
    sirve cuando el cliente abre el correo en el teléfono y compra en el
    computador. Los dos valen y los dos caducan a la vez.

    Los estilos van EN LÍNEA porque los clientes de correo se comen casi todo
    lo que vaya en un <style>.
--}}
<body style="margin:0; padding:24px; background-color:#f4f5f7; font-family:Arial, Helvetica, sans-serif; color:#1d1d1f;">

    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px; margin:0 auto; background-color:#ffffff; border-radius:12px; overflow:hidden;">

        <tr>
            <td style="background-color:#0f766e; padding:24px; text-align:center;">
                <h1 style="margin:0; color:#ffffff; font-size:20px;">{{ $object->tienda }}</h1>
            </td>
        </tr>

        <tr>
            <td style="padding:28px 28px 8px;">
                <p style="margin:0 0 12px; font-size:16px;">Hola, <strong>{{ $object->nombre }}</strong>:</p>
                <p style="margin:0 0 20px; font-size:15px; line-height:1.5;">
                    Gracias por crear tu cuenta. Sólo falta confirmar que este correo es tuyo
                    para que puedas terminar tus pedidos.
                </p>
            </td>
        </tr>

        <tr>
            <td style="padding:0 28px 8px; text-align:center;">
                <a href="{{ $object->enlace }}"
                   style="display:inline-block; padding:14px 28px; background-color:#0f766e; color:#ffffff; text-decoration:none; border-radius:999px; font-weight:bold; font-size:15px;">
                    Confirmar mi correo
                </a>
            </td>
        </tr>

        <tr>
            <td style="padding:20px 28px;">
                <p style="margin:0 0 8px; font-size:14px; color:#6b7280; text-align:center;">
                    O escribe este código en la tienda:
                </p>
                <p style="margin:0; text-align:center; font-size:30px; letter-spacing:8px; font-weight:bold; color:#0f766e;">
                    {{ $object->codigo }}
                </p>
                <p style="margin:14px 0 0; font-size:13px; color:#6b7280; text-align:center;">
                    Caduca en {{ $object->horas }} horas.
                </p>
            </td>
        </tr>

        <tr>
            <td style="padding:0 28px 28px;">
                <p style="margin:0; font-size:13px; color:#6b7280; line-height:1.5;">
                    Si no fuiste tú quien creó esta cuenta, no hagas nada: sin confirmar el
                    correo no se puede comprar con ella.
                </p>
            </td>
        </tr>

        <tr>
            <td style="background-color:#f4f5f7; padding:16px; text-align:center;">
                <p style="margin:0; font-size:12px; color:#6b7280;">
                    &copy; {{ date('Y') }} {{ $object->tienda }}
                </p>
            </td>
        </tr>

    </table>

</body>
</html>
