<?php

namespace App\Http\Controllers\auth;

use App\Http\Controllers\Controller;
use App\Http\Resources\ApiResponder;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use Exception;

/**
 * Tipos de usuario (seguridad.tipos_usuarios): del sistema, de la página web,
 * freelance, temporal… Es la CLASE de usuario, no sus permisos; lo que puede
 * hacer lo deciden su grupo y su perfil.
 *
 * Cada tipo puede tener vigencia (fecha de inicio y de fin): mientras no esté
 * vigente, los usuarios de ese tipo no entran al sistema. Eso lo comprueba
 * seguridad.fn_tipo_usuario_vigente, y lo aplica el middleware
 * VerificarUsuarioActivo en cada petición.
 *
 * Como en el resto del CRM, la lógica vive en las funciones PL/pgSQL
 * (seguridad.fn_tipos_usuarios_*) y aquí sólo se valida y se llama.
 */
class TipoUsuarioController extends Controller
{
    use ApiResponder;

    /**
     * Los mensajes de validación, en español.
     *
     * Laravel los trae en inglés y esta aplicación no tiene traducciones
     * instaladas, así que un código corto decía «The codigo field must be at
     * least 3 characters» a un usuario que no tiene por qué leer inglés. Las
     * funciones de base ya dan sus mensajes en español; estos son para que los
     * dos caminos digan lo mismo.
     */
    private const MENSAJES = [
        'codigo.required'            => 'El código es obligatorio',
        'codigo.min'                 => 'El código necesita al menos 3 letras',
        'codigo.max'                 => 'El código no puede pasar de 20 letras',
        'nombre.required'            => 'El nombre es obligatorio',
        'nombre.max'                 => 'El nombre no puede pasar de 60 letras',
        'descripcion.string'         => 'La descripción no es válida',
        'icono.max'                  => 'El icono no puede pasar de 40 letras',
        'color.max'                  => 'El color no puede pasar de 30 letras',
        'orden.integer'              => 'El orden tiene que ser un número entero',
        'activo.boolean'             => 'El estado tiene que ser sí o no',
        'fecha_inicio.date'          => 'La fecha de inicio no es una fecha válida',
        'fecha_fin.date'             => 'La fecha de fin no es una fecha válida',
        'fecha_fin.after_or_equal'   => 'La fecha de fin no puede ser anterior a la de inicio',
    ];

    // ****** LISTADO PAGINADO (la pantalla de administración) ****** //
    public function allTiposUsuario(Request $request)
    {
        try {
            $page    = (int) $request->input('page', 1);
            $perPage = (int) $request->input('per_page', 15);
            $search  = $request->input('search', '');

            $result = DB::selectOne('SELECT seguridad.fn_tipos_usuarios_listar_paginado(?, ?, ?) as result', [
                $page,
                $perPage,
                $search
            ]);

            $resultado = json_decode($result->result, true);

            sistemaLog('info', 'allTiposUsuario ejecutado correctamente', [
                'total_registros' => $resultado['meta']['total'] ?? 0,
                'pagina'          => $page,
                'busqueda'        => $search,
                'usuario'         => auth('api')->user()->login_user ?? 'desconocido',
                'ip'              => request()->ip()
            ]);

            return $this->successResponse($resultado, 'La solicitud ha tenido éxito');

        } catch (Exception $e) {
            sistemaLog('error', 'Error en allTiposUsuario', [
                'code'    => $e->getCode(),
                'message' => $e->getMessage(),
                'line'    => $e->getLine()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    /**
     * El catálogo para los desplegables (la ficha del usuario).
     *
     * ?inactivos=1  trae también los dados de baja; lo necesita la ficha al
     *               EDITAR, para poder mostrar el tipo que ya tiene un usuario
     *               viejo en vez de dejar el campo en blanco.
     * ?vigentes=1   deja sólo los vigentes hoy; es lo sensato al dar de alta.
     */
    public function listTiposUsuario(Request $request)
    {
        try {
            $incluirInactivos = filter_var($request->query('inactivos', false), FILTER_VALIDATE_BOOLEAN);
            $soloVigentes     = filter_var($request->query('vigentes', false), FILTER_VALIDATE_BOOLEAN);

            $result = DB::selectOne('SELECT seguridad.fn_tipos_usuarios_listar(?::BOOLEAN, ?::BOOLEAN) as result', [
                $incluirInactivos,
                $soloVigentes
            ]);

            $resultado = json_decode($result->result, true);

            if ($resultado['success']) {
                return $this->successResponse($resultado['data'], $resultado['message']);
            }
            return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en listTiposUsuario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function getTipoUsuario($id)
    {
        try {
            $result = DB::selectOne('SELECT seguridad.fn_tipos_usuarios_obtener(?) as result', [(int) $id]);
            $resultado = json_decode($result->result, true);

            if ($resultado['success']) {
                return $this->successResponse($resultado['data'], $resultado['message']);
            }
            return $this->errorResponse($resultado['message'], 404, $resultado['error_code'] ?? null);

        } catch (Exception $e) {
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function addTipoUsuario(Request $request)
    {
        try {
            // 1. Validar los datos de entrada
            //
            // Con Validator::make y no con $this->validate: éste lanza una
            // excepción que el catch de abajo convertiría en un 500, y un dato
            // mal escrito es un 422.
            $validator = Validator::make($request->all(), [
                'codigo'       => 'required|string|max:20|min:3',
                'nombre'       => 'required|string|max:60',
                'descripcion'  => 'nullable|string',
                'icono'        => 'nullable|string|max:40',
                'color'        => 'nullable|string|max:30',
                'orden'        => 'nullable|integer',
                'activo'       => 'nullable|boolean',
                'fecha_inicio' => 'nullable|date',
                // La función también lo comprueba, pero así el mensaje sale
                // antes y señalando el campo
                'fecha_fin'    => 'nullable|date|after_or_equal:fecha_inicio',
            ], self::MENSAJES);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 422);
            }

            $validatedData = $validator->validated();

            // 2. Quién lo hace, para la auditoría
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

            // 3. Llamar a la función de PostgreSQL
            $result = DB::selectOne('
                SELECT seguridad.fn_tipos_usuarios_crear(
                    ?::VARCHAR,
                    ?::VARCHAR,
                    ?::TEXT,
                    ?::VARCHAR,
                    ?::VARCHAR,
                    ?::INTEGER,
                    ?::BOOLEAN,
                    ?::DATE,
                    ?::DATE,
                    ?::BIGINT,
                    ?::VARCHAR,
                    ?::VARCHAR,
                    ?::INET,
                    ?::TEXT,
                    ?::UUID
                ) as result
            ', [
                $validatedData['codigo'],
                $validatedData['nombre'],
                $validatedData['descripcion']  ?? null,
                $validatedData['icono']        ?? null,
                $validatedData['color']        ?? null,
                $validatedData['orden']        ?? 100,
                // "false" en texto es true a secas: hay que pasarlo por filter_var
                filter_var($validatedData['activo'] ?? true, FILTER_VALIDATE_BOOLEAN) ? 'true' : 'false',
                $validatedData['fecha_inicio'] ?? null,
                $validatedData['fecha_fin']    ?? null,
                $usuarioId ? (int) $usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);

            $resultado = json_decode($result->result, true);

            if ($resultado['success']) {
                sistemaLog('info', 'Tipo de usuario creado exitosamente', [
                    'tipo_id' => $resultado['data']['id'] ?? null,
                    'codigo'  => $resultado['data']['codigo'] ?? null,
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            }
            return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en addTipoUsuario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'data'    => $request->all()
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function editTipoUsuario(Request $request, $id)
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
                'codigo'       => 'required|string|max:20|min:3',
                'nombre'       => 'required|string|max:60',
                'descripcion'  => 'nullable|string',
                'icono'        => 'nullable|string|max:40',
                'color'        => 'nullable|string|max:30',
                'orden'        => 'nullable|integer',
                'activo'       => 'nullable|boolean',
                'fecha_inicio' => 'nullable|date',
                'fecha_fin'    => 'nullable|date|after_or_equal:fecha_inicio',
            ], self::MENSAJES);

            if ($validator->fails()) {
                return $this->errorResponse($validator->errors()->first(), 400);
            }

            $validatedData = $validator->validated();

            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

            $result = DB::selectOne('
                SELECT seguridad.fn_tipos_usuarios_modificar(
                    ?::INTEGER, ?::VARCHAR, ?::VARCHAR, ?::TEXT, ?::VARCHAR, ?::VARCHAR,
                    ?::INTEGER, ?::BOOLEAN, ?::DATE, ?::DATE,
                    ?::BIGINT, ?::VARCHAR, ?::VARCHAR, ?::INET, ?::TEXT, ?::UUID
                ) as result
            ', [
                (int) $id,
                $validatedData['codigo'],
                $validatedData['nombre'],
                $validatedData['descripcion']  ?? null,
                $validatedData['icono']        ?? null,
                $validatedData['color']        ?? null,
                $validatedData['orden']        ?? null,
                array_key_exists('activo', $validatedData)
                    ? (filter_var($validatedData['activo'], FILTER_VALIDATE_BOOLEAN) ? 'true' : 'false')
                    : null,
                $validatedData['fecha_inicio'] ?? null,
                $validatedData['fecha_fin']    ?? null,
                $usuarioId ? (int) $usuarioId : null,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);

            $resultado = json_decode($result->result, true);

            if ($resultado['success']) {
                sistemaLog('info', 'Tipo de usuario actualizado exitosamente', [
                    'tipo_id' => $id,
                    'codigo'  => $resultado['data']['codigo'] ?? null,
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            }
            return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en editTipoUsuario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'tipo_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }

    public function deleteTipoUsuario(Request $request, $id)
    {
        try {
            $usuario = auth('api')->user();
            $usuarioId = $usuario->id ?? null;
            $usuarioLogin = $usuario->login_user ?? null;
            $usuarioNombre = trim(($usuario->name ?? '') . ' ' . ($usuario->surname ?? '')) ?: null;

            $result = DB::selectOne('SELECT seguridad.fn_tipos_usuarios_eliminar(?, ?, ?, ?, ?::inet, ?, ?::uuid) as result', [
                (int) $id,
                $usuarioId,
                $usuarioLogin,
                $usuarioNombre,
                $request->ip(),
                $request->userAgent(),
                (string) Str::uuid()
            ]);

            $resultado = json_decode($result->result, true);

            if ($resultado['success']) {
                sistemaLog('info', 'Tipo de usuario eliminado exitosamente', [
                    'tipo_id' => $id,
                    'usuario' => $usuarioLogin ?? 'desconocido'
                ]);
                return $this->successResponse($resultado['data'], $resultado['message']);
            }
            return $this->errorResponse($resultado['message'], 400, $resultado['error_code'] ?? null);

        } catch (Exception $e) {
            sistemaLog('error', 'Error en deleteTipoUsuario', [
                'message' => $e->getMessage(),
                'line'    => $e->getLine(),
                'tipo_id' => $id
            ]);
            return $this->errorResponse($e->getMessage(), 500);
        }
    }
}
