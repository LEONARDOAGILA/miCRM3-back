<!DOCTYPE html>
<html>

<head>
    <style>
        body {
            margin: 0;
            padding: 0;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background-image: url('/storage/assets/bg-login.png');
            background-size: cover;
        }

        .content {
            text-align: center;
            background-color: rgba(255, 255, 255, 0.7);
            padding: 20px;
            border-radius: 10px;
        }

        .logo img {
            position: absolute;
            top: 0;
            left: 0;
            padding: 20px;
            width: 20%;
        }

        .titulo {
            color: green;
            font-size: 50px;
            line-height: 1;
            text-shadow: 2px 2px 4px rgba(88, 212, 201, 0.2);
        }

        .info {
            color: red;
            font-size: 25px;
            line-height: 1.2;
            letter-spacing: 0.5px;
            padding: 5px;
            border-radius: 5px;
            margin-top: 20px;
        }

        .auto-style1 {
            text-align: right;
        }

        .auto-style2 {
            text-align: left;
        }
    </style>
</head>

<body>
    <div class="logo">
        <img src="/storage/assets/logoalmagex.png" alt="Logo Image">
    </div>

    <div class="content">
        <div class="titulo">AUTORIZACIÓN PARA EL TRATAMIENTO DE DATOS PERSONALES Y DE RIESGO CREDITICIO</div>
        <div>
            <p style="text-align: justify;">
                Autorizo y consiento de manera expresa, libre, inequívoca y voluntaria para que <strong>ALMESPANA CIA.
                    LTDA.</strong> obtenga y use información personal de carácter crediticio y de contacto,
                la cual me corresponda cuantas veces lo considere necesario; esto con el fin de <strong>analizar
                    indicadores de
                    riesgo crediticio</strong> que se generen en las relaciones comerciales que mantenga con la
                compañía.
            </p>
            <p style="text-align: justify;">
                Así también, autorizo a <strong>ALMESPANA CIA. LTDA.</strong> para utilizar mis datos de contacto, como:
                números
                de teléfono celular, convencional y correo electrónico, con el fin de enviarme todo tipo de información
                comercial y publicidad.
            </p>
            <p style="text-align: justify;">
                La presente autorización tiene sustento en la Ley Orgánica de Protección de Datos Personales aprobada
                por la
                Asamblea Nacional del Ecuador en fecha 11 de mayo de 2021; y en la Constitución de la República del
                Ecuador.
            </p>
            <p style="text-align: justify;">
                Se deja constancia de la existencia de una base de datos de <strong>ALMESPANA CIA. LTDA.</strong>, en la
                que
                reposará la información proporcionada por el titular. De la misma forma, por medio de esta autorización,
                se
                declara
                que <strong>ALMESPANA CIA. LTDA.</strong> posee las medidas de seguridad físicas y digitales necesarias
                para el
                tratamiento de los datos personales del titular, conforme lo determinado en la ley.
            </p>
            <br>
            <table style="width: 100%">
                <tr>
                    <td style="width: 111px"><strong>Fecha solicitud:</strong></td>
                    <td class="auto-style2">{{ $object->fecha_solicitud }}</td>
                </tr>
                <tr>
                    <td class="auto-style1" style="width: 111px"><strong>Agencia:</strong></td>
                    <td class="auto-style2">{{ $object->almacen }}</td>
                </tr>
                <tr>
                    <td class="auto-style1" style="width: 111px; height: 23px"><strong>
                            Agente</strong>:</td>
                    <td class="auto-style2" style="height: 23px">{{ $object->agente }}</td>
                </tr>
                <tr>
                    <td class="auto-style1" style="width: 111px"><strong>Cliente:</strong></td>
                    <td class="auto-style2">{{ $object->cliente }}</td>
                </tr>
                <tr>
                    <td class="auto-style1" style="width: 111px"><strong>Teléfono:</strong></td>
                    <td class="auto-style2">{{ $object->telefono }}</td>
                </tr>
                <tr>
                    <td class="auto-style1" style="width: 111px"><strong>Email:</strong></td>
                    <td class="auto-style2">{{ $object->email }}</td>
                </tr>
                <tr>
                    <td class="auto-style1" style="width: 111px"><strong>Identificación:</strong></td>
                    <td class="auto-style2">{{ $object->identificacion }}</td>
                </tr>
            </table>

            <hr />

            <strong>Para validar esta solicitud por favor haga click en el siguiente enlace.</strong>
            <a href="http://localhost:4222/validacion-auto-trata-datos/{{ $object->id }}">Aprobar autorización</a>

        </div>
    </div>
</body>

</html>
