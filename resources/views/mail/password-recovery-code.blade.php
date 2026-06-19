<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="X-UA-Compatible" content="IE=edge">
    <title>Código de Recuperación</title>
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
        
        .code-box {
            background: linear-gradient(135deg, #fff9e6 0%, #fff3cd 100%);
            border-left: 4px solid #ffc107;
            padding: 20px;
            border-radius: 8px;
            margin: 25px 0;
            text-align: center;
        }
        
        .code-label {
            font-size: 14px;
            color: #856404;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 10px;
        }
        
        .code-value {
            font-size: 32px;
            font-weight: bold;
            color: #d9534f;
            font-family: monospace;
            letter-spacing: 5px;
            background: #fff;
            display: inline-block;
            padding: 15px 25px;
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
        
        @media (max-width: 480px) {
            .content {
                padding: 25px 20px;
            }
            
            .title {
                font-size: 20px;
            }
            
            .code-value {
                font-size: 24px;
                padding: 10px 15px;
                letter-spacing: 3px;
            }
            
            .header {
                padding: 20px;
            }
        }
    </style>
</head>
<body>

    <div class="container">
        <div class="header">
            <div class="logo">
                <img src="{{ $message->embed(public_path('storage/img/mail/mail.png')) }}" alt="Logo">
            </div>
        </div>

        <div class="content">
            <h1 class="title">Recuperación de Contraseña</h1>
            
            <div class="greeting">
                Estimado/a, <strong>{{ $object->email }}</strong>
            </div>
            
            <div class="message">
                Hemos recibido una solicitud para recuperar tu contraseña en <strong>miEMPRESA Cía. Ltda.</strong>
            </div>
            
            <div class="code-box">
                <div class="code-label">🔐 Tu código de verificación es:</div>
                <div class="code-value">{{ $object->codigo }}</div>
                <div style="font-size: 12px; color: #856404; margin-top: 10px;">
                    ⏰ Este código expira en 15 minutos
                </div>
            </div>
            
            <div class="message">
                <strong>Instrucciones:</strong>
                <ol style="margin-top: 10px; text-align: left; display: inline-block;">
                    <li>1. Ingresa este código en la aplicación</li>
                    <li>2. Podrás establecer una nueva contraseña</li>
                    <li>3. La solicitud expirará en 15 minutos</li>
                </ol>
            </div>
            
            <div class="warning-box">
                <div class="warning-text">
                    ⚠️ <strong>Nota importante:</strong> Si no solicitaste este cambio, ignora este correo 
                    o contacta a soporte inmediatamente.
                </div>
            </div>
        </div>

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