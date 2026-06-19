<?php

namespace App\Http\Controllers\auth;

use Exception;
use App\Http\Controllers\Controller;
use Illuminate\Support\Facades\Mail;
use App\Models\mail\SendMail;

class EmailController extends Controller
{
    public function __construct()
    {
        $this->middleware('auth:api');
    }

    /**
     * Enviar correo electrónico parametrizable
     * 
     * @param string $email Destinatario
     * @param object $object Datos para la vista (con email, password, etc.)
     * @param string $subject Asunto del correo
     * @param string $viewName Nombre de la vista (ej: 'mail.send_email')
     * @param array $attachments Lista de archivos a adjuntar
     * @return bool
     */
    public function send_email($email, $object, $subject, $viewName, $attachments = [])
    {
        try {
            sistemaLog('info', 'Inicio de envío de correo', [
                'email' => $email,
                'subject' => $subject,
                'view' => $viewName
            ]);
            
            Mail::to($email)->send(new SendMail($object, $subject, $viewName, $attachments));
            
            sistemaLog('info', 'Correo electrónico enviado correctamente', [
                'email' => $email
            ]);
            
            return true;
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error: correo electrónico no enviado', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line' => $e->getLine(),
                'email' => $email,
                'subject' => $subject
            ]);
            
            return false;
        }
    }
}