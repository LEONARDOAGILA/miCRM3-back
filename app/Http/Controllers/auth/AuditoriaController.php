<?php

namespace App\Http\Controllers\auth;

use Exception;
use Illuminate\Http\Request;
use App\Http\Controllers\Controller;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Facades\DB;
use App\Http\Resources\Funciones;
use App\Http\Resources\ApiResponder;
use App\Models\auth\Auditoria;

class AuditoriaController extends Controller
{
    use ApiResponder;

    public function __construct()
    {
        $this->middleware('auth:api');
    }

    /**
     * Obtiene todos los registros de auditoría con paginación
     */
    public function all(Request $request){
        try {
            $validator = Validator::make($request->all(), [
                'per_page' => 'sometimes|integer|min:1|max:100',
                'page' => 'sometimes|integer|min:1',
                'tabla' => 'sometimes|string|max:100',
                'registro_id' => 'sometimes|integer',
                'tipo_operacion' => 'sometimes|string|in:INSERT,UPDATE,DELETE',
                'fecha_desde' => 'sometimes|date',
                'fecha_hasta' => 'sometimes|date|after_or_equal:fecha_desde'
            ]);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors(), 422);
            }

            $query = Auditoria::query()
                ->orderBy('fecha_operacion', 'desc');

            // Filtros
            if ($request->has('tabla')) {
                $query->where('tabla_afectada', $request->tabla);
            }

            if ($request->has('registro_id')) {
                $query->where('id_registro_afectado', $request->registro_id);
            }

            if ($request->has('tipo_operacion')) {
                $query->where('tipo_operacion', $request->tipo_operacion);
            }

            if ($request->has('fecha_desde') && $request->has('fecha_hasta')) {
                $query->whereBetween('fecha_operacion', [
                    $request->fecha_desde,
                    $request->fecha_hasta . ' 23:59:59'
                ]);
            }

            $perPage = $request->per_page ?? 15;
            $data = $query->paginate($perPage);

            // Formatear fechas
            $dateFields = ['fecha_operacion'];
            $data->getCollection()->transform(function ($item) use ($dateFields) {
                $funciones = new Funciones();
                $funciones->formatoFechaItem($item, $dateFields);
                return $item;
            });

            return $this->successResponse($data, 'Registros de auditoría obtenidos');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    // public function getByRecord(Request $request, $tabla, $id)
    // {
            
    //     // echo "Datos recibidos:";
    //     // print_r($request->tipo_operacion);

    //         info("Tabla: $tabla, ID: $id");

    //     try {
    //         $validator = Validator::make($request->all(), [         
    //             'tipo_operacion' => 'sometimes|string|in:INSERT,UPDATE,DELETE',
    //              'fecha_desde' => 'sometimes|date',
    //              'fecha_hasta' => 'sometimes|date|after_or_equal:fecha_desde'
    //         ]);



    //         if ($validator->fails()) {
    //             return $this->errorResponse($validator->errors(), 422);
    //         }

    //         $query = Auditoria::where('tabla_afectada', $tabla)
    //             ->where('id_registro_afectado', $id)
    //             ->orderBy('fecha_operacion', 'desc');

    //         // Filtros adicionales
    //         if ($request->has('tipo_operacion')) {
    //             $query->where('tipo_operacion', $request->tipo_operacion);
    //         }

    //         if ($request->has('fecha_desde') && $request->has('fecha_hasta')) {
    //             $query->whereBetween('fecha_operacion', [
    //                 $request->fecha_desde,
    //                 $request->fecha_hasta . ' 23:59:59'
    //             ]);
    //         }

    //         // echo "Consulta SQL: " . $query->toSql() . "\n";
    //         // print_r($query->getBindings());


    //         $data = $query->get();

    //         // Formatear fechas y datos JSON
    //         $dateFields = ['fecha_operacion'];
    //         $data->transform(function ($item) use ($dateFields) {
    //             $funciones = new Funciones();
    //             $funciones->formatoFechaItem($item, $dateFields);
                
    //             // Convertir JSON a array para mejor manejo en frontend
    //             $item->datos_anteriores = json_decode($item->datos_anteriores, true);
    //             $item->datos_nuevos = json_decode($item->datos_nuevos, true);
                
    //             return $item;
    //         });

    //         return $this->successResponse($data, 'Historial de auditoría obtenido');
    //     } catch (Exception $e) {
    //         return $this->errorResponse($e->getMessage(), 500);
    //     }
    // }





public function getByRecord(Request $request, $tabla, $id)
{
    try {
        // Validar parámetros
        $validator = Validator::make($request->all(), [         
            'tipo_operacion' => 'nullable|string|in:INSERT,UPDATE,DELETE,insert,update,delete',
            'fecha_desde' => 'nullable|date|date_format:Y-m-d',
            'fecha_hasta' => 'nullable|date|date_format:Y-m-d|after_or_equal:fecha_desde',
            'page' => 'nullable|integer|min:1',
            'per_page' => 'nullable|integer|min:1|max:100'
        ]);

        if ($validator->fails()) {
            return $this->errorResponse($validator->errors()->first(), 422);
        }

        $page = $request->input('page', 1);
        $perPage = $request->input('per_page', 15);
        $operacion = $request->input('tipo_operacion');
        
        // Convertir operación a MAYÚSCULAS para que coincida con la BD
        if ($operacion) {
            $operacion = strtoupper($operacion);
        }
        
        $fechaDesde = $request->input('fecha_desde');
        $fechaHasta = $request->input('fecha_hasta');

        // Llamar a la función de PostgreSQL
        $results = DB::select('
            SELECT auditoria.fn_auditoria_listar_paginado(
                ?::TEXT,
                ?::TEXT,
                ?::TEXT,
                ?::TEXT,
                ?::TEXT,
                ?::INTEGER,
                ?::INTEGER
            ) as result
        ', [
            $tabla,
            (string)$id,
            $operacion,
            $fechaDesde,
            $fechaHasta,
            (int)$page,
            (int)$perPage
        ]);

        $result = $results[0] ?? null;
        
        if (!$result || !isset($result->result)) {
            return $this->errorResponse('No se obtuvieron datos de auditoría', 500);
        }

        $resultado = json_decode($result->result, true);
        
        if (json_last_error() !== JSON_ERROR_NONE) {
            return $this->errorResponse('Error al procesar datos de auditoría', 500);
        }

        if (!$resultado['success']) {
            return $this->errorResponse($resultado['message'] ?? 'Error al obtener auditoría', 400);
        }

        // Log de éxito
        sistemaLog('info', 'Historial de auditoría obtenido exitosamente', [
            'tabla' => $tabla,
            'registro_id' => $id,
            'total_registros' => $resultado['meta']['total'] ?? 0,
            'pagina' => $page,
            'por_pagina' => $perPage,
            'filtros' => [
                'tipo_operacion' => $operacion,
                'fecha_desde' => $fechaDesde,
                'fecha_hasta' => $fechaHasta
            ]
        ]);

        $responseData = [
            'data' => $resultado['data'],
            'meta' => $resultado['meta']
        ];

        return $this->successResponse($responseData, 'Historial de auditoría obtenido');

    } catch (Exception $e) {
        sistemaLog('error', 'Error en getByRecord', [
            'code'    => $e->getCode(),
            'message' => $e->getMessage(),
            'line'    => $e->getLine(),
            'tabla'   => $tabla,
            'id'      => $id
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
}





    /**
     * Obtiene los últimos N registros de auditoría
     */
    public function getLatest($limit = 10){
        try {
            $validator = Validator::make(['limit' => $limit], [
                'limit' => 'sometimes|integer|min:1|max:100'
            ]);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors(), 422);
            }

            $data = Auditoria::orderBy('fecha_operacion', 'desc')
                ->limit($limit)
                ->get();

            // Formatear fechas
            $dateFields = ['fecha_operacion'];
            $data->transform(function ($item) use ($dateFields) {
                $funciones = new Funciones();
                $funciones->formatoFechaItem($item, $dateFields);
                return $item;
            });

            return $this->successResponse($data, 'Últimos registros de auditoría');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}