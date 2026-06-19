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
    </style>
</head>

<body>
    <table style="width: 100%">
        <tr>
            <td>
                <h3>Almespana Cia. Ltda.</h3>
            </td>
        </tr>
    </table>

    {!! $object->cuerpo ?? '' !!}

    <h5 class="auto-style1">{{ $object->firma ?? '' }}</h5>
    <h5 class="auto-style1">{{ $object->cuerpo2 ?? '' }}</h5>
    <h5 class="auto-style1">{{ $object->cuerpo3 ?? '' }}</h5>

</body>

</html>
