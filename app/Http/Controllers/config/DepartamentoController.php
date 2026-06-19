<?php

namespace App\Http\Controllers\config;

use Exception;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

use App\Http\Controllers\Controller;
use Illuminate\Support\Facades\Validator;

use App\Http\Resources\Funciones;
use App\Http\Resources\ApiResponder;

use App\Services\AuditoriaService;
use App\Models\Departamento;



class DepartamentoController extends Controller{

    use ApiResponder;

    public function __construct() {
        $this->middleware('auth:api',['except' =>[
            'allDepartamentos',
            'listDepartamentos',
            'findByIdDepartamento',        
        ]]);
    }


    public function allDepartamentos(){
        try {
            $data = Departamento::orderBy('id', 'desc')->get();
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


    public function listDepartamentos(){
        try {
            $data = Departamento::where('activo', true)->get();
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


    public function findByIdDepartamento($id){
        try {
            $data = Departamento::find($id);
            if (!$data) {
                return $this->errorResponse('Departamento no encontrado o inactivo', 404);
            }
            return $this->successResponse($data, 'La solicitud ha tenido éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), (int) $e->getCode() ?: 500);
        }
    }


    public function addDepartamento(){
        DB::beginTransaction();

            try {

                // Valida los datos
                $validator = Validator::make(request()->all(), [
                    'nombre' => 'required|string',
                    'activo' => 'required|boolean',
                ]);
                
                if ($validator->fails()) {
                    return $this->errorResponse($validator->errors(), 422);
                }            
                //$validatedData = $validator->validated();
                
                // Procesa los datos y crea un nuevo departamento
                $departamento = new Departamento();
                $departamento->nombre = request() -> nombre;
                $departamento->activo = request() -> activo;
                $departamento->save();

                // Registrar en auditoría
                AuditoriaService::registrarAuditoria('departamento', $departamento->id, 'INSERTO', null, $departamento);

                // Obtener todos los registros de la tabla
                $data = null;
                $data = Departamento::orderBy('id', 'desc')->get();

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


            } catch (Exception $e) {
                    DB::rollBack();
                    return $this->errorResponse($e->getMessage(), 500);
            }
    }

    public function editDepartamento(Request $request, $id){
        DB::beginTransaction();

        try {
            // Decodificar el JSON de entrada
            $params = json_decode($request->input('json', null), true);

            // Validar los datos
            $validator = \Validator::make($params, [
                'nombre' => 'required|string|max:255',
                'activo' => 'required|boolean',
            ]);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors(), 422);
            }

            // Obtener registro antes de modificar
            $beforeUpdate = Departamento::findOrFail($id);

            // Eliminar campos que no se deben actualizar
            unset($params['id'], $params['created_at']);

            // Actualizar
            Departamento::where('id', $id)->update($params);

            // Obtener registro actualizado
            $afterUpdate = Departamento::findOrFail($id);

            // Formatear fechas
            $dateFields = ['created_at', 'updated_at'];
            (new Funciones())->formatoFechaItem($afterUpdate, $dateFields);

            // Registrar en auditoría
            AuditoriaService::registrarAuditoria('departamento', $id, 'ACTUALIZO', $beforeUpdate, $afterUpdate);

            // Commit de la transacción
            DB::commit();
            return $this->successResponse($afterUpdate, 'Se modificó con éxito');

        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), $e->getCode() ?: 500);
        }
    }

    public function deleteDepartamento(Request $request, $id){
        DB::beginTransaction();

        try {
            // Buscar el departamento a eliminar
            $departamento = Departamento::find($id);

            // Si no se encuentra el departamento, devolver error 404
            if (!$departamento) {
                return $this->errorResponse('Departamento no encontrado', 404);
            }

            // Eliminar el registro
            $departamento->delete();

            // Registrar auditoría de eliminación
            AuditoriaService::registrarAuditoria('departamento', $departamento->id, 'ELIMINO', $departamento, null);

            // Commit de la transacción
            DB::commit();
            return $this->successResponse($departamento, 'Se eliminó con éxito');

        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), $e->getCode() ?: 500);
        }
    }


    public function clonDepartamento(Request $request){
        DB::beginTransaction();

        try {
            // Recoger datos por post
            $json = $request->input('json', null);
            $params_array = json_decode($json, true);

            // Validar los datos
            $validatedData = \Validator::make($params_array, [
                'nombre' => 'required|string|max:255',
                'activo' => 'required',
            ]);

            if ($validatedData->fails()) {
                return $this->errorResponse($validatedData->errors(), 400);
            }

            // Crea un nuevo departamento
            $departamento = new Departamento($params_array);
            $departamento->save();

            // Registrar auditoría para la creación del perfil
            AuditoriaService::registrarAuditoria('departamento', $departamento->id, 'INSERTO', null, $departamento);

            $data = null;
            $data = Departamento::orderBy('id', 'desc')->get();

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

        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), $e->getCode() ?: 500);
        }
    }

}
