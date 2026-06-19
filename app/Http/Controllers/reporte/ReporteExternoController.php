<?php

namespace App\Http\Controllers\reporte;

use Exception;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

use App\Http\Controllers\Controller;
use Illuminate\Support\Facades\Validator;

use App\Http\Resources\Funciones;
use App\Http\Resources\ApiResponder;

use App\Services\AuditoriaService;

use App\Models\auth\User;
use App\Models\ReporteExterno;
use App\Models\UsersReporteExterno;

class ReporteExternoController extends Controller{

    use ApiResponder;

    public function __construct() {
        $this->middleware('auth:api',['except' =>[
            'allReportesExternos',
        ]]);
    }


    public function allReportesExternos(){
        try {
            $data = ReporteExterno::with('departamento')->orderBy('id', 'desc')->get();

            $dateFields = ['created_at', 'updated_at'];
            $data->map(function ($item) use ($dateFields) {
                $funciones = new Funciones();
                $funciones->formatoFechaItem($item, $dateFields);
                return $item;
            });
            return $this->successResponse($data,'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), (int) $e->getCode() ?: 500);
        }
    }


    public function listReportesExternos(){
        try {
            $data = ReporteExterno::where('activo', true)->get();
            $dateFields = ['created_at', 'updated_at'];
            $data->map(function ($item) use ($dateFields) {
                $funciones = new Funciones();
                $funciones->formatoFechaItem($item, $dateFields);
                return $item;
            });
            return $this->successResponse($data,'La solicitud ha tenido éxito');
        }catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), (int) $e->getCode() ?: 500);
        }
    }

    public function findByIdReporteExterno($id){
        try {
            $data = ReporteExterno::find($id);
            if (!$data) {
                return $this->errorResponse('ReporteExterno no encontrado o inactivo', 404);
            }
            return $this->successResponse($data, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), (int) $e->getCode() ?: 500);
        }
    }

    public function addReporteExterno(){
        DB::beginTransaction();

            try {

                // Valida los datos
                $validator = Validator::make(request()->all(), [
                    'nombre' => 'required|string',
                    'activo' => 'required|boolean',
                    'departamento_id'=> 'required|integer',
                ]);
                
                if ($validator->fails()) {
                    return $this->errorResponse($validator->errors(), 422);
                }            
                //$validatedData = $validator->validated();
                
                // Procesa los datos y crea un nuevo reporteExterno
                $reporteExterno = new ReporteExterno();
                $reporteExterno->nombre = request() -> nombre;
                $reporteExterno->descripcion = request() -> descripcion;
                $reporteExterno->url = request() -> url;
                $reporteExterno->activo = request() -> activo;
                $reporteExterno->departamento_id = request() -> departamento_id;
                $reporteExterno->save();

                // Registrar en auditoría
                AuditoriaService::registrarAuditoria('reporteExterno', $reporteExterno->id, 'INSERTO', null, $reporteExterno);

                // Obtener todos los registros de la tabla
                $data = null;
                $data = ReporteExterno::with('departamento')->orderBy('id', 'desc')->get();

                // Formatear ferchas
                $dateFields = ['created_at', 'updated_at'];
                $data->map(function ($item) use ($dateFields) {
                    $funciones = new Funciones();
                    $funciones->formatoFechaItem($item, $dateFields);
                    return $item;
                });

                // Commit de la transacción
                DB::commit();
                return $this->successResponse($data,'Se guardó con éxito');


            } catch (\Exception $e) {
                    DB::rollBack();
                    return $this->errorResponse($e->getMessage(), 500);
            }
    }

    public function editReporteExterno(Request $request, $id){
        DB::beginTransaction();

        try {
            // Decodificar el JSON de entrada
            $params = json_decode($request->input('json', null), true);

            // Validar los datos
            $validator = \Validator::make($params, [
                'nombre' => 'required|string|max:100',
                'descripcion' => 'string|max:500',
                'url' => 'required|string|max:500',
                'activo' => 'required|boolean',
                'departamento_id'=> 'required|integer',
            ]);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors(), 422);
            }

            // Obtener registro antes de modificar
            $beforeUpdate = ReporteExterno::findOrFail($id);

            // Eliminar campos que no se deben actualizar
            unset($params['id'], $params['created_at']);

            // Actualizar
            ReporteExterno::where('id', $id)->update($params);

            // Obtener registro actualizado
            $afterUpdate = ReporteExterno::with('departamento')->findOrFail($id);


            // Formatear fechas
            $dateFields = ['created_at', 'updated_at'];
            (new Funciones())->formatoFechaItem($afterUpdate, $dateFields);

            // Registrar en auditoría
            AuditoriaService::registrarAuditoria('reporteExterno', $id, 'ACTUALIZO', $beforeUpdate, $afterUpdate);

            // Commit de la transacción
            DB::commit();
            return $this->successResponse($afterUpdate, 'Se modificó con éxito');

        } catch (\Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), $e->getCode() ?: 500);
        }
    }

    public function deleteReporteExterno(Request $request, $id){
        DB::beginTransaction();

        try {
            // Buscar el reporteExterno a eliminar
            $reporteExterno = ReporteExterno::find($id);

            // Si no se encuentra el reporteExterno, devolver error 404
            if (!$reporteExterno) {
                return $this->errorResponse('ReporteExterno no encontrado', 404);
            }

            // Eliminar el registro
            $reporteExterno->delete();

            // Registrar auditoría de eliminación
            AuditoriaService::registrarAuditoria('reporteExterno', $reporteExterno->id, 'ELIMINO', $reporteExterno, null);

            // Commit de la transacción
            DB::commit();
            return $this->successResponse($reporteExterno, 'Se eliminó con éxito');

        } catch (\Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), $e->getCode() ?: 500);
        }
    }

    public function clonReporteExterno(Request $request){
        DB::beginTransaction();

        try {
            // Recoger datos por post
            $json = $request->input('json', null);
            $params_array = json_decode($json, true);

            // Validar los datos
            $validatedData = \Validator::make($params_array, [
                'nombre' => 'required|string|max:100',
                'descripcion' => 'string|max:500',
                'url' => 'required|string|max:500',
                'activo' => 'required|boolean',
                'departamento_id'=> 'required|integer',
            ]);

            if ($validatedData->fails()) {
                return $this->errorResponse($validatedData->errors(), 400);
            }

            // Crea un nuevo reporteExterno
            $reporteExterno = new ReporteExterno($params_array);
            $reporteExterno->save();

            // Registrar auditoría para la creación del perfil
            AuditoriaService::registrarAuditoria('reporteExterno', $reporteExterno->id, 'INSERTO', null, $reporteExterno);

            $data = null;
            $data = ReporteExterno::with('departamento')->orderBy('id', 'desc')->get();

            // formatea fecha
            $dateFields = ['created_at', 'updated_at'];
            $data->map(function ($item) use ($dateFields) {
                $funciones = new Funciones();
                $funciones->formatoFechaItem($item, $dateFields);
                return $item;
            });

            // Commit de la transacción
            DB::commit();
            return $this->successResponse($data,'Se creo con éxito');

        } catch (\Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), $e->getCode() ?: 500);
        }
    }



    public function listUserReportesExternos(){
        try {
            // Obtener el usuario autenticado
            $user = auth('api')->user();
            
            if (!$user) {
                return $this->errorResponse('Usuario no autenticado', 401);
            }

            // Obtener los reportes externos con los datos de la tabla intermedia
            $data = ReporteExterno::where('activo', true)
                ->whereHas('users', function($query) use ($user) {
                    $query->where('users.id', $user->id);
                })
                ->with(['departamento', 'users' => function($query) use ($user) {
                    $query->where('users.id', $user->id)
                        ->select('users.id', 'users.name', 'users.surname')
                        ->withPivot(['created_at', 'updated_at', 'view_at']);
                }])
                ->get();

            // Transformar la estructura de la respuesta
            $transformedData = $data->map(function($reporte) {
                $userData = $reporte->users->first(); // Obtener los datos del usuario en la relación pivot
                
                return [
                    'id' => $reporte->id,
                    'nombre' => $reporte->nombre,
                    'descripcion' => $reporte->descripcion,
                    'url' => $reporte->url,
                    'departamento' => $reporte->departamento,
                    'users_reporteexterno' => $userData ? [
                        'pivot_id' => $userData->pivot->id,
                        'view_at' => $userData->pivot->view_at
                    ] : null
                ];
            });

            // Formatear fechas
            $dateFields = ['created_at', 'updated_at'];
            $transformedData->map(function ($item) use ($dateFields) {
                $funciones = new Funciones();
                $funciones->formatoFechaItem($item, $dateFields);
                if ($item['users_reporteexterno']) {
                    $funciones->formatoFechaItem($item['users_reporteexterno'], $dateFields);
                }
                return $item;
            });
            
            return $this->successResponse($transformedData, 'La solicitud ha tenido éxito');
            
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), (int) $e->getCode() ?: 500);
        }
    }

    public function listUsersReportesExternosSelected($id_reporte){
        try {            
            $data = User::select('users.*')
                ->with(['profile:id,name', 'reporteExternos:id,nombre'])
                ->join('profile', 'profile.id', '=', 'users.profile_id')
                ->join('users_reporteexterno', 'users_reporteexterno.users_id', '=', 'users.id')
                ->where('users_reporteexterno.reporteexterno_id', $id_reporte)
                ->get();

            $dateFields = ['created_at', 'updated_at'];
            $data->map(function ($item) use ($dateFields) {
                $funciones = new Funciones();
                $funciones->formatoFechaItem($item, $dateFields);
                return $item;
            });
            return $this->successResponse($data,'La solicitud ha tenido éxito');
        }catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), (int) $e->getCode() ?: 500);
        }
    }

    public function listUsersReportesExternosPendientexSeleccionar($id_reporte){
        try {            
            $data = User::select('users.*')
                ->with(['profile:id,name', 'reporteExternos:id,nombre'])
                ->join('profile', 'profile.id', '=', 'users.profile_id')
                ->whereNotIn('users.id', function($query)use ($id_reporte) {
                    $query->select('users_id')
                        ->from('users_reporteexterno')
                        ->where('reporteexterno_id', $id_reporte);
                })
                ->get();

            $dateFields = ['created_at', 'updated_at'];
            $data->map(function ($item) use ($dateFields) {
                $funciones = new Funciones();
                $funciones->formatoFechaItem($item, $dateFields);
                return $item;
            });
            return $this->successResponse($data,'La solicitud ha tenido éxito');
        }catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), (int) $e->getCode() ?: 500);
        }
    }

    public function saveUsersReportesExternos(Request $request) {
        try {
            $data = DB::transaction(function () use ($request) {
                // Primero obtenemos el reporteexterno_id del primer usuario (si existe)
                $reporteExternoId = null;
                if (isset($request->usuariosNuevos) && count($request->usuariosNuevos) > 0) {
                    $reporteExternoId = $request->usuariosNuevos[0]['reporteexterno_id'];
                }

                // Eliminamos todos los usuarios asociados al reporteexterno_id
                if ($reporteExternoId) {
                    UsersReporteExterno::where('reporteexterno_id', $reporteExternoId)->delete();
                } else {
                    // Si no hay usuarios nuevos, igual eliminamos cualquier asociación existente
                    UsersReporteExterno::where('reporteexterno_id', $request->reporteexterno_id ?? null)->delete();
                }

                // Luego, insertamos los usuarios nuevos
                if (isset($request->usuariosNuevos) && count($request->usuariosNuevos) > 0) {
                    foreach ($request->usuariosNuevos as $usuarioNuevo) {
                        // Verificamos si el usuario ya existe (aunque debería estar borrado)
                        $existingUser = UsersReporteExterno::where('users_id', $usuarioNuevo['users_id'])
                            ->where('reporteexterno_id', $usuarioNuevo['reporteexterno_id'])
                            ->first();

                        // Si no existe, lo creamos
                        if (!$existingUser && $usuarioNuevo['users_id'] !== null) {
                            UsersReporteExterno::create([
                                'reporteexterno_id' => $usuarioNuevo['reporteexterno_id'],
                                'users_id' => $usuarioNuevo['users_id'],
                            ]);
                        }
                    }
                }

                return null;
            });

            return $this->successResponse($data, 'Se guardó con éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function updateUsersReportesExternos($reporteExternoId) {
        DB::beginTransaction();
        
        try {
            // Obtener el usuario autenticado
            $user = auth('api')->user();
            
            if (!$user) {
                return $this->errorResponse('Usuario no autenticado', 401);
            }

            // Buscar la relación usuario-reporte
            $userReporte = UsersReporteExterno::where('users_id', $user->id)
                ->where('reporteexterno_id', $reporteExternoId)
                ->first();

            if (!$userReporte) {
                return $this->errorResponse('Relación usuario-reporte no encontrada', 404);
            }

            // Guardar el estado anterior para auditoría
            $beforeUpdate = clone $userReporte;

            // Actualizar el campo view_at con la fecha y hora actual
            $userReporte->view_at = now();
            $userReporte->save();

            // Obtener el estado después de la actualización
            $afterUpdate = $userReporte;

            // Registrar en auditoría
            AuditoriaService::registrarAuditoria(
                'users_reporteexterno', 
                $userReporte->id, 
                'ACTUALIZO', 
                $beforeUpdate, 
                $afterUpdate
            );

            // Formatear fechas para la respuesta
            $dateFields = ['created_at', 'updated_at', 'view_at'];
            (new Funciones())->formatoFechaItem($afterUpdate, $dateFields);

            DB::commit();
            return $this->successResponse($afterUpdate, 'Fecha de visualización actualizada con éxito');

        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), $e->getCode() ?: 500);
        }
    }
    

}
