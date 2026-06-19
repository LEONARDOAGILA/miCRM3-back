<?php

namespace App\Http\Resources;


class RespuestaApi
{

    public static function returnResultado($estado, $message, $data)
    {
        switch ($estado) {
            case 'success':
                return array(
                    'code' =>  200,
                    'status' =>  'success',
                    'message' =>  $message,
                    'data' =>  $data,
                    'icon' =>  'success',
                    'color' =>  '#99ff99'
                );

            case 'error':
                return array(
                    'code' =>   500,
                    'status' =>  'error',
                    'message' =>  $message,
                    'data' =>  $data,
                    'icon' =>  'error',
                    'color' =>  '#ff4000'
                );

            case 'exception':
                return array(
                    'code' =>   500,
                    'status' =>  'error',
                    'message' =>  'Exception: '.$message,
                    'data' =>  $data,
                    'icon' =>  'error',
                    'color' =>  '#ff4000'
                );
            default:
            return array(
                'code' =>   404,
                'status' =>  'error',
                'message' =>  'Exception: '.$message,
                'data' =>  $data,
                'icon' =>  'error',
                'color' =>  '#ff4000'
            );
        }
    }
}
