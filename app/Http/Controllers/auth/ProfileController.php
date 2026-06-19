<?php

namespace App\Http\Controllers\auth;

use Exception;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;


class ProfileController extends Controller
{

use ApiResponder;


public function __construct() {
    $this->middleware('auth:api',['except' =>[
        'allProfiles',
        'listProfiles',
        'findByIdProfile',
        'findByIdProfileAccess',
        'getAppMenus',        
    ]]);
}






/// 1. Construye el árbol de menú desde la base - para estar en el formato de frontend plantilla coloradmin
public function getAppMenus($perfilId)
{
    try {
        // 1. OBTENER MENÚS ACCESIBLES CON UNA SOLA CONSULTA
        $menus = DB::select(
            "WITH RECURSIVE menu_tree AS (
                -- Nodos raíz (padre_id = NULL) con acceso
                SELECT 
                    m.id,
                    m.padre_id,
                    m.orden,
                    m.nombre,
                    m.url,
                    m.icono,
                    m.etiqueta,
                    0 as nivel,
                    m.id::text as ruta,
                    LPAD(m.orden::text, 10, '0') as orden_path,
                    LOWER(REPLACE(m.nombre, ' ', '-'))::text as path
                FROM seguridad.menus m
                INNER JOIN seguridad.accesos a ON a.menu_id = m.id 
                    AND a.perfil_id = ? 
                    AND a.ejecutar = true
                WHERE m.padre_id IS NULL
                
                UNION ALL
                
                -- Hijos recursivos
                SELECT 
                    m.id,
                    m.padre_id,
                    m.orden,
                    m.nombre,
                    m.url,
                    m.icono,
                    m.etiqueta,
                    mt.nivel + 1,
                    mt.ruta || '.' || m.id::text,
                    mt.orden_path || '.' || LPAD(m.orden::text, 10, '0'),
                    (mt.path || '/' || LOWER(REPLACE(m.nombre, ' ', '-')))::text
                FROM seguridad.menus m
                INNER JOIN seguridad.accesos a ON a.menu_id = m.id 
                    AND a.perfil_id = ? 
                    AND a.ejecutar = true
                INNER JOIN menu_tree mt ON m.padre_id = mt.id
            )
            SELECT * FROM menu_tree ORDER BY orden_path",
            [$perfilId, $perfilId]
        );
        
        // 2. CONSTRUIR EL ÁRBOL RECURSIVAMENTE EN PHP
        $formattedMenus = $this->buildMenuTreeFromArray($menus);
        
        return $this->successResponse($formattedMenus, 'Menús obtenidos exitosamente');
        
    } catch (Exception $e) {
        return $this->errorResponse($e->getMessage(), 500);
    }
}
// Construye el árbol de menú desde un array plano
private function buildMenuTreeFromArray($menus, $padreId = null)
{
    $result = [];
    
    foreach ($menus as $menu) {
        // Si el padre del menú coincide con el padreId buscado
        if ($menu->padre_id == $padreId) {
            // Buscar submenús recursivamente
            $submenus = $this->buildMenuTreeFromArray($menus, $menu->id);
            
            // Construir el menú formateado
            $formattedMenu = [
                'icon' => $menu->icono,
                'title' => $menu->nombre,
                'label' => $menu->etiqueta,
                'url' => $menu->url ?? '',
                'path' => $menu->path ?? '',
            ];
            
            // Si tiene submenús, agregar caret y submenu
            if (!empty($submenus)) {
                $formattedMenu['caret'] = 'true';
                $formattedMenu['submenu'] = $submenus;
            }
            
            $result[] = $formattedMenu;
        }
    }    
    return $result;
}






/// 2. Obtener los accesos de un perfil para un programa específico 
/// (ej. perfil sistemas->crud perfil->crear,editar, eliminar en el programa de ventas)
/// Se usa en el crear perfil
public function findByProgramProfile($perfil, $programa)
{
    try {
        $vprograma = strtoupper($programa);
        
        // SQL DIRECTO - Una sola consulta con JOIN
        $data = DB::select(
            "SELECT 
                a.id,
                a.perfil_id,
                a.menu_id,
                a.ver,
                a.crear,
                a.editar,
                a.eliminar,
                a.listar,
                a.reporte,
                a.auditar,
                a.ejecutar,
                a.created_at,
                a.updated_at,
                m.id as menu_id,
                m.nombre as menu_nombre,
                m.url as menu_url,
                m.icono as menu_icono,
                m.padre_id as menu_padre_id,
                m.orden as menu_orden
             FROM seguridad.accesos a
             INNER JOIN seguridad.menus m ON m.id = a.menu_id
             WHERE a.perfil_id = ?
               AND UPPER(SPLIT_PART(m.url, '/', 2)) = ?
             ORDER BY m.id",
            [$perfil, $vprograma]
        );
        
        return $this->successResponse($data, 'La solicitud ha tenido éxito');
        
    } catch (Exception $e) {
        return $this->errorResponse($e->getMessage(), 500);
    }
}



/// 3. Obtener los accesos de un perfil para un programa específico 
/// (ej. perfil sistemas->crud perfil->crear,editar, eliminar en el programa de ventas)
/// Se usa en el ver el perfil
public function findByIdProfileAccess($id)
{
    try {
        // 1. Obtener el perfil con nombres en español
        $profile = DB::selectOne("
            SELECT 
                id,
                nombre,
                inactividad,
                activo,
                created_at,
                updated_at
            FROM seguridad.perfiles
            WHERE id = ?
        ", [$id]);

        if (!$profile) {
            return $this->successResponseEmpty(null, 'La petición se ha completado, pero su respuesta no tiene ningún contenido', 201);
        }

        // 2. Obtener los accesos con sus menús (usando los nombres reales de las columnas)
        $accesos = DB::select("
            SELECT 
                a.id,
                a.perfil_id,
                a.menu_id,
                a.ver,
                a.crear,
                a.editar,
                a.eliminar,
                a.listar,
                a.reporte,
                a.ejecutar,
                a.auditar,
                a.created_at,
                a.updated_at,
                m.id as menu_id,
                COALESCE(m.padre_id, 0) as padre_id,
                m.orden,
                m.nivel,
                m.nombre as menu_nombre,
                m.url,
                m.descripcion,
                m.etiqueta,
                m.icono,
                m.created_at as menu_created_at,
                m.updated_at as menu_updated_at
            FROM seguridad.accesos a
            INNER JOIN seguridad.menus m ON m.id = a.menu_id
            WHERE a.perfil_id = ?
            ORDER BY m.orden ASC, m.id ASC
        ", [$id]);

        // 3. Construir la estructura anidada con los nombres que espera Angular
        $profile->acceso = array_map(function($acceso) {
            return (object) [
                'id' => $acceso->id,
                'perfil_id' => $acceso->perfil_id,
                'menu_id' => $acceso->menu_id,
                'ver' => (bool) $acceso->ver,
                'crear' => (bool) $acceso->crear,
                'editar' => (bool) $acceso->editar,
                'eliminar' => (bool) $acceso->eliminar,
                'listar' => (bool) $acceso->listar,
                'reporte' => (bool) $acceso->reporte,
                'ejecutar' => (bool) $acceso->ejecutar,
                'auditar' => (bool) $acceso->auditar,
                'created_at' => $acceso->created_at,
                'updated_at' => $acceso->updated_at,
                'menu' => (object) [
                    'id' => $acceso->menu_id,
                    'padre_id' => $acceso->padre_id,
                    'orden' => $acceso->orden,
                    'nivel' => $acceso->nivel,
                    'nombre' => $acceso->menu_nombre,
                    'url' => $acceso->url,
                    'descripcion' => $acceso->descripcion,
                    'etiqueta' => $acceso->etiqueta,
                    'icono' => $acceso->icono,
                    'created_at' => $acceso->menu_created_at,
                    'updated_at' => $acceso->menu_updated_at
                ]
            ];
        }, $accesos);

        // 4. Formatear fechas del perfil (opcional, igual que lo hacías)
        $profile->created_at = $profile->created_at ? date('Y-m-d\TH:i:s.u\Z', strtotime($profile->created_at)) : null;
        $profile->updated_at = $profile->updated_at ? date('Y-m-d\TH:i:s.u\Z', strtotime($profile->updated_at)) : null;

        return $this->successResponse($profile, 'La solicitud ha tenido éxito');

    } catch (Exception $e) {
        return $this->errorResponse($e->getMessage(), 500);
    }
}




/// 4. Obtener todos los perfiles paginados
public function allProfiles(Request $request)
{
    try {
        $page     = (int) $request->input('page', 1);
        $perPage  = (int) $request->input('per_page', 15);
        $search   = $request->input('search', '');
        
        $result = DB::selectOne('SELECT seguridad.fn_perfiles_listar_paginado(?, ?, ?) as result', [
            $page,
            $perPage,
            $search
        ]);
        
        $resultado = json_decode($result->result, true);
        
        sistemaLog('info', 'allProfiles ejecutado correctamente', [
            'total_registros' => $resultado['meta']['total'] ?? 0,
            'pagina'          => $page,
            'busqueda'        => $search,
            'usuario'         => auth('api')->user()->login_user ?? 'desconocido',
            'ip'              => request()->ip()
        ]);
        
        return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        
    } catch (Exception $e) {
        sistemaLog('error', 'Error en allProfiles', [
            'code'    => $e->getCode(),
            'message' => $e->getMessage(),
            'line'    => $e->getLine()
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
}


public function listProfiles(Request $request)
{
    try {
        $page     = (int) $request->input('page', 1);
        $perPage  = (int) $request->input('per_page', 15);
        $search   = $request->input('search', '');
        
        $result = DB::selectOne('SELECT seguridad.fn_perfiles_listar_paginado_activos(?, ?, ?) as result', [
            $page,
            $perPage,
            $search
        ]);
        
        $resultado = json_decode($result->result, true);
        
        sistemaLog('info', 'allProfiles ejecutado correctamente', [
            'total_registros' => $resultado['meta']['total'] ?? 0,
            'pagina'          => $page,
            'busqueda'        => $search,
            'usuario'         => auth('api')->user()->login_user ?? 'desconocido',
            'ip'              => request()->ip()
        ]);
        
        return $this->successResponse($resultado, 'La solicitud ha tenido éxito');
        
    } catch (Exception $e) {
        sistemaLog('error', 'Error en allProfiles', [
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




public function addProfile(Request $request)
{
    try {
        // 1. Validar los datos de entrada
        $validatedData = $this->validate($request, [
            'nombre' => 'required|string|max:100',
            'inactividad' => 'required|integer',
            'activo' => 'required|boolean',
            'acceso' => 'required|array|min:1', // Al menos un acceso
        ]);

        // 2. Obtener datos del usuario autenticado (para pasar a PostgreSQL)
        $usuario = auth('api')->user();
        $usuarioId = $usuario->id ?? null;
        $usuarioLogin = $usuario->login_user ?? null;
        $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

        // 3. Preparar el JSON de accesos en el formato que espera la función PostgreSQL
        $accesosArray = array_map(function($acceso) {
            return [
                'menu_id'  => (int)($acceso['menu_id'] ?? null),
                'ver'      => (bool)($acceso['ver'] ?? false),
                'crear'    => (bool)($acceso['crear'] ?? false),
                'editar'   => (bool)($acceso['editar'] ?? false),
                'eliminar' => (bool)($acceso['eliminar'] ?? false),
                'listar'   => (bool)($acceso['listar'] ?? false),
                'reporte'  => (bool)($acceso['reporte'] ?? false),
                'ejecutar' => (bool)($acceso['ejecutar'] ?? false),
                'auditar'  => (bool)($acceso['auditar'] ?? false),
            ];
        }, $validatedData['acceso']);
        
        $accesosJson = json_encode($accesosArray);
        
        // 4. Convertir el booleano a string para PostgreSQL
        $activoPostgres = $validatedData['activo'] ? 'true' : 'false';

        // 5. Llamar a la función de PostgreSQL con CAST explícito
        $result = DB::selectOne('
            SELECT seguridad.fn_perfiles_crear(
                ?::VARCHAR,          -- p_nombre
                ?::INTEGER,          -- p_inactividad
                ?::BOOLEAN,          -- p_activo
                ?::JSONB,            -- p_accesos
                ?::BIGINT,           -- p_usuario_id
                ?::VARCHAR,          -- p_usuario_login
                ?::VARCHAR,          -- p_usuario_nombre
                ?::INET,             -- p_ip_address
                ?::TEXT,             -- p_user_agent
                ?::UUID              -- p_request_id
            ) as result
        ', [
            $validatedData['nombre'],
            (int)$validatedData['inactividad'],
            $activoPostgres,
            $accesosJson,
            $usuarioId ? (int)$usuarioId : null,
            $usuarioLogin,
            $usuarioNombre,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid()
        ]);

        // 6. Decodificar el resultado JSON devuelto por la función
        $resultado = json_decode($result->result, true);

        // 7. Evaluar respuesta
        if ($resultado['success']) {
            sistemaLog('info', 'Perfil creado exitosamente', [
                'perfil_id' => $resultado['data']['id'],
                'nombre'    => $resultado['data']['nombre'],
                'usuario'   => $usuarioLogin ?? 'desconocido'
            ]);
            return $this->successResponse($resultado['data'], $resultado['message']);
        } else {
            return $this->errorResponse($resultado['message'], 400);
        }

    } catch (Exception $e) {
        sistemaLog('error', 'Error en addProfile', [
            'code'    => $e->getCode(),
            'message' => $e->getMessage(),
            'line'    => $e->getLine(),
            'data'    => $request->all()
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
}



public function editProfile(Request $request, $id)
{
    try {
        // 1. Obtener el JSON del campo 'json' (enviado como FormData)
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
            'nombre' => 'required|string|max:100',
            'inactividad' => 'required|integer',
            'activo' => 'required|boolean',
            'acceso' => 'required|array',
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
        
        // 5. Preparar el JSON de accesos (asegurar que sea un objeto JSON válido)
        $accesosArray = array_map(function($acceso) {
            return [
                'menu_id'  => (int)($acceso['menu_id'] ?? null),
                'ver'      => (bool)($acceso['ver'] ?? false),
                'crear'    => (bool)($acceso['crear'] ?? false),
                'editar'   => (bool)($acceso['editar'] ?? false),
                'eliminar' => (bool)($acceso['eliminar'] ?? false),
                'listar'   => (bool)($acceso['listar'] ?? false),
                'reporte'  => (bool)($acceso['reporte'] ?? false),
                'ejecutar' => (bool)($acceso['ejecutar'] ?? false),
                'auditar'  => (bool)($acceso['auditar'] ?? false),
            ];
        }, $validatedData['acceso']);
        
        $accesosJson = json_encode($accesosArray);
        
        // 6. Convertir el booleano a string para PostgreSQL
        $activoPostgres = $validatedData['activo'] ? 'true' : 'false';
        
        // 7. Llamar a la función de PostgreSQL con CAST explícito
        $result = DB::selectOne('
            SELECT seguridad.fn_perfiles_modificar(
                ?::BIGINT,           -- p_id
                ?::VARCHAR,          -- p_nombre  
                ?::INTEGER,          -- p_inactividad
                ?::BOOLEAN,          -- p_activo
                ?::JSONB,            -- p_accesos
                ?::BIGINT,           -- p_usuario_id
                ?::VARCHAR,          -- p_usuario_login
                ?::VARCHAR,          -- p_usuario_nombre
                ?::INET,             -- p_ip_address
                ?::TEXT,             -- p_user_agent
                ?::UUID              -- p_request_id
            ) as result
        ', [
            (int)$id,
            $validatedData['nombre'],
            (int)$validatedData['inactividad'],
            $activoPostgres,
            $accesosJson,
            $usuarioId ? (int)$usuarioId : null,
            $usuarioLogin,
            $usuarioNombre,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid()
        ]);
        
        $resultado = json_decode($result->result, true);
        
        // 8. Evaluar respuesta
        if ($resultado['success']) {
            sistemaLog('info', 'Perfil actualizado exitosamente', [
                'perfil_id' => $id,
                'nombre'    => $resultado['data']['nombre'] ?? $validatedData['nombre'],
                'usuario'   => $usuarioLogin ?? 'desconocido'
            ]);
            return $this->successResponse($resultado['data'], $resultado['message']);
        } else {
            return $this->errorResponse($resultado['message'], 400);
        }
        
    } catch (Exception $e) {
        sistemaLog('error', 'Error en editProfile', [
            'code'    => $e->getCode(),
            'message' => $e->getMessage(),
            'line'    => $e->getLine(),
            'data'    => $request->all()
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
}



public function deleteProfile(Request $request, $id)
{
    try {
        // 1. Obtener datos del usuario autenticado
        $usuario = auth('api')->user();
        $usuarioId = $usuario->id ?? null;
        $usuarioLogin = $usuario->login_user ?? null;
        $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

        // 2. Llamar a la función de PostgreSQL con CAST explícito
        $result = DB::selectOne('
            SELECT seguridad.fn_perfiles_eliminar(
                ?::BIGINT,           -- p_id
                ?::BIGINT,           -- p_usuario_id
                ?::VARCHAR,          -- p_usuario_login
                ?::VARCHAR,          -- p_usuario_nombre
                ?::INET,             -- p_ip_address
                ?::TEXT,             -- p_user_agent
                ?::UUID              -- p_request_id
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

        // 3. Decodificar el resultado JSON devuelto por la función
        $resultado = json_decode($result->result, true);

        // 4. Evaluar respuesta
        if ($resultado['success']) {
            sistemaLog('info', 'Perfil eliminado exitosamente', [
                'perfil_id' => $id,
                'nombre'    => $resultado['data']['nombre'] ?? 'desconocido',
                'usuario'   => $usuarioLogin ?? 'desconocido'
            ]);
            return $this->successResponse($resultado['data'], $resultado['message']);
        } else {
            return $this->errorResponse($resultado['message'], 400);
        }

    } catch (Exception $e) {
        sistemaLog('error', 'Error en deleteProfile', [
            'code'    => $e->getCode(),
            'message' => $e->getMessage(),
            'line'    => $e->getLine(),
            'perfil_id' => $id
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
}





public function clonProfile(Request $request)
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
        
        // 3. Validar los datos
        $validator = Validator::make($data, [
            'nombre' => 'required|string|max:100',
            'inactividad' => 'required|integer',
            'activo' => 'required|boolean',
            'acceso' => 'required|array|min:1', // Al menos un acceso
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
        
        // 5. Preparar el JSON de accesos en el formato que espera la función PostgreSQL
        $accesosArray = array_map(function($acceso) {
            return [
                'menu_id'  => (int)($acceso['menu_id'] ?? null),
                'ver'      => (bool)($acceso['ver'] ?? false),
                'crear'    => (bool)($acceso['crear'] ?? false),
                'editar'   => (bool)($acceso['editar'] ?? false),
                'eliminar' => (bool)($acceso['eliminar'] ?? false),
                'listar'   => (bool)($acceso['listar'] ?? false),
                'reporte'  => (bool)($acceso['reporte'] ?? false),
                'ejecutar' => (bool)($acceso['ejecutar'] ?? false),
                'auditar'  => (bool)($acceso['auditar'] ?? false),
            ];
        }, $validatedData['acceso']);
        
        $accesosJson = json_encode($accesosArray);
        
        // 6. Convertir el booleano a string para PostgreSQL
        $activoPostgres = $validatedData['activo'] ? 'true' : 'false';
        
        // 7. Llamar a la función de PostgreSQL con CAST explícito (la misma de crear)
        $result = DB::selectOne('
            SELECT seguridad.fn_perfiles_crear(
                ?::VARCHAR,          -- p_nombre
                ?::INTEGER,          -- p_inactividad
                ?::BOOLEAN,          -- p_activo
                ?::JSONB,            -- p_accesos
                ?::BIGINT,           -- p_usuario_id
                ?::VARCHAR,          -- p_usuario_login
                ?::VARCHAR,          -- p_usuario_nombre
                ?::INET,             -- p_ip_address
                ?::TEXT,             -- p_user_agent
                ?::UUID              -- p_request_id
            ) as result
        ', [
            $validatedData['nombre'],
            (int)$validatedData['inactividad'],
            $activoPostgres,
            $accesosJson,
            $usuarioId ? (int)$usuarioId : null,
            $usuarioLogin,
            $usuarioNombre,
            $request->ip(),
            $request->userAgent(),
            (string) Str::uuid()
        ]);
        
        // 8. Decodificar el resultado JSON devuelto por la función
        $resultado = json_decode($result->result, true);
        
        // 9. Evaluar respuesta
        if ($resultado['success']) {
            sistemaLog('info', 'Perfil clonado exitosamente', [
                'perfil_id' => $resultado['data']['id'],
                'nombre'    => $resultado['data']['nombre'],
                'usuario'   => $usuarioLogin ?? 'desconocido'
            ]);
            return $this->successResponse($resultado['data'], 'Perfil clonado exitosamente');
        } else {
            return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
        }
        
    } catch (Exception $e) {
        sistemaLog('error', 'Error en clonProfile', [
            'code'    => $e->getCode(),
            'message' => $e->getMessage(),
            'line'    => $e->getLine(),
            'data'    => $request->all()
        ]);
        return $this->errorResponse($e->getMessage(), 500);
    }
}




}


// public function allProfiles2(Request $request)
// {
//     try {
//         $perPage = $request->input('per_page', 15);
//         $page = $request->input('page', 1);
//         $search = $request->input('search', ''); // término de búsqueda
//         $offset = ($page - 1) * $perPage;

//         // Construir la consulta base
//         $query = DB::table('seguridad.perfiles');

//         // Aplicar filtro de búsqueda si existe
//         if (!empty($search)) {
//             $query->where(function($q) use ($search) {
//                 $q->where('nombre', 'ILIKE', "%{$search}%")
//                   ->orWhere('id', 'ILIKE', "%{$search}%");
//                   // Puedes agregar más campos si lo deseas (ej. 'inactividad' si es texto)
//             });
//         }

//         // Contar total de registros (con filtro)
//         $total = $query->count();

//         // Obtener datos paginados
//         $data = $query
//             ->select(
//                 'id',
//                 'nombre',
//                 'inactividad',
//                 'activo',
//                 DB::raw("TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at_formateado"),
//                 DB::raw("TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI:SS') as updated_at_formateado")
//             )
//             ->orderBy('id', 'asc')
//             ->skip($offset)
//             ->take($perPage)
//             ->get();

//         $response = [
//             'data' => $data,
//             'meta' => [
//                 'total' => $total,
//                 'per_page' => (int) $perPage,
//                 'current_page' => (int) $page,
//                 'last_page' => ceil($total / $perPage),
//             ]
//         ];

//         sistemaLog('info', 'allProfiles ejecutado correctamente', [
//             'total_registros' => $total,
//             'pagina' => $page,
//             'busqueda' => $search,
//             'usuario' => auth('api')->user()->login_user ?? 'desconocido',
//             'ip' => request()->ip()
//         ]);

//         return $this->successResponse($response, 'La solicitud ha tenido éxito');

//     } catch (Exception $e) {
//         sistemaLog('error', 'Error en allProfiles', [
//             'code' => $e->getCode(),
//             'message' => $e->getMessage(),
//             'line' => $e->getLine()
//         ]);
//         return $this->errorResponse($e->getMessage(), 500);
//     }
// }

// public function allProfiles(Request $request)
// {
//     try {
//         $perPage = (int) $request->input('per_page', 15);
//         $page    = (int) $request->input('page', 1);
//         $search  = $request->input('search', '');
//         $offset  = ($page - 1) * $perPage;

//         // ---------- 1. Contar total (con filtro) ----------
//         $totalSql = "SELECT COUNT(*) as total FROM seguridad.perfiles";
//         $totalParams = [];

//         if (!empty($search)) {
//             $totalSql .= " WHERE nombre ILIKE ? OR id::text ILIKE ?";
//             $totalParams = ["%{$search}%", "%{$search}%"];
//         }

//         $total = DB::selectOne($totalSql, $totalParams)->total;

//         // ---------- 2. Consulta paginada (con filtro) ----------
//         $dataSql = "
//             SELECT 
//                 id,
//                 nombre,
//                 inactividad,
//                 activo,
//                 created_by,
//                 updated_by,
//                 TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
//                 TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI:SS') as updated_at
//             FROM seguridad.perfiles
//         ";

//         $dataParams = [];

//         if (!empty($search)) {
//             $dataSql .= " WHERE nombre ILIKE ? OR id::text ILIKE ?";
//             $dataParams = ["%{$search}%", "%{$search}%"];
//         }

//         $dataSql .= " ORDER BY id DESC LIMIT ? OFFSET ?";
//         $dataParams = array_merge($dataParams, [$perPage, $offset]);

//         $data = DB::select($dataSql, $dataParams);

//         // ---------- 3. Respuesta ----------
//         $response = [
//             'data' => $data,
//             'meta' => [
//                 'total'        => $total,
//                 'per_page'     => $perPage,
//                 'current_page' => $page,
//                 'last_page'    => ceil($total / $perPage),
//             ]
//         ];

//         sistemaLog('info', 'allProfiles ejecutado correctamente', [
//             'total_registros' => $total,
//             'pagina'          => $page,
//             'busqueda'        => $search,
//             'usuario'         => auth('api')->user()->login_user ?? 'desconocido',
//             'ip'              => request()->ip()
//         ]);

//         return $this->successResponse($response, 'La solicitud ha tenido éxito');

//     } catch (Exception $e) {
//         sistemaLog('error', 'Error en allProfiles', [
//             'code'    => $e->getCode(),
//             'message' => $e->getMessage(),
//             'line'    => $e->getLine()
//         ]);
//         return $this->errorResponse($e->getMessage(), 500);
//     }
// }


// public function allProfiles_sin_paginacion()
// {
//     try {

//         $data = DB::select("
//             SELECT 
//                 id,
//                 nombre,
//                 inactividad,
//                 activo,
//                 TO_CHAR(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at_formateado,
//                 TO_CHAR(updated_at, 'YYYY-MM-DD HH24:MI:SS') as updated_at_formateado
//             FROM seguridad.perfiles
//             ORDER BY id DESC
//         ");

//         sistemaLog('info', 'ALLProfiles ejecutado correctamente', [
//             'total_registros' => count($data),
//             'usuario' => auth('api')->user()->login_user ?? 'desconocido',
//             'ip' => request()->ip()
//         ]);

//         return $this->successResponse($data, 'La solicitud ha tenido éxito');
        
//     } catch (Exception $e) {

//         sistemaLog('error', 'Error en ALLProfiles', [
//             'code' => $e->getCode(),
//             'message' => $e->getMessage(),
//             'line' => $e->getLine()
//         ]);

//         return $this->errorResponse($e->getMessage(), 500);
//     }
// }


// public function addProfile(Request $request)
// {
//     try {
//         // 1. Validar los datos de entrada
//         $validatedData = $this->validate($request, [
//             'nombre' => 'required|string|max:100',
//             'inactividad' => 'required|integer',
//             'activo' => 'required|boolean',
//             'acceso' => 'required|array',
//         ]);

//         // 2. Obtener datos del usuario autenticado (para auditoría)
//         $usuario = auth('api')->user();
//         $usuarioId = $usuario->id ?? null;
//         $usuarioLogin = $usuario->login_user ?? null;
//         $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

//         // 3. Preparar el JSON de accesos en el formato que espera la función PostgreSQL
//         $accesosJson = json_encode(array_map(function($acceso) {
//             return [
//                 'menu_id'  => $acceso['menu_id'] ?? null,
//                 'ver'      => $acceso['ver'] ?? false,
//                 'crear'    => $acceso['crear'] ?? false,
//                 'editar'   => $acceso['editar'] ?? false,
//                 'eliminar' => $acceso['eliminar'] ?? false,
//                 'listar'   => $acceso['listar'] ?? false,
//                 'reporte'  => $acceso['reporte'] ?? false,
//                 'ejecutar' => $acceso['ejecutar'] ?? false,
//                 'auditar'  => $acceso['auditar'] ?? false,
//             ];
//         }, $validatedData['acceso']));

//         // 4. Llamar a la función de PostgreSQL
//         $result = DB::selectOne('SELECT seguridad.fn_perfiles_crear(?, ?, ?, ?, ?, ?, ?, ?, ?, ?) as result', [
//             $validatedData['nombre'],
//             $validatedData['inactividad'],
//             $validatedData['activo'],
//             $accesosJson,
//             $usuarioId,
//             $usuarioLogin,
//             $usuarioNombre,
//             $request->ip(),
//             $request->userAgent(),
//             (string) Str::uuid()
//         ]);

//         // 5. Decodificar el resultado JSON devuelto por la función
//         $resultado = json_decode($result->result, true);

//         // 6. Evaluar respuesta
//         if ($resultado['success']) {
//             // --- Registrar auditoría usando el servicio (desde Laravel) ---
//             $auditoria = new AuditoriaService();
//             $datosNuevos = [
//                 'nombre'      => $validatedData['nombre'],
//                 'inactividad' => $validatedData['inactividad'],
//                 'activo'      => $validatedData['activo'],
//                 'acceso'      => $validatedData['acceso'], // array original
//             ];
//             $auditoria->registrar(
//                 'seguridad.perfiles',
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
//                 'seguridad.perfiles'
//             );
//             // ------------------------------------------------------------

//             sistemaLog('info', 'Perfil creado exitosamente', [
//                 'perfil_id' => $resultado['data']['id'],
//                 'nombre'    => $resultado['data']['nombre'],
//                 'usuario'   => $usuarioLogin ?? 'desconocido'
//             ]);
//             return $this->successResponse($resultado['data'], $resultado['message']);
//         } else {
//             return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
//         }

//     } catch (Exception $e) {
//         sistemaLog('error', 'Error en addProfile', [
//             'code'    => $e->getCode(),
//             'message' => $e->getMessage(),
//             'line'    => $e->getLine(),
//             'data'    => $request->all()
//         ]);
//         return $this->errorResponse($e->getMessage(), 500);
//     }
// }
// public function deleteProfile(Request $request, $id)
// {
//     try {
//         // 1. Obtener datos del usuario autenticado
//         $usuario = auth('api')->user();
//         $usuarioId = $usuario->id ?? null;
//         $usuarioLogin = $usuario->login_user ?? $usuario->email ?? 'anonimo';
//         $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: $usuarioLogin;

//         // 2. Obtener los datos ACTUALES del perfil (antes de eliminar)
//         $perfilActual = DB::selectOne("
//             SELECT id, nombre, inactividad, activo
//             FROM seguridad.perfiles WHERE id = ?
//         ", [$id]);

//         if (!$perfilActual) {
//             return $this->errorResponse('Perfil no encontrado', 404);
//         }

//         // 3. Obtener los accesos actuales (mismo formato que en editProfile)
//         $accesosActuales = DB::select("
//             SELECT 
//                 a.menu_id,
//                 a.ver,
//                 a.crear,
//                 a.editar,
//                 a.eliminar,
//                 a.listar,
//                 a.reporte,
//                 a.ejecutar,
//                 a.auditar
//             FROM seguridad.accesos a
//             WHERE a.perfil_id = ?
//             ORDER BY a.menu_id
//         ", [$id]);

//         // 4. Construir el array de accesos en el formato esperado por auditoría (array de arrays, no objetos)
//         $accesosArray = array_map(function($acceso) {
//             return [
//                 'menu_id'   => $acceso->menu_id,
//                 'ver'       => (bool) $acceso->ver,
//                 'crear'     => (bool) $acceso->crear,
//                 'editar'    => (bool) $acceso->editar,
//                 'eliminar'  => (bool) $acceso->eliminar,
//                 'listar'    => (bool) $acceso->listar,
//                 'reporte'   => (bool) $acceso->reporte,
//                 'ejecutar'  => (bool) $acceso->ejecutar,
//                 'auditar'   => (bool) $acceso->auditar,
//             ];
//         }, $accesosActuales);

//         // 5. Construir los datos anteriores (igual estructura que en addProfile/editProfile)
//         $datosAnteriores = [
//             'nombre'      => $perfilActual->nombre,
//             'inactividad' => $perfilActual->inactividad,
//             'activo'      => $perfilActual->activo,
//             'acceso'      => $accesosArray,
//         ];

//         // 6. Llamar a la función de PostgreSQL (que solo elimina, no audita)
//         $result = DB::selectOne('SELECT seguridad.fn_perfiles_eliminar(?, ?, ?, ?, ?::inet, ?, ?::uuid) as result', [
//             $id,
//             $usuarioId,
//             $usuarioLogin,
//             $usuarioNombre,
//             $request->ip(),
//             $request->userAgent(),
//             (string) Str::uuid()
//         ]);

//         $resultado = json_decode($result->result, true);

//         if (!$resultado['success']) {
//             return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
//         }

//         // 7. Registrar auditoría desde Laravel (DELETE)
//         $auditoria = new AuditoriaService();
//         $auditoria->registrar(
//             'seguridad.perfiles',
//             $id,
//             'DELETE',
//             $datosAnteriores,   // datos anteriores (el perfil completo con accesos)
//             null,               // no hay datos nuevos
//             $usuarioId,
//             $usuarioLogin,
//             $usuarioNombre,
//             $request->ip(),
//             $request->userAgent(),
//             (string) Str::uuid(),
//             'seguridad.perfiles'
//         );

//         // 8. Log de éxito
//         sistemaLog('info', 'Perfil eliminado exitosamente', [
//             'perfil_id' => $id,
//             'nombre'    => $perfilActual->nombre,
//             'usuario'   => $usuarioLogin
//         ]);

//         return $this->successResponse($resultado['data'], $resultado['message']);

//     } catch (Exception $e) {
//         sistemaLog('error', 'Error en deleteProfile', [
//             'code'    => $e->getCode(),
//             'message' => $e->getMessage(),
//             'line'    => $e->getLine(),
//             'perfil_id' => $id
//         ]);
//         return $this->errorResponse($e->getMessage(), 500);
//     }
// }

// public function clonProfile(Request $request)
// {
//     try {
//         // 1. Obtener el JSON del campo 'json'
//         $jsonData = $request->input('json');
        
//         if (!$jsonData) {
//             return $this->errorResponse('No se enviaron datos válidos', 400);
//         }
        
//         // 2. Decodificar el JSON
//         $data = json_decode($jsonData, true);
        
//         if (json_last_error() !== JSON_ERROR_NONE) {
//             return $this->errorResponse('Formato JSON inválido', 400);
//         }
        
//         // 3. Validar los datos
//         $validator = Validator::make($data, [
//             'nombre' => 'required|string|max:100',
//             'inactividad' => 'required|integer',
//             'activo' => 'required|boolean',
//             'acceso' => 'required|array',
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
        
//         // 5. Preparar el JSON de accesos (los accesos ya vienen con campos en español)
//         $accesosJson = json_encode(array_map(function($acceso) {
//             return [
//                 'menu_id'  => $acceso['menu_id'] ?? null,
//                 'ver'      => $acceso['ver'] ?? false,
//                 'crear'    => $acceso['crear'] ?? false,
//                 'editar'   => $acceso['editar'] ?? false,
//                 'eliminar' => $acceso['eliminar'] ?? false,
//                 'listar'   => $acceso['listar'] ?? false,
//                 'reporte'  => $acceso['reporte'] ?? false,
//                 'ejecutar' => $acceso['ejecutar'] ?? false,
//                 'auditar'  => $acceso['auditar'] ?? false,
//             ];
//         }, $validatedData['acceso']));
        
//         // 6. Llamar a la función de PostgreSQL (la misma de crear)
//         $result = DB::selectOne('SELECT seguridad.fn_perfiles_crear(?, ?, ?, ?, ?, ?, ?, ?, ?, ?) as result', [
//             $validatedData['nombre'],
//             $validatedData['inactividad'],
//             $validatedData['activo'],
//             $accesosJson,
//             $usuarioId,
//             $usuarioLogin,
//             $usuarioNombre,
//             $request->ip(),
//             $request->userAgent(),
//             (string) Str::uuid()
//         ]);
        
//         $resultado = json_decode($result->result, true);
        
//         if ($resultado['success']) {
//             // Registrar auditoría
//             $auditoria = new AuditoriaService();
//             $datosNuevos = [
//                 'nombre'      => $validatedData['nombre'],
//                 'inactividad' => $validatedData['inactividad'],
//                 'activo'      => $validatedData['activo'],
//                 'acceso'      => $validatedData['acceso'],
//             ];
//             $auditoria->registrar(
//                 'seguridad.perfiles',
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
//                 'seguridad.perfiles'
//             );
            
//             sistemaLog('info', 'Perfil clonado exitosamente', [
//                 'perfil_id' => $resultado['data']['id'],
//                 'nombre'    => $resultado['data']['nombre'],
//                 'usuario'   => $usuarioLogin ?? 'desconocido'
//             ]);
//             return $this->successResponse($resultado['data'], 'Perfil clonado exitosamente');
//         } else {
//             return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);
//         }
        
//     } catch (Exception $e) {
//         sistemaLog('error', 'Error en clonProfile', [
//             'code'    => $e->getCode(),
//             'message' => $e->getMessage(),
//             'line'    => $e->getLine(),
//             'data'    => $request->all()
//         ]);
//         return $this->errorResponse($e->getMessage(), 500);
//     }
// }