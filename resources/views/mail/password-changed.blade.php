<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <title>Cambio de Contraseña</title>
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
            background: linear-gradient(135deg, #1a73e8 0%, #0d47a1 100%);
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
            color: #1a73e8;
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
        
        .password-box {
            background: linear-gradient(135deg, #fff9e6 0%, #fff3cd 100%);
            border-left: 4px solid #ffc107;
            padding: 20px;
            border-radius: 8px;
            margin: 25px 0;
            text-align: center;
        }
        
        .password-label {
            font-size: 14px;
            color: #856404;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 10px;
        }
        
        .password-value {
            font-size: 28px;
            font-weight: bold;
            color: #d9534f;
            font-family: monospace;
            letter-spacing: 2px;
            background: #fff;
            display: inline-block;
            padding: 10px 20px;
            border-radius: 8px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        
        .message {
            color: #555;
            margin: 25px 0;
            text-align: center;
        }
        
        .warning-box {
            background-color: #f8d7da;
            border-left: 4px solid #dc3545;
            padding: 15px 20px;
            border-radius: 8px;
            margin: 25px 0;
        }
        
        .warning-text {
            color: #721c24;
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
            background: linear-gradient(135deg, #1a73e8 0%, #0d47a1 100%);
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
            
            .password-value {
                font-size: 20px;
                padding: 8px 15px;
            }
            
            .header {
                padding: 20px;
            }
        }
    </style>
</head>
<body>

    <div class="container">
        <!-- Cabecera con logo -->
        <div class="header">
            <div class="logo">
                <img src="{{ $message->embed(public_path('storage/img/mail/mail.png')) }}" alt="Logo">
                
            </div>
        </div>

        <!-- Contenido principal -->
        <div class="content">
            <h1 class="title">Cambio de Contraseña</h1>
            
            <div class="greeting">
                Estimado/a, <strong>{{ $object->email }}</strong>
            </div>
            
            <div class="message">
                Has solicitado recientemente cambiar tu contraseña en <strong>miEMPRESA Cía. Ltda.</strong>
            </div>
            
            <!-- Recuadro con la nueva contraseña -->
            <div class="password-box">
                <div class="password-label">🔐 Tu nueva contraseña temporal es:</div>
                <div class="password-value">{{ $object->password }}</div>
                <div style="font-size: 12px; color: #856404; margin-top: 10px;">
                    ⚠️ Por seguridad, cambia esta contraseña al iniciar sesión
                </div>
            </div>
            
            <div class="message">
                <strong>Recomendaciones de seguridad:</strong>
                <ul style="margin-top: 10px; text-align: left; display: inline-block;">
                    <li>✓ No compartas tu contraseña con nadie</li>
                    <li>✓ Utiliza una contraseña única y difícil de adivinar</li>
                    <li>✓ Cambia tu contraseña periódicamente</li>
                </ul>
            </div>
            
            <div class="warning-box">
                <div class="warning-text">
                    ⚠️ <strong>Nota importante:</strong> Este es un correo automático. Por favor, no respondas a este mensaje.
                    Si no solicitaste este cambio, ignora este correo o contacta a soporte inmediatamente.
                </div>
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