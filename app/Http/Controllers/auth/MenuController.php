<?php
namespace App\Http\Controllers\auth;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Exception;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;


class MenuController extends Controller
{

    use ApiResponder;  
     
     public function __construct() {
        $this->middleware('auth:api',['except' =>[
            'allMenus'
        ]]);
    }
        
    


    public function allMenus()
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_menus_listar() as result');
            $resultado = json_decode($result->result, true);
            
            if ($resultado['success']) {
                sistemaLog('info', 'allMenus ejecutado correctamente', [
                    'total_registros' => count($resultado['data']),
                    'usuario' => auth('api')->user()->login_user ?? 'desconocido',
                    'ip' => request()->ip()
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en allMenus', [
                'code' => $e->getCode(),
                'message' => $e->getMessage(),
                'line'    => $e->getLine()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }    
    

    public function addMenu(Request $request)
    {
        try {
            // 1. Validar los datos de entrada
            $validatedData = $this->validate($request, [
                'nombre'     => 'required|string|max:100',
                'url'        => 'nullable|string|max:255',
                'descripcion'=> 'nullable|string|max:255',
                'etiqueta'   => 'nullable|string|max:100',
                'icono'      => 'nullable|string|max:50',
                'orden'      => 'nullable|integer',
                'padre_id'   => 'nullable|integer'
            ]);

            // 2. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

            // 3. Llamar a la función de PostgreSQL con CAST explícito
            $result = DB::selectOne('
                SELECT seguridad.fn_menus_crear(
                    ?::VARCHAR,   -- p_nombre
                    ?::VARCHAR,   -- p_url
                    ?::VARCHAR,   -- p_descripcion
                    ?::VARCHAR,   -- p_etiqueta
                    ?::VARCHAR,   -- p_icono
                    ?::INTEGER,   -- p_orden
                    ?::INTEGER,   -- p_padre_id
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                $validatedData['nombre'],
                $validatedData['url'] ?? null,
                $validatedData['descripcion'] ?? null,
                $validatedData['etiqueta'] ?? null,
                $validatedData['icono'] ?? null,
                (int)($validatedData['orden'] ?? 0),
                $validatedData['padre_id'] ? (int)$validatedData['padre_id'] : null,
                $usuarioId ? (int)$usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);

            // 4. Decodificar el resultado
            $resultado = json_decode($result->result, true);

            // 5. Evaluar respuesta
            if ($resultado['success']) {
                sistemaLog('info', 'Menú creado exitosamente', [
                    'menu_id' => $resultado['data']['id'],
                    'nombre'  => $resultado['data']['nombre'],
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400);
            }

        } catch (Exception $e) {
            sistemaLog('error', 'Error en addMenu', [
                'code'    => $e->getCode(),
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'data'    => $request->all()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }


    public function editMenu(Request $request, $id)
    {
        try {
            // 1. Obtener el JSON del campo 'json'
            $jsonData = $request->input('json');
            
            if (!$jsonData) {
                return $this->errorResponse('No se enviaron datos válidos', 400);
            }
            
            // 2. Decodificar el JSON
            $data = json_decode($jsonData, true);
            
            if (json_last_error() !== JSON_ERROR_NONE) {
                return $this->errorResponse('Formato JSON inválido', 400);
            }
            
            // 3. Validar los datos decodificados
            $validator = Validator::make($data, [
                'nombre'     => 'required|string|max:100',
                'url'        => 'nullable|string|max:255',
                'descripcion'=> 'nullable|string|max:255',
                'etiqueta'   => 'nullable|string|max:100',
                'icono'      => 'nullable|string|max:50',
                'orden'      => 'nullable|integer',
                'padre_id'   => 'nullable|integer'
            ]);
            
            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 400);
            }
            
            $validatedData = $validator->validated();
            
            // 4. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
            // 5. Llamar a la función de PostgreSQL con CAST explícito
            $result = DB::selectOne('
                SELECT seguridad.fn_menus_modificar(
                    ?::BIGINT,    -- p_id
                    ?::VARCHAR,   -- p_nombre
                    ?::VARCHAR,   -- p_url
                    ?::VARCHAR,   -- p_descripcion
                    ?::VARCHAR,   -- p_etiqueta
                    ?::VARCHAR,   -- p_icono
                    ?::INTEGER,   -- p_orden
                    ?::INTEGER,   -- p_padre_id
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                (int)$id,
                $validatedData['nombre'],
                $validatedData['url'] ?? null,
                $validatedData['descripcion'] ?? null,
                $validatedData['etiqueta'] ?? null,
                $validatedData['icono'] ?? null,
                isset($validatedData['orden']) ? (int)$validatedData['orden'] : null,
                isset($validatedData['padre_id']) ? (int)$validatedData['padre_id'] : null,
                $usuarioId ? (int)$usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);
            
            // 6. Decodificar el resultado
            $resultado = json_decode($result->result, true);
            
            // 7. Evaluar respuesta
            if ($resultado['success']) {
                sistemaLog('info', 'Menú actualizado exitosamente', [
                    'menu_id' => $id,
                    'nombre'  => $resultado['data']['nombre'],
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400);
            }
            
        } catch (Exception $e) {
            sistemaLog('error', 'Error en editMenu', [
                'code'    => $e->getCode(),
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'menu_id' => $id,
                'data'    => $request->all()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function deleteMenu(Request $request, $id)
    {
        try {
            // 1. Obtener datos del usuario autenticado
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

            // 2. Llamar a la función de PostgreSQL con CAST explícito
            $result = DB::selectOne('
                SELECT seguridad.fn_menus_eliminar(
                    ?::BIGINT,    -- p_id
                    ?::BIGINT,    -- p_usuario_id
                    ?::VARCHAR,   -- p_usuario_login
                    ?::VARCHAR,   -- p_usuario_nombre
                    ?::INET,      -- p_ip_address
                    ?::TEXT,      -- p_user_agent
                    ?::UUID       -- p_request_id
                ) as result
            ', [
                (int)$id,
                $usuarioId ? (int)$usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);

            // 3. Decodificar el resultado
            $resultado = json_decode($result->result, true);

            // 4. Evaluar respuesta
            if ($resultado['success']) {
                sistemaLog('info', 'Menú eliminado exitosamente', [
                    'menu_id' => $id,
                    'nombre'  => $resultado['data']['nombre'] ?? 'desconocido',
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            } else {
                return $this->errorResponse($resultado['message'], 400);
            }

        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteMenu', [
                'code'     => $e->getCode(),
                'message'  => $e->getMessage(),
                'line'     => $e->getLine(),
                'menu_id'  => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }



}




// public function editMenu(Request $request, $id)
// {
//     try {
//         // 1. Obtener el JSON del campo 'json' (enviado como FormData)
//         $jsonData = $request->input('json');
        
//         if (!$jsonData) {
//             return $this->errorResponse('No se enviaron datos válidos', 400);
//         }
        
//         // 2. Decodificar el JSON
//         $data = json_decode($jsonData, true);
        
//         if (json_last_error() !== JSON_ERROR_NONE) {
//             return $this->errorResponse('Formato JSON inválido', 400);
//         }
        
//         // 3. Validar los datos decodificados
//         $validator = Validator::make($data, [
//             'orden'      => 'nullable|integer',
//             'nombre'     => 'required|string|max:255',
//             'url'        => 'nullable|string|max:255',
//             'descripcion'=> 'nullable|string',
//             'etiqueta'   => 'nullable|string|max:255',
//             'icono'      => 'nullable|string|max:255',
//             'padre_id'   => 'nullable|integer'
//         ]);
        
//         if ($validator->fails()) {
//             return $this->errorResponse($validator->errors()->first(), 400);
//         }
        
//         $validatedData = $validator->validated();
        
//         // 4. Obtener datos del usuario autenticado (para auditoría)
//         $usuario = auth('api')->user();
//         $usuarioId = $usuario->id ?? null;
//         $usuarioLogin = $usuario->login_user ?? null;
//         $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
        
//         // 5. Obtener los datos ACTUALES del menú (antes de la modificación) para auditoría
//         $menuActual = DB::selectOne("
//             SELECT id, padre_id, orden, nivel, nombre, url, descripcion, etiqueta, icono
//             FROM seguridad.menus WHERE id = ?
//         ", [$id]);
        
//         if (!$menuActual) {
//             return $this->errorResponse('Menú no encontrado', 404);
//         }
        
//         // 6. Construir array de datos anteriores para auditoría
//         $datosAnteriores = [
//             'padre_id'    => $menuActual->padre_id,
//             'orden'       => $menuActual->orden,
//             'nivel'       => $menuActual->nivel,
//             'nombre'      => $menuActual->nombre,
//             'url'         => $menuActual->url,
//             'descripcion' => $menuActual->descripcion,
//             'etiqueta'    => $menuActual->etiqueta,
//             'icono'       => $menuActual->icono,
//         ];
        
//         // 7. Preparar la actualización de forma SEGURA (lista blanca de campos)
//         $allowedFields = ['padre_id', 'orden', 'nivel', 'nombre', 'url', 'descripcion', 'etiqueta', 'icono'];
//         $setParts = [];
//         $updateParams = [];
        
//         foreach ($allowedFields as $field) {
//             if (array_key_exists($field, $validatedData)) {
//                 $setParts[] = "$field = ?";
//                 $updateParams[] = $validatedData[$field];
//             }
//         }
        
//         if (empty($setParts)) {
//             return $this->errorResponse('No hay datos para actualizar', 400);
//         }
        
//         // 8. Ejecutar la actualización con SQL directo (seguro)
//         $sql = "UPDATE seguridad.menus SET " . implode(', ', $setParts) . " WHERE id = ?";
//         $updateParams[] = $id;
//         DB::update($sql, $updateParams);
        
//         // 9. Obtener los datos actualizados (con fechas formateadas)
//         $menuActualizado = DB::selectOne("
//             SELECT 
//                 id, 
//                 padre_id, 
//                 orden, 
//                 nivel, 
//                 nombre, 
//                 url, 
//                 descripcion, 
//                 etiqueta, 
//                 icono,
//                 TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
//                 TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI:SS') as updated_at
//             FROM seguridad.menus WHERE id = ?
//         ", [$id]);
        
//         // 10. Construir array de datos nuevos para auditoría
//         $datosNuevos = [
//             'padre_id'    => $menuActualizado->padre_id,
//             'orden'       => $menuActualizado->orden,
//             'nivel'       => $menuActualizado->nivel,
//             'nombre'      => $menuActualizado->nombre,
//             'url'         => $menuActualizado->url,
//             'descripcion' => $menuActualizado->descripcion,
//             'etiqueta'    => $menuActualizado->etiqueta,
//             'icono'       => $menuActualizado->icono,
//         ];
        
//         // 11. Registrar auditoría
//         $auditoria = new AuditoriaService();
//         $auditoria->registrar(
//             'seguridad.menus',
//             $id,
//             'UPDATE',
//             $datosAnteriores,
//             $datosNuevos,
//             $usuarioId,
//             $usuarioLogin,
//             $usuarioNombre,
//             $request->ip(),
//             $request->userAgent(),
//             (string) Str::uuid(),
//             'seguridad.menus'
//         );
        
//         // 12. Log de éxito
//         sistemaLog('info', 'Menú actualizado exitosamente', [
//             'menu_id' => $id,
//             'nombre'  => $menuActualizado->nombre,
//             'usuario' => $usuarioLogin ?? 'desconocido'
//         ]);
        
//         return $this->successResponse($menuActualizado, 'Se modificó con éxito');
        
//     } catch (Exception $e) {
//         sistemaLog('error', 'Error en editMenu', [
//             'message' => $e->getMessage(),
//             'line'    => $e->getLine(),
//             'menu_id' => $id
//         ]);
//         return $this->errorResponse($e->getMessage(), 500);
//     }
// }



    // public function addMenu(Request $request)
    // {
    //     DB::beginTransaction();
    //     try {
    //         $exitoso = null;

    //             // Valida los datos (puedes usar la validación de Laravel, por ejemplo)
    //             $validatedData = $this->validate($request, [
    //                 'padre_id' => 'nullable|integer',
    //                 'orden' => 'nullable|integer',
    //                 'nivel' => 'nullable|integer',
    //                 'nombre' => 'required|string|max:255',
    //                 'url' => 'nullable|string|max:255',
    //                 'descripcion' => 'nullable|string',
    //                 'etiqueta' => 'nullable|string|max:255',
    //                 'icono' => 'nullable|string|max:255',
    //             ]);


    //                 // Procesa los datos y crea un nuevo perfil            
    //                 $menu = new Menu();
    //                 $menu->padre_id = $validatedData['padre_id'] ?? null; // Si no se proporciona padre_id, se establece como null (raíz)
    //                 $menu->orden = $validatedData['orden'] ?? 0; // Si no se proporciona orden, se establece como 0
    //                 $menu->nivel = $validatedData['nivel'] ?? 0; // Si no se proporciona nivel, se establece como 0
    //                 $menu->nombre = $validatedData['nombre'];
    //                 $menu->url = $validatedData['url'];
    //                 $menu->descripcion = $validatedData['descripcion'];
    //                 $menu->etiqueta = $validatedData['etiqueta'];
    //                 $menu->icono = $validatedData['icono'];
    //                 $menu->save(); // Guarda el menu y obtén el ID

    //                 // Registrar auditoría para la creación del perfil
    //                 $auditoria = new AuditoriaService();
    //                 $usuario = auth('api')->user();
    //                 $auditoria->registrar(
    //                     'seguridad.menus',
    //                     $menu->id,
    //                     'CREATE',
    //                     null,
    //                     $menu->toArray(),
    //                     $usuario->id ?? null,
    //                     $usuario->login_user ?? null,
    //                     trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null,
    //                     $request->ip(),
    //                     $request->userAgent(),
    //                     (string) Str::uuid(),
    //                     'seguridad.menus'
    //                 );



    //                 $exitoso = Menu::orderBy('id', 'desc')->get();
    //                 // Especificar las propiedades que representan fechas en tu objeto Nota
    //                 $dateFields = ['created_at', 'updated_at'];
    //                 // Utilizar la función map para transformar y obtener una nueva colección
    //                 $exitoso->map(function ($item) use ($dateFields) {
    //                     $funciones = new Funciones();
    //                     $funciones->formatoFechaItem($item, $dateFields);
    //                     return $item;
    //                 });

    //             DB::commit();
    //             return $this->successResponse($exitoso,'Se guardó con éxito');
    //     } catch (Exception $e) {
    //             DB::rollBack();
    //             return $this->errorResponse($e->getMessage(), 500);
    //     }
    // }

    
    // public function deleteMenu(Request $request, $id){
    //     try {
    //         $data = DB::transaction(function () use ($request, $id) {
    //             // Buscar el menú por su ID
    //             $menu = Menu::findOrFail($id);
                
    //             // Verificar si el menú tiene hijos
    //             $hasChildren = Menu::where('padre_id', $menu->id)->exists();
    //             if ($hasChildren) {
    //                 throw new Exception('No se puede eliminar este menú porque tiene hijos.');
    //             }
    
    //             $menu->access()->delete();                
    //             $menu->delete();
                
    //             // Registrar auditoría para la eliminación del menú
    //             $usuario = auth('api')->user();
    //             $auditoria = new AuditoriaService();
    //             $auditoria->registrar(
    //                 'seguridad.menus',
    //                 $menu->id,
    //                 'DELETE',
    //                 $menu->toArray(),
    //                 null,
    //                 $usuario->id ?? null,
    //                 $usuario->login_user ?? null,
    //                 trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null,
    //                 $request->ip(),
    //                 $request->userAgent(),
    //                 (string) Str::uuid(),
    //                 'seguridad.menus'
    //             );
                
    //             return $menu;
    //         });
    
    //         return $this->successResponse($data, 'Se eliminó con éxito');
    //     } catch (Exception $e) {
    //         return $this->errorResponse($e->getMessage(), 400);
    //     }    
    // }


        // public function findByIdMenu($id)
    // {
    //      try {
    //         $data = null;
    //         $data = Menu::where('id', $id)
    //                 ->first(); // Limita el resultado a 1 registro            
    //         return $this->successResponse($data,'La solicitud ha tenido éxito');
            
    //     } catch (Exception $e) {
    //             return $this->errorResponse($e->getMessage(), (int)$e->getCode());
    //     }
    // }
    // public function allMenus()
    // {
    //     try {
    //         // SQL directo con ordenación jerárquica usando CTE recursivo
    //         $menus = DB::select("
    //             WITH RECURSIVE menu_tree AS (
    //                 -- Nodos raíz (padre_id = NULL)
    //                 SELECT 
    //                     m.id,
    //                     m.padre_id,
    //                     m.orden,
    //                     m.nivel,
    //                     m.nombre,
    //                     m.url,
    //                     m.descripcion,
    //                     m.etiqueta,
    //                     m.icono,
    //                     m.created_at,
    //                     m.updated_at,
    //                     m.created_by,
    //                     m.updated_by,
    //                     0 as nivel_hierarchy,
    //                     LPAD(m.orden::text, 5, '0') as path
    //                 FROM seguridad.menus m
    //                 WHERE m.padre_id IS NULL
                    
    //                 UNION ALL
                    
    //                 -- Hijos recursivos
    //                 SELECT 
    //                     m.id,
    //                     m.padre_id,
    //                     m.orden,
    //                     m.nivel,
    //                     m.nombre,
    //                     m.url,
    //                     m.descripcion,
    //                     m.etiqueta,
    //                     m.icono,
    //                     m.created_at,
    //                     m.updated_at,
    //                     m.created_by,
    //                     m.updated_by,
    //                     mt.nivel_hierarchy + 1,
    //                     mt.path || '.' || LPAD(m.orden::text, 5, '0')
    //                 FROM seguridad.menus m
    //                 INNER JOIN menu_tree mt ON m.padre_id = mt.id
    //             )
    //             SELECT 
    //                 id,
    //                 padre_id,
    //                 orden,
    //                 nivel,
    //                 nombre,
    //                 url,
    //                 descripcion,
    //                 etiqueta,
    //                 icono,
    //                 TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
    //                 TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI:SS') as updated_at,
    //                 created_by,
    //                 updated_by,
    //                 nivel_hierarchy
    //             FROM menu_tree
    //             ORDER BY path
    //         ");
            
    //         if (empty($menus)) {
    //             return $this->successResponse([], 'No hay menús registrados');
    //         }
            
    //         return $this->successResponse($menus, 'La solicitud ha tenido éxito');
            
    //     } catch (Exception $e) {
    //         sistemaLog('error', 'Error en allMenus', [
    //             'code' => $e->getCode(),
    //             'message' => $e->getMessage(),
    //             'line'    => $e->getLine()
    //         ]);
    //         return $this->errorResponse($e->getMessage(), 500);
    //     }
    // }

        // private function addMenuWithParent($menu, $menuById, &$sorted, &$processed)
    // {
    //     if (isset($processed[$menu->id])) {
    //         return;
    //     }

    //     // Si tiene un padre y aún no se ha agregado, lo agregamos primero
    //     if ($menu->parent != 0 && isset($menuById[$menu->parent]) && !isset($processed[$menu->parent])) {
    //         $this->addMenuWithParent($menuById[$menu->parent], $menuById, $sorted, $processed);
    //     }

    //     // Agregar el menú y marcarlo como procesado
    //     $sorted->push($menu);
    //     $processed[$menu->id] = true;
    // }

        // public function addMenu(Request $request)
    // {
    //     try {
    //         // 1. Validar los datos de entrada
    //         $validatedData = $this->validate($request, [
    //             'nombre'     => 'required|string|max:100',
    //             'url'        => 'nullable|string|max:255',
    //             'descripcion'=> 'nullable|string|max:255',
    //             'etiqueta'   => 'nullable|string|max:100',
    //             'icono'      => 'nullable|string|max:50',
    //             'orden'      => 'nullable|integer',
    //             'padre_id'   => 'nullable|integer'
    //         ]);

    //         // 2. Obtener datos del usuario autenticado
    //         $usuario = auth('api')->user();
    //         $usuarioId = $usuario->id ?? null;
    //         $usuarioLogin = $usuario->login_user ?? null;
    //         $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

    //         // 3. Llamar a la función de PostgreSQL
    //         $result = DB::selectOne('SELECT fn_menus_crear(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) as result', [
    //             $validatedData['nombre'],
    //             $validatedData['url'] ?? null,
    //             $validatedData['descripcion'] ?? null,
    //             $validatedData['etiqueta'] ?? null,
    //             $validatedData['icono'] ?? null,
    //             $validatedData['orden'] ?? 0,
    //             $validatedData['padre_id'] ?? null,
    //             $usuarioId,
    //             $usuarioLogin,
    //             $usuarioNombre,
    //             $request->ip(),
    //             $request->userAgent(),
    //             (string) Str::uuid()
    //         ]);

    //         // 4. Verificar que la consulta devolvió algo
    //         if (!$result || !$result->result) {
    //             sistemaLog('error', 'La función fn_menus_crear no devolvió resultado', [
    //                 'result' => $result
    //             ]);
    //             return $this->errorResponse('Error al crear menú', 500);
    //         }

    //         // 5. Decodificar el resultado
    //         $resultado = json_decode($result->result, true);

    //         // 6. Evaluar respuesta
    //         if ($resultado['success']) {
    //             // Registrar auditoría
    //             $auditoria = new AuditoriaService();
    //             $datosNuevos = [
    //                 'nombre'      => $validatedData['nombre'],
    //                 'url'         => $validatedData['url'] ?? null,
    //                 'descripcion' => $validatedData['descripcion'] ?? null,
    //                 'etiqueta'    => $validatedData['etiqueta'] ?? null,
    //                 'icono'       => $validatedData['icono'] ?? null,
    //                 'orden'       => $validatedData['orden'] ?? 0,
    //                 'padre_id'    => $validatedData['padre_id'] ?? null,
    //             ];
    //             $auditoria->registrar(
    //                 'seguridad.menus',
    //                 $resultado['data']['id'],
    //                 'INSERT',
    //                 null,
    //                 $datosNuevos,
    //                 $usuarioId,
    //                 $usuarioLogin,
    //                 $usuarioNombre,
    //                 $request->ip(),
    //                 $request->userAgent(),
    //                 (string) Str::uuid(),
    //                 'seguridad.menus'
    //             );

    //             sistemaLog('info', 'Menú creado exitosamente', [
    //                 'menu_id' => $resultado['data']['id'],
    //                 'nombre'  => $resultado['data']['nombre'],
    //                 'usuario' => $usuarioLogin ?? 'desconocido'
    //             ]);


    //             return $this->successResponse($resultado['data'], $resultado['message']);
    //         } else {
    //             return $this->errorResponse($resultado['message'], 400);
    //         }

    //     } catch (Exception $e) {
    //         sistemaLog('error', 'Error en addMenu', [
    //             'code' => $e->getCode(),
    //             'message' => $e->getMessage(),
    //             'line'    => $e->getLine(),
    //             'data'    => $request->all()
    //         ]);
    //         return $this->errorResponse($e->getMessage(), 500);
    //     }
    // }

    // public function editMenu(Request $request, $id)
    // {
    //     try {
    //         // 1. Obtener el JSON del campo 'json' (enviado como FormData)
    //         $jsonData = $request->input('json');
            
    //         if (!$jsonData) {
    //             return $this->errorResponse('No se enviaron datos válidos', 400);
    //         }
            
    //         // 2. Decodificar el JSON
    //         $data = json_decode($jsonData, true);
            
    //         if (json_last_error() !== JSON_ERROR_NONE) {
    //             return $this->errorResponse('Formato JSON inválido', 400);
    //         }
            
    //         // 3. Validar los datos decodificados
    //         $validator = Validator::make($data, [
    //             'nombre'     => 'required|string|max:100',
    //             'url'        => 'nullable|string|max:255',
    //             'descripcion'=> 'nullable|string|max:255',
    //             'etiqueta'   => 'nullable|string|max:100',
    //             'icono'      => 'nullable|string|max:50',
    //             'orden'      => 'nullable|integer',
    //             'padre_id'   => 'nullable|integer'
    //         ]);
            
    //         if ($validator->fails()) {
    //             return $this->errorResponse($validator->errors()->first(), 400);
    //         }
            
    //         $validatedData = $validator->validated();
            
    //         // 4. Obtener datos del usuario autenticado
    //         $usuario = auth('api')->user();
    //         $usuarioId = $usuario->id ?? null;
    //         $usuarioLogin = $usuario->login_user ?? null;
    //         $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
    //         // 5. Obtener datos actuales del menú para auditoría
    //         $menuActual = DB::selectOne("
    //             SELECT id, padre_id, orden, nivel, nombre, url, descripcion, etiqueta, icono
    //             FROM seguridad.menus WHERE id = ?
    //         ", [$id]);
            
    //         if (!$menuActual) {
    //             return $this->errorResponse('Menú no encontrado', 404);
    //         }
            
    //         // 6. Construir array de datos anteriores
    //         $datosAnteriores = [
    //             'nombre'      => $menuActual->nombre,
    //             'url'         => $menuActual->url,
    //             'descripcion' => $menuActual->descripcion,
    //             'etiqueta'    => $menuActual->etiqueta,
    //             'icono'       => $menuActual->icono,
    //             'orden'       => $menuActual->orden,
    //             'padre_id'    => $menuActual->padre_id,
    //         ];
            
    //         // 7. Llamar a la función de PostgreSQL
    //         $result = DB::selectOne('SELECT seguridad.fn_menus_modificar(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) as result', [
    //             $id,
    //             $validatedData['nombre'],
    //             $validatedData['url'] ?? null,
    //             $validatedData['descripcion'] ?? null,
    //             $validatedData['etiqueta'] ?? null,
    //             $validatedData['icono'] ?? null,
    //             $validatedData['orden'] ?? null,
    //             $validatedData['padre_id'] ?? null,
    //             $usuarioId,
    //             $usuarioLogin,
    //             $usuarioNombre,
    //             $request->ip(),
    //             $request->userAgent(),
    //             (string) Str::uuid()
    //         ]);
            
    //         // 8. Verificar que la consulta devolvió algo
    //         if (!$result || !$result->result) {
    //             sistemaLog('error', 'La función fn_menus_modificar no devolvió resultado', [
    //                 'result' => $result
    //             ]);
    //             return $this->errorResponse('Error al actualizar menú', 500);
    //         }
            
    //         // 9. Decodificar el resultado
    //         $resultado = json_decode($result->result, true);
            
    //         // 10. Evaluar respuesta
    //         if ($resultado['success']) {
    //             // Registrar auditoría
    //             $auditoria = new AuditoriaService();
    //             $datosNuevos = [
    //                 'nombre'      => $validatedData['nombre'],
    //                 'url'         => $validatedData['url'] ?? null,
    //                 'descripcion' => $validatedData['descripcion'] ?? null,
    //                 'etiqueta'    => $validatedData['etiqueta'] ?? null,
    //                 'icono'       => $validatedData['icono'] ?? null,
    //                 'orden'       => $validatedData['orden'] ?? null,
    //                 'padre_id'    => $validatedData['padre_id'] ?? null,
    //             ];
    //             $auditoria->registrar(
    //                 'seguridad.menus',
    //                 $id,
    //                 'UPDATE',
    //                 $datosAnteriores,
    //                 $datosNuevos,
    //                 $usuarioId,
    //                 $usuarioLogin,
    //                 $usuarioNombre,
    //                 $request->ip(),
    //                 $request->userAgent(),
    //                 (string) Str::uuid(),
    //                 'seguridad.menus'
    //             );
                
    //             sistemaLog('info', 'Menú actualizado exitosamente', [
    //                 'menu_id' => $id,
    //                 'nombre'  => $resultado['data']['nombre'],
    //                 'usuario' => $usuarioLogin ?? 'desconocido'
    //             ]);
    //             return $this->successResponse($resultado['data'], $resultado['message']);
    //         } else {
    //             return $this->errorResponse($resultado['message'], 400);
    //         }
            
    //     } catch (Exception $e) {
    //         sistemaLog('error', 'Error en editMenu', [
    //             'code' => $e->getCode(),
    //             'message' => $e->getMessage(),
    //             'line'    => $e->getLine(),
    //             'menu_id' => $id,
    //             'data'    => $request->all()
    //         ]);
    //         return $this->errorResponse($e->getMessage(), 500);
    //     }
    // }

    // public function deleteMenu(Request $request, $id)
    // {
    //     try {
    //         // 1. Obtener datos del usuario autenticado
    //         $usuario = auth('api')->user();
    //         $usuarioId = $usuario->id ?? null;
    //         $usuarioLogin = $usuario->login_user ?? null;
    //         $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;
            
    //         // 2. Llamar a la función de PostgreSQL
    //         $result = DB::selectOne('SELECT seguridad.fn_menus_eliminar(?, ?, ?, ?, ?::inet, ?, ?::uuid) as result', [
    //             $id,
    //             $usuarioId,
    //             $usuarioLogin,
    //             $usuarioNombre,
    //             $request->ip(),
    //             $request->userAgent(),
    //             (string) Str::uuid()
    //         ]);
            
    //         // 3. Verificar que la consulta devolvió algo
    //         if (!$result || !$result->result) {
    //             sistemaLog('error', 'La función fn_menus_eliminar no devolvió resultado', [
    //                 'result' => $result,
    //                 'menu_id' => $id
    //             ]);
    //             return $this->errorResponse('Error al eliminar menú', 500);
    //         }
            
    //         // 4. Decodificar el resultado
    //         $resultado = json_decode($result->result, true);
            
    //         // 5. Evaluar respuesta
    //         if ($resultado['success']) {
    //             sistemaLog('info', 'Menú eliminado exitosamente', [
    //                 'menu_id' => $id,
    //                 'nombre'  => $resultado['data']['nombre'] ?? 'N/A',
    //                 'usuario' => $usuarioLogin ?? 'desconocido'
    //             ]);
    //             return $this->successResponse($resultado['data'], $resultado['message']);
    //         } else {
    //             return $this->errorResponse($resultado['message'], 400);
    //         }
            
    //     } catch (Exception $e) {
    //         sistemaLog('error', 'Error en deleteMenu', [
    //             'code' => $e->getCode(),
    //             'message' => $e->getMessage(),
    //             'line'    => $e->getLine(),
    //             'menu_id' => $id
    //         ]);
    //         return $this->errorResponse($e->getMessage(), 500);
    //     }
    // }
