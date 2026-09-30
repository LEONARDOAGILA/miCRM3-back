<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <title>Contraseña restablecida</title>
    <style type="text/css">
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: #f4f7fc;
            line-height: 1.6;
            padding: 20px;
        }
        
        .container {
            max-width: 600px;
            margin: 0 auto;
            background-color: #ffffff;
            border-radius: 12px;
            overflow: hidden;
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1);
        }
        
        .header {
            background: linear-gradient(135deg, #28a745 0%, #1e7e34 100%);
            padding: 30px;
            text-align: center;
        }
        
        .logo {
            max-width: 180px;
            margin: 0 auto;
        }
        
        .logo img {
            max-width: 100%;
            height: auto;
            background: white;
            padding: 10px 20px;
            border-radius: 10px;
        }
        
        .content {
            padding: 40px 30px;
        }
        
        .title {
            font-size: 24px;
            color: #28a745;
            text-align: center;
            margin-bottom: 20px;
            font-weight: 600;
        }
        
        .greeting {
            font-size: 18px;
            color: #333;
            margin-bottom: 25px;
            text-align: center;
        }
        
        .success-box {
            background: linear-gradient(135deg, #d4edda 0%, #c3e6cb 100%);
            border-left: 4px solid #28a745;
            padding: 20px;
            border-radius: 8px;
            margin: 25px 0;
            text-align: center;
        }
        
        .success-icon {
            font-size: 48px;
            color: #28a745;
            margin-bottom: 10px;
        }
        
        .success-text {
            font-size: 16px;
            color: #155724;
            font-weight: 500;
        }
        
        .message {
            color: #555;
            margin: 25px 0;
            text-align: center;
        }
        
        .info-box {
            background-color: #d1ecf1;
            border-left: 4px solid #17a2b8;
            padding: 15px 20px;
            border-radius: 8px;
            margin: 25px 0;
        }
        
        .info-text {
            color: #0c5460;
            font-size: 14px;
            text-align: center;
        }
        
        .footer {
            background-color: #f8f9fa;
            padding: 20px 30px;
            text-align: center;
            border-top: 1px solid #e9ecef;
        }
        
        .footer-text {
            color: #6c757d;
            font-size: 12px;
            margin: 5px 0;
        }
        
        .button {
            display: inline-block;
            background: linear-gradient(135deg, #28a745 0%, #1e7e34 100%);
            color: white;
            text-decoration: none;
            padding: 12px 30px;
            border-radius: 25px;
            font-weight: 600;
            margin: 15px 0;
            transition: all 0.3s ease;
        }
        
        .button:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 10px rgba(0,0,0,0.2);
        }
        
        @media (max-width: 480px) {
            .content {
                padding: 25px 20px;
            }
            
            .title {
                font-size: 20px;
            }
            
            .header {
                padding: 20px;
            }
        }
    </style>
</head>
<body>

    <div class="container">
        <!-- Cabecera con logo (color verde para éxito) -->
        <div class="header">
            <div class="logo">
                @php $rutaLogo = public_path('storage/img/mail/mail.png'); @endphp
                @if (file_exists($rutaLogo))
                    <img src="{{ $message->embed($rutaLogo) }}" alt="Logo">
                @endif
            </div>
        </div>

        <!-- Contenido principal -->
        <div class="content">
            <div class="success-icon">✓</div>
            <h1 class="title">¡Contraseña Actualizada!</h1>
            
            <div class="greeting">
                Estimado/a, <strong>{{ $object->name ?? $object->email }}</strong>
            </div>
            
            <div class="success-box">
                <div class="success-text">
                    🔒 Tu contraseña se restableció correctamente.
                    @isset($object->fecha)
                        <br><span style="font-size: 13px;">{{ $object->fecha }}</span>
                    @endisset
                </div>
            </div>
            
            <div class="message">
                <strong>Información importante:</strong>
                <ul style="margin-top: 10px; text-align: left; display: inline-block;">
                    <li>✓ Tu nueva contraseña ha sido registrada en el sistema</li>
                    <li>✓ Puedes iniciar sesión con tu nueva contraseña de inmediato</li>
                    <li>✓ Te recomendamos no compartir tu contraseña con nadie</li>
                </ul>
            </div>
            
            <div class="info-box">
                <div class="info-text">
                    🔐 <strong>¿No realizaste este cambio?</strong><br>
                    Si no solicitaste este cambio de contraseña, contacta inmediatamente al administrador del sistema.
                </div>
            </div>
            
            <div style="text-align: center;">
                <a href="{{ env('APP_URL') }}" class="button">Ir al Sistema</a>
            </div>
        </div>

        <!-- Pie de página -->
        <div class="footer">
            <div class="footer-text">
                <strong>miEmpresa Cía. Ltda.</strong>
            </div>
            <div class="footer-text">
                &copy; {{ date('Y') }} Todos los derechos reservados.
            </div>
            <div class="footer-text">
                Este mensaje es enviado automáticamente por el sistema de gestión.
            </div>
        </div>
    </div>

</body>
</html>