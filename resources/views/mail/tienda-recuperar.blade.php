<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Recupera tu contraseña</title>
</head>
{{--
    EL CÓDIGO PARA CAMBIAR LA CONTRASEÑA DE UNA CUENTA DE LA TIENDA.

    Dura poco a propósito (dos horas): es la llave de una cuenta, no una
    confirmación de correo.
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
                    Pediste cambiar la contraseña de tu cuenta. Usa este código:
                </p>
            </td>
        </tr>

        <tr>
            <td style="padding:0 28px 8px;">
                <p style="margin:0; text-align:center; font-size:30px; letter-spacing:8px; font-weight:bold; color:#0f766e;">
                    {{ $object->codigo }}
                </p>
                <p style="margin:14px 0 0; font-size:13px; color:#6b7280; text-align:center;">
                    Caduca en {{ $object->horas }} horas.
                </p>
            </td>
        </tr>

        <tr>
            <td style="padding:20px 28px 28px;">
                <p style="margin:0; font-size:13px; color:#6b7280; line-height:1.5;">
                    Si no lo pediste tú, no hagas nada: tu contraseña sigue siendo la de
                    siempre mientras nadie use este código.
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
