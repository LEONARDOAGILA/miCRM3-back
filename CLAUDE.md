# miCRM3 — API (Laravel)

Laravel 10 sobre PHP 8.1, PostgreSQL. Es la API que consume `miCRM3-front`.

## Cómo se levanta

`php artisan serve --host=0.0.0.0 --port=8009` — no hay Apache delante, y en el
`.env` `APP_URL` apunta a ese puerto. Si el 8009 no responde, **hay que
relanzarlo**; no matar `php.exe` en bloque, que se lleva por delante otras cosas.

Es de un solo proceso: cada petición carga Laravel entero (~250 ms). Cuando algo
va lento, medir la consulta antes de culpar a la base — normalmente es el
arranque, no el SQL.

Aparte hay que tener corriendo `php artisan websockets:serve` (Pusher local en el
6001) para las notificaciones.

## Base de datos

`crm3` en `192.168.2.173:5432`, usuario `postgres`. Es una **dirección de red
local**: desde fuera de esa red no se llega sin VPN.

La lógica de negocio pesada vive en funciones PL/pgSQL que devuelven `jsonb`, no
en PHP. Los controladores casi siempre sólo validan y llaman a una función.

Las funciones se guardan en `database/sql/`, un archivo por cambio con la fecha
delante (`2026-09-28_ventas_whatsapp.sql`). Reglas:

- Siempre `CREATE OR REPLACE`, para poder volver a aplicar el archivo sin romper nada.
- `SECURITY DEFINER SET search_path` en las que tocan varios esquemas.
- Devolver `jsonb_build_object('success', …, 'message', …, 'data', …)` y capturar
  `WHEN OTHERS` para que un error no llegue al cliente como un 500 pelado.
- Se aplican con `psql -h 192.168.2.173 -U postgres -d crm3 -f <archivo>`.
  **No son migraciones de Laravel**; `artisan migrate` no las conoce.

## Cosas que no se adivinan leyendo el código

- El trait de respuestas es `App\Http\Resources\ApiResponder`, **no**
  `App\Traits\ApiResponder`. No existe la carpeta `app/Traits`.
- **No está activada la extensión GD.** Nada de generar ni redimensionar
  imágenes en PHP; lo que haya que dibujar (marcas de agua, miniaturas) se hace
  en el navegador.
- Un **prefijo de ruta nuevo hay que añadirlo a `config/cors.php`**, o Angular
  sólo dirá «Error en el servidor» sin más pista.
- El login **muere a las 44 sesiones activas**. Toda prueba automatizada tiene
  que cerrar la suya con `POST auth/logout` al terminar.
- Los booleanos que llegan por JSON se leen con
  `filter_var($x, FILTER_VALIDATE_BOOLEAN)`: `"false"` en texto es `true` a secas.

## Datos de prueba

Los clientes de prueba van marcados con `CARGA DE PRUEBA%` en el nombre y se
quitan con `database/sql/limpiar-carga.sql`.

Al limpiar, **borrar sólo las filas propias por id**. Leonardo prueba en paralelo
sobre la misma base: un `DELETE` de tabla entera se lleva su trabajo.

## El escucha de WhatsApp

`../miCRM3-wa` (servicio Node aparte) manda cada mensaje a
`POST ventas/whatsapp/mensaje`, autenticado con la cabecera `X-WA-TOKEN`, que
tiene que coincidir con `WHATSAPP_TOKEN` del `.env`. No usa el login normal.
