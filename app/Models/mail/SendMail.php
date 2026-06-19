<?php

namespace App\Models\mail;

use Illuminate\Bus\Queueable;
use Illuminate\Mail\Mailable;
use Illuminate\Queue\SerializesModels;

class SendMail extends Mailable
{
    use Queueable, SerializesModels;

    public $object;
    public $subjectText;
    public $viewName;
    public $attachmentsList;

    /**
     * Create a new message instance.
     * 
     * @param object $object Datos para la vista (con email, password, etc.)
     * @param string $subject Asunto del correo
     * @param string $viewName Nombre de la vista (ej: 'mail.send_email')
     * @param array $attachments Lista de archivos a adjuntar
     */
    public function __construct($object, $subject, $viewName, $attachments = [])
    {
        $this->object = $object;
        $this->subjectText = $subject;
        $this->viewName = $viewName;
        $this->attachmentsList = $attachments;
    }

    public function build()
    {
        $mail = $this->subject($this->subjectText)
                    ->view($this->viewName)
                    ->with('object', $this->object);
        
        // Adjuntar archivos
        foreach ($this->attachmentsList as $attachment) {
            if (isset($attachment['path']) && file_exists($attachment['path'])) {
                $mail->attach($attachment['path'], [
                    'as' => $attachment['as'] ?? basename($attachment['path']),
                    'mime' => $attachment['mime'] ?? mime_content_type($attachment['path']),
                ]);
            }
        }
        
        return $mail;
    }
}
