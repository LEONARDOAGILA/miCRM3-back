<?php

namespace App\Http\Controllers\auth;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use Exception;

class HorarioController extends Controller
{
    use ApiResponder;

    // ****** LISTAR HORARIOS PAGINADOS ****** //
    public function allHorarios(Request $request)
    {
        try {
            $page     = (int) $request->input('page', 1);
            $perPage  = (int) $request->input('per_page', 15);
            $search   = $request->input('search', '');
            
            $result = DB::selectOne('SELECT seguridad.fn_horarios_listar_paginado(?, ?, ?) as result', [
                $page,
                $perPage,
                $search
            ]);
            
            $resultado = json_decode($result->result, true);
            
            sistemaLog('info', 'allHorarios ejecutado correctamente', [
                'total_registros' => $resultado['meta']['total'] ?? 0,
                'pagina'          => $page,
                'busqueda'        => $search,
                'usuario'         => auth('api')->user()->login_user ?? 'desconocido',
                'ip'              => request()->ip()
            ]);
            
            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allHorarios', [
                'code'    => $e->getCode(),
                'message' => $e->getMessage(),
                'line'    => $e->getLine()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
    

    public function listHorarios(Request $request)
    {
    try{
        $page     = (int) $request->input('page', 1);
        $perPage  = (int) $request->input('per_page', 15);
        $search   = $request->input('search', '');
        
        $result = DB::selectOne('SELECT seguridad.fn_horarios_listar_paginado_activos(?, ?, ?) as result', [
            $page,
            $perPage,
            $search
        ]);
        
        $resultado = json_decode($result->result, true);
        
        sistemaLog('info', 'listHorarios ejecutado correctamente', [
            'total_registros' => $resultado['meta']['total'] ?? 0,
            'pagina'          => $page,
            'busqueda'        => $search,
            'usuario'         => auth('api')->user()->login_user ?? 'desconocido',
            'ip'              => request()->ip()
        ]);
        
        return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        
    } catch (Exception $e) {
        sistemaLog('error', 'Error en listHorarios', [
            'code'    => $e->getCode(),
            'message' => $e->getMessage(),
            'line'    => $e->getLine()
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
    }


public function findByIdProfile($id)
{
    try {
        // SQL directo: buscar perfil activo por ID
        $data = DB::selectOne("
            SELECT 
                id,
                nombre,
                inactividad,
                activo,
                TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at_formateado,
                TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI:SS') as updated_at_formateado
            FROM seguridad.perfiles
            WHERE id = ? AND activo = true
        ", [$id]);

        if ($data === null) {
            sistemaLog('warning', 'Perfil no encontrado o inactivo', [
                'perfil_id' => $id,
                'usuario' => auth('api')->user()->login_user ?? 'desconocido',
                'ip' => request()->ip()
            ]);
            return $this->errorResponse('Perfil no encontrado o inactivo', 404);
        }

        sistemaLog('info', 'findByIdProfile ejecutado correctamente', [
            'perfil_id' => $data->id,
            'nombre' => $data->nombre,
            'usuario' => auth('api')->user()->login_user ?? 'desconocido',
            'ip' => request()->ip()
        ]);

        return $this->successResponse($data, 'La solicitud ha tenido éxito');

    } catch (Exception $e) {
        sistemaLog('error', 'Error en findByIdProfile', [
            'code' => $e->getCode(),
            'message' => $e->getMessage(),
            'line' => $e->getLine(),
            'perfil_id' => $id,
            'ip' => request()->ip()
        ]);

        return $this->errorResponse($e->getMessage(), 500);
    }
}    


    public function getHorario($id)
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_horarios_obtener(?) as result', [$id]);
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 404, $resultado['error_code'] ?? null);
            }
            
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }


    public function addHorario(Request $request)
    {
        try {
            // 1. Validar los datos de entrada
            $validatedData = $this->validate($request, [
                'nombre'  => 'required|string|max:100',
                'activo'  => 'nullable|boolean',
                'dhorario' => 'nullable|array'
            ]);

            // 2. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

            // 3. Preparar el JSON de dhorario
            $dhorarioJson = null;
            if (isset($validatedData['dhorario']) && !empty($validatedData['dhorario'])) {
                $dhorarioArray = array_map(function($item) {
                    return [
                        'dia' => (int)$item['dia'],
                        'hora_inicio' => $item['hora_inicio'],
                        'hora_fin' => $item['hora_fin'],
                        'activo' => (bool)($item['activo'] ?? true)
                    ];
                }, $validatedData['dhorario']);
                $dhorarioJson = json_encode($dhorarioArray);
            }

            // 4. Convertir booleano para PostgreSQL
            $activoPostgres = $validatedData['activo'] ? 'true' : 'false';

            // 5. Llamar a la función de PostgreSQL
            $result = DB::selectOne('
                SELECT seguridad.fn_horarios_crear(
                    ?::VARCHAR,
                    ?::BOOLEAN,
                    ?::JSONB,
                    ?::BIGINT,
                    ?::VARCHAR,
                    ?::VARCHAR,
                    ?::INET,
                    ?::TEXT,
                    ?::UUID
                ) as result
            ', [
                $validatedData['nombre'],
                $activoPostgres,
                $dhorarioJson,
                $usuarioId ? (int)$usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);

            $resultado = json_decode($result->result, true);

            if ($resultado['success']) {
                sistemaLog('info', 'Horario creado exitosamente', [
                    'horario_id' => $resultado['data']['id'],
                    'nombre'     => $resultado['data']['nombre'],
                    'usuario'    => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
            }

        } catch (Exception $e) {
            sistemaLog('error', 'Error en addHorario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'data'    => $request->all()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }


    public function editHorario(Request $request, $id)
    {
        try {
            $jsonData = $request->input('json');
            
            if (!$jsonData) {
                return $this->errorResponse('No se enviaron datos válidos', 400);
            }
            
            $data = json_decode($jsonData, true);
            
            if (json_last_error() !== JSON_ERROR_NONE) {
                return $this->errorResponse('Formato JSON inválido', 400);
            }
            
            $validator = Validator::make($data, [
                'nombre'  => 'required|string|max:100',
                'activo'  => 'nullable|boolean',
                'dhorario' => 'nullable|array'
            ]);
            
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 400);
            }
            
            $validatedData = $validator->validated();
            
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            $dhorarioJson = $validatedData['dhorario'] ? json_encode($validatedData['dhorario']) : null;
            
            $result = DB::selectOne('SELECT seguridad.fn_horarios_modificar(?, ?, ?, ?, ?, ?, ?, ?::inet, ?, ?::uuid) as result', [
                $id,
                $validatedData['nombre'],
                $validatedData['activo'] ?? true,
                $dhorarioJson,
                $usuarioId,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);
            
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                sistemaLog('info', 'Horario actualizado exitosamente', [
                    'horario_id' => $id,
                    'nombre'     => $resultado['data']['nombre'],
                    'usuario'    => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editHorario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'horario_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function deleteHorario(Request $request, $id)
    {
        try {
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            $result = DB::selectOne('SELECT seguridad.fn_horarios_eliminar(?, ?, ?, ?, ?::inet, ?, ?::uuid) as result', [
                $id,
                $usuarioId,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);
            
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                sistemaLog('info', 'Horario eliminado exitosamente', [
                    'horario_id' => $id,
                    'usuario'    => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteHorario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'horario_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}







