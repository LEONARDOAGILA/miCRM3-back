<?php

namespace App\Http\Resources;

use Illuminate\Http\JsonResponse;
use Symfony\Component\HttpFoundation\Response;

trait ApiResponder
{


  public function successResponse($data, $message, int $code = Response::HTTP_OK): JsonResponse {
        return response()->json([
            'code' => $code,
            'status' => 'success',
            'message' => $message,
            'icon' =>  'success',
            'color' =>  '#99ff99',
            'data' => $data,
        ], $code)->header('Content-Type', 'application/json');
  }

  public function errorResponse($message, int $code = Response::HTTP_BAD_REQUEST): JsonResponse
  {
        return response()->json([
        'code'  => $code,
        'status' => 'error',
        'message' => $message,
        'icon' =>  'error',
        'color' =>  '#99ff99',
        'data' => null,
        ], $code)->header('Content-Type', 'application/json');
    }


}
