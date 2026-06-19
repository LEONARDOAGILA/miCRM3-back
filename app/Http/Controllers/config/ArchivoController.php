<?php
namespace App\Http\Controllers\config;

use App\Models\Menu;
use Illuminate\Support\Facades\DB;
use Illuminate\Http\Request;
use Exception;


use App\Http\Controllers\Controller;
use App\Http\Resources\Funciones;
use App\Http\Resources\ApiResponder;


use App\Services\AuditoriaService;
use App\Models\Archivo;

class ArchivoController extends Controller
{
    use ApiResponder;      

    public function __construct() {
        $this->middleware('auth:api',['except' =>[
            'allArchivos',
            'getArchivoTree',
            'findByIdMenu',

            'list',
            'findByUser',
            'findByUser2',
        ]]);
    }

    public function allArchivos(){
            try {
                // Obtener todos los archivos (la ordenación inicial no es necesaria)
                $archivos = Archivo::all();

                // Aplicar ordenación que respete el parent
                $sortedArchivos = $this->sortByParent($archivos);

                $dateFields = ['created_at', 'updated_at'];
                $sortedArchivos->map(function ($item) use ($dateFields) {
                    $funciones = new Funciones();
                    $funciones->formatoFechaItem($item, $dateFields);
                    return $item;
                });

                return $this->successResponse($sortedArchivos, 'La solicitud ha tenido éxito');
            } catch (Exception $e) {
                return $this->errorResponse($e->getMessage(), (int)$e->getCode());
            }
    }

    private function sortByParent($archivos){
        $children = [];

        // Agrupar los archivos por su padre
        foreach ($archivos as $archivo) {
            $parentId = $archivo->padre ?? 0; // Usar 0 como padre raíz si es null
            $children[$parentId][] = $archivo;
        }

        // Ordenar los hijos dentro de cada grupo por orden
        foreach ($children as $padreId => &$childList) {
            usort($childList, function ($a, $b) {
                return [$a->orden, $a->id] <=> [$b->orden, $b->id];
            });
        }

        $sorted = collect();
        // Función recursiva para agregar los elementos respetando la jerarquía
        $this->addChildren(0, $children, $sorted);

        return $sorted;
    }

    private function addChildren($parentId, $children, $sorted){
        if (!isset($children[$parentId])) {
            return;
        }

        foreach ($children[$parentId] as $archivo) {
            $sorted->push($archivo); // Agregar el archivo principal
            $this->addChildren($archivo->id, $children, $sorted); // Agregar sus hijos
        }
    }

    public function getArchivoTree(){
        $archivoTree = Archivo::where('padre', 0)
                        ->orderBy('orden') // Ordenar el primer nivel por 'order2'
                        ->with('children') // Cargar los hijos recursivamente
                        ->get();

    // Formatear fechas
    $dateFields = ['created_at', 'updated_at'];
    $archivoTree->map(function ($item) use ($dateFields) {
        $funciones = new Funciones();
        $funciones->formatoFechaItem($item, $dateFields);
        
        // Aplicar recursivamente a los hijos
        if ($item->children->isNotEmpty()) {
            $this->formatChildrenDates($item->children, $dateFields);
        }
        
        return $item;
    });

        // Eliminar el campo 'children' si está vacío
        $archivoTree->each(function ($archivo) {
            if ($archivo->children->isEmpty()) {
                unset($archivo->children);
            } else {
                // Si hay hijos, aplicar la misma lógica recursivamente
                $this->removeEmptyChildren($archivo->children);
            }
        });

        return $this->successResponse($archivoTree, 'La solicitud ha tenido éxito');
    }

    // Método auxiliar recursivo para formatear fechas de hijos
    private function formatChildrenDates($children, $dateFields)
    {
        $funciones = new Funciones();
        
        $children->each(function ($child) use ($funciones, $dateFields) {
            $funciones->formatoFechaItem($child, $dateFields);
            
            if ($child->children->isNotEmpty()) {
                $this->formatChildrenDates($child->children, $dateFields);
            }
        });
    }

    private function removeEmptyChildren($children) {
        $children->each(function ($child) {
            if ($child->children->isEmpty()) {
                unset($child->children);
            } else {
                $this->removeEmptyChildren($child->children);
            }
        });
    }

    

    

    

    

    

    private function addArchivoWithParent($menu, $menuById, &$sorted, &$processed)
    {
        if (isset($processed[$menu->id])) {
            return;
        }

        // Si tiene un padre y aún no se ha agregado, lo agregamos primero
        if ($menu->parent != 0 && isset($menuById[$menu->parent]) && !isset($processed[$menu->parent])) {
            $this->addMenuWithParent($menuById[$menu->parent], $menuById, $sorted, $processed);
        }

        // Agregar el menú y marcarlo como procesado
        $sorted->push($menu);
        $processed[$menu->id] = true;
    }

    public function addArchivo(Request $request){
        DB::beginTransaction();

        try {
            $exitoso = null;

                // Valida los datos (puedes usar la validación de Laravel, por ejemplo)
                $validatedData = $this->validate($request, [
                    'padre' => 'nullable|integer',
                    'orden' => 'nullable|integer',
                    'nivel' => 'nullable|integer',
                    'nombre' => 'required|string|max:255',
                    'url' => 'nullable|string|max:255',
                    'descripcion' => 'nullable|string',
                    'modulo' => 'nullable|string|max:255',
                    'icono' => 'nullable|string|max:255',
                    'color' => 'nullable|string|max:255',
                    'tipo' => 'nullable|string|max:255',
                    'escarpeta' => 'required|boolean',
                ]);

                // Procesa los datos y crea uno nuevo
                $archivo = new Archivo();
                $archivo->padre = $validatedData['padre'];
                $archivo->orden = $validatedData['orden'];
                $archivo->nivel = $validatedData['nivel'];
                $archivo->nombre = $validatedData['nombre'];
                $archivo->url = $validatedData['url'];
                $archivo->descripcion = $validatedData['descripcion'];
                $archivo->modulo = $validatedData['modulo'];
                $archivo->icono = $validatedData['icono'];
                $archivo->color = $validatedData['color'];
                $archivo->escarpeta = $validatedData['escarpeta'];
                $archivo->tipo = $validatedData['tipo'];
                $archivo->save(); // Guarda
                // Registrar auditoría
                AuditoriaService::registrarAuditoria('archivo', $archivo->id, 'CREATE', null, $archivo);
                $exitoso = Archivo::orderBy('id', 'desc')->get();
                // Especificar las propiedades que representan fechas en tu objeto Nota
                $dateFields = ['created_at', 'updated_at'];
                
                // Utilizar la función map para transformar y obtener una nueva colección
                $exitoso->map(function ($item) use ($dateFields) {
                    $funciones = new Funciones();
                    $funciones->formatoFechaItem($item, $dateFields);
                    return $item;
                });
                
                DB::commit();
                
                return $this->successResponse($exitoso,'Se guardó con éxito');
        } catch (Exception $e) {
                DB::rollBack();
                return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function findByIdMenu($id){
        try {
            $data = null;

            $data = Menu::where('id', $id)
                    ->first(); // Limita el resultado a 1 registro    
            
            return $this->successResponse($data,'La solicitud ha tenido éxito');
            
        } catch (Exception $e) {
                return $this->errorResponse($e->getMessage(), (int)$e->getCode());
        }
    }






    public function editMenu(Request $request, $id)
    {
        DB::beginTransaction();

        try {
            // Decodificar el JSON de entrada
            $params_array = json_decode($request->input('json', null), true);
            $params_array1 = $params_array;
            
            // Validar los datos
            $validatedData = \Validator::make($params_array, [
                'order2' => 'nullable|integer',
                'name' => 'required|string|max:255',
                'url' => 'nullable|string|max:255',
                'description' => 'nullable|string',
                'label' => 'nullable|string|max:255',
                'icon' => 'nullable|string|max:255',
            ]);
    
            if ($validatedData->fails()) {
                return $this->errorResponse($validatedData->errors(), 400);
            }
    
            // Obtener el perfil actual antes de la actualización
            $BeforeUpdate = Menu::findOrFail($id);
    
            // Actualizar el menu
            $menuId = Menu::where('id', $id)->update($params_array1);
    
            // Quitar campos que no quiero actualizar
            unset($params_array['id']);
            unset($params_array['created_at']);
            unset($params_array['updated_at']);
    
            // Obtener el perfil actualizado
            $afterUpdated = Menu::findOrFail($id);
        
            // Especificar las propiedades que representan fechas en tu objeto Nota
            $dateFields = ['created_at', 'updated_at'];
            $funciones = new Funciones();
            $funciones->formatoFechaItem($afterUpdated, $dateFields);
    
            // Registrar auditoría usando el servicio
            AuditoriaService::registrarAuditoria('profile', $id, 'UPDATE', $BeforeUpdate, $afterUpdated);
    
            DB::commit();
            return $this->successResponse($afterUpdated, 'Se modificó con éxito');
    
        } catch (Exception $e) {
            DB::rollBack();
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function deleteMenu(Request $request, $id){
        try {
            $data = DB::transaction(function () use ($request, $id) {
                // Buscar el menú por su ID
                $menu = Menu::findOrFail($id);
                
                // Verificar si el menú tiene hijos
                $hasChildren = Menu::where('parent', $menu->id)->exists();
                if ($hasChildren) {
                    throw new Exception('No se puede eliminar este menú porque tiene hijos.');
                }
    
                $menu->access()->delete();                
                $menu->delete();
                
                // Registrar auditoría para la eliminación del menú (descomenta esta línea si necesitas registrar la auditoría)
                AuditoriaService::registrarAuditoria('menu', $menu->id, 'DELETE', $menu, null);
                
                return $menu;
            });
    
            return $this->successResponse($data, 'Se eliminó con éxito');
        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 400);
        }    
    }
}
