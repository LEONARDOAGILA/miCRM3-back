<#
  COPIAR LOS ADJUNTOS DE UNA GESTIÓN AL PORTAPAPELES

  Se engancha al protocolo micrm3: y hace lo único que el navegador no puede
  hacer: poner FICHEROS en el portapapeles de Windows, de forma que al pulsar
  Ctrl+V en WhatsApp se adjunten de verdad.

  Por qué hace falta un intermediario: una página web sólo puede copiar texto,
  HTML, PNG y SVG —lo demás lo bloquea el navegador—, así que un PDF o un Word
  no hay manera de pasarlos por ahí. Con Set-Clipboard -Path se deja la lista
  de ficheros igual que si se hubieran copiado desde el Explorador.

  Abre además la conversación, y por eso el CRM lanza UN solo protocolo y no
  dos: Chrome sólo deja abrir una aplicación externa durante unos segundos
  después del clic, y para cuando se ha guardado la gestión y subido los
  archivos, ese permiso ya se ha agotado. El primer aviso llega; el segundo,
  no. Así que el navegador avisa una vez y aquí se hace el resto en orden:
  copiar, abrir el chat, esperar a que esté delante y pegar.

  Uso (lo llama Windows, no se ejecuta a mano):
      powershell -File copiar-archivos.ps1 "micrm3://enviar?ids=12,13&tel=593987654321&texto=Hola" -Api http://servidor:8009/

  Sólo copiar, sin abrir nada:
      powershell -File copiar-archivos.ps1 "micrm3://copiar?ids=12" -Api http://... -SinPegar
#>
param(
    [Parameter(Position = 0)] [string] $Url = '',

    # De dónde se bajan los ficheros. Lo pone el instalador y NO se acepta
    # desde la url a propósito: si viniera en el enlace, cualquier página que
    # alguien abriera podría mandar a este script a descargar de donde fuera.
    [string] $Api = '',

    # Dejar los ficheros en el portapapeles y no tocar WhatsApp
    [switch] $SinPegar,

    # Traer WhatsApp al frente y pulsar Ctrl+V. No envía nada: WhatsApp abre su
    # ventana de previsualización y el envío lo confirma la persona.
    [switch] $Pegar,

    # Dónde se dejan las copias descargadas
    [string] $Carpeta = (Join-Path $env:TEMP 'miCRM3-adjuntos'),

    # Cuánto se le da a WhatsApp para CARGAR LA CONVERSACIÓN antes de pegar.
    # Es el número que hay que subir si el adjunto no se pega solo: WhatsApp es
    # Electron y en un equipo lento, o la primera vez que se abre, tarda más.
    # Y no es sólo que no pegue: si todavía se ve la conversación anterior, el
    # Ctrl+V caería en el chat equivocado.
    [int] $EsperaChat = 3000,

    # Respiro extra una vez la ventana ya está delante, mientras termina de
    # colocar su interfaz. Recién traída al frente se come las pulsaciones.
    [int] $EsperaFoco = 1200,

    # Que salga solo, sin que nadie lo mire: en WhatsApp pulsa Intro después de
    # pegar; en el correo, manda el de Outlook en vez de enseñarlo.
    #
    # Apagado por defecto a propósito: lo que se le manda a un cliente no se
    # deshace, y aquí nadie ha mirado la pantalla antes de que salga. Si una
    # espera se queda corta y la conversación anterior sigue delante, el
    # adjunto se va al cliente equivocado. (Y en el correo, Outlook suele
    # preguntar igualmente cuando un programa manda por su cuenta.)
    [switch] $Enviar,

    # Lo que se le da a WhatsApp para pintar la previsualización del adjunto
    # antes de pulsar Intro. Si se pulsa demasiado pronto, el Intro cae en la
    # caja del mensaje y manda el texto suelto, sin el archivo.
    [int] $EsperaEnvio = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Las capturas van por su propio script.
#
# Aqui solo se desvia: lo de capturar una conversacion no comparte nada con
# bajar adjuntos y pegarlos, y meterlo en este fichero era arriesgar lo que ya
# funciona por una funcion que no se le parece.
# ---------------------------------------------------------------------------
if ($Url -match '^\s*micrm3:/*capturas') {
    & (Join-Path $PSScriptRoot 'capturar-whatsapp.ps1') -Url $Url -Api $Api
    exit 0
}

# ---------------------------------------------------------------------------
# Traer una ventana al frente en Windows no es una sola llamada: el sistema
# protege al que está delante para que nadie le robe el foco. El truco que sí
# funciona es engancharse al hilo de la ventana con foco (AttachThreadInput).
# Es el mismo código que marcar-zoiper.ps1, por la misma razón.
# ---------------------------------------------------------------------------
Add-Type -Namespace Win -Name Api -MemberDefinition @'
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@

$SW_RESTORE = 9

function Levantar-Ventana([IntPtr] $h) {
    if ($h -eq [IntPtr]::Zero) { return $false }
    if ([Win.Api]::IsIconic($h)) { [void][Win.Api]::ShowWindow($h, $SW_RESTORE) }

    $miHilo = [Win.Api]::GetCurrentThreadId()
    $suHilo = [Win.Api]::GetWindowThreadProcessId([Win.Api]::GetForegroundWindow(), [IntPtr]::Zero)
    $enganchado = $false
    if ($suHilo -ne 0 -and $suHilo -ne $miHilo) {
        $enganchado = [Win.Api]::AttachThreadInput($miHilo, $suHilo, $true)
    }
    [void][Win.Api]::BringWindowToTop($h)
    [void][Win.Api]::SetForegroundWindow($h)
    if ($enganchado) { [void][Win.Api]::AttachThreadInput($miHilo, $suHilo, $false) }

    return ([Win.Api]::GetForegroundWindow() -eq $h)
}

# La ventana de WhatsApp: vale la aplicación de escritorio y, si no está, la
# que tenga «WhatsApp» en el título (WhatsApp Web en una pestaña del navegador
# la pone ahí).
# Procesos que sólo ALOJAN interfaz de otro. Tienen ventana y título propios
# —el de WhatsApp incluido, porque la aplicación de escritorio se dibuja dentro
# de un WebView2— pero no son la ventana que recibe el teclado: un Ctrl+V ahí
# se pierde sin dar error. Hay que descartarlos siempre.
$ALOJADORES = @('msedgewebview2', 'ApplicationFrameHost', 'TextInputHost', 'WebViewHost')

function Buscar-VentanaDeWhatsapp {
    # La aplicación de escritorio.
    #
    # Se busca por 'WhatsApp*' y no por 'WhatsApp' a secas: el proceso que
    # tiene la ventana se llama «WhatsApp.Root» en la versión de la Store, así
    # que el nombre exacto NO lo encontraba nunca y se caía al plan B. Y el
    # plan B tomaba la primera coincidencia por título, que según el orden de
    # enumeración podía ser el WebView2 — por eso a veces pegaba y a veces no.
    $app = Get-Process -ErrorAction SilentlyContinue |
           Where-Object {
               $_.ProcessName -like 'WhatsApp*' -and
               $_.MainWindowHandle -ne 0 -and
               $ALOJADORES -notcontains $_.ProcessName
           } | Select-Object -First 1
    if ($app) { return $app }

    # WhatsApp Web: la pestaña del navegador lleva «WhatsApp» en el título.
    return Get-Process -ErrorAction SilentlyContinue |
           Where-Object {
               $_.MainWindowHandle -ne 0 -and
               $_.MainWindowTitle -like '*WhatsApp*' -and
               $ALOJADORES -notcontains $_.ProcessName
           } | Select-Object -First 1
}

# ---------------------------------------------------------------------------
# 1. Los ids: vienen como «micrm3://copiar?ids=12,13», a veces con barras de
#    más que añade Windows. Sólo se aceptan números.
# ---------------------------------------------------------------------------
$ids = @()
if ($Url -match 'ids=([0-9,]+)') {
    # El @() no es adorno: con un solo id la tubería devuelve un texto suelto y
    # no un array, y bajo Set-StrictMode preguntarle .Count revienta.
    $ids = @($Matches[1] -split ',' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 20)
}

# A quién se le escribe y qué. Vienen codificados: el texto lleva tildes,
# signos de interrogación y saltos de línea.
$tel = ''
if ($Url -match '[?&]tel=([^&]*)') { $tel = ($Matches[1] -replace '[^\d+]', '') }

$texto = ''
if ($Url -match '[?&]texto=([^&]*)') {
    try { $texto = [System.Uri]::UnescapeDataString($Matches[1].Replace('+', ' ')) } catch { $texto = '' }
}

# 'app' abre el WhatsApp instalado; 'web' pasa por el navegador. Lo decide el
# CRM, que es donde se elige, y aquí sólo se obedece.
$via = 'app'
if ($Url -match '[?&]via=web') { $via = 'web' }

# ---------------------------------------------------------------------------
# El correo: «micrm3://correo?para=…&asunto=…&cuerpo=…&ids=…»
#
# El cuerpo viaja en el propio enlace, y cabe: medido en este equipo, por el
# protocolo llegan 25.000 caracteres intactos. Por eso no hace falta ni fichero
# temporal ni portapapeles.
# ---------------------------------------------------------------------------
$esCorreo = ($Url -match '^\s*micrm3:/*correo')

function Leer-Parametro([string] $url, [string] $nombre) {
    if ($url -match ('[?&]' + $nombre + '=([^&]*)')) {
        try { return [System.Uri]::UnescapeDataString($Matches[1].Replace('+', ' ')) } catch { return '' }
    }
    return ''
}

$para   = ''
$asunto = ''
$cuerpo = ''
if ($esCorreo) {
    $para   = Leer-Parametro $Url 'para'
    $asunto = Leer-Parametro $Url 'asunto'
    $cuerpo = Leer-Parametro $Url 'cuerpo'
}

if ($ids.Count -eq 0 -and -not $tel -and -not $para) { exit 0 }
if ($ids.Count -gt 0 -and -not $Api) { throw 'Falta -Api: lo pone el instalador y dice de qué servidor se baja' }
if ($Api -and $Api -notmatch '/$') { $Api = $Api + '/' }

# ---------------------------------------------------------------------------
# 2. Bajarlos
#
# La carpeta se vacía antes: si no, cada envío iría arrastrando los adjuntos
# de los anteriores y un día se pega al cliente lo que no era.
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $Carpeta) { Remove-Item -LiteralPath $Carpeta -Recurse -Force -ErrorAction SilentlyContinue }
$null = New-Item -ItemType Directory -Path $Carpeta -Force

$rutas = @()
foreach ($id in $ids) {
    $enlace = "${Api}ventas/archivoCliente/ver/$id`?descargar=1"
    try {
        # El nombre bueno viene en la cabecera, no en la url: en el disco del
        # servidor el fichero se llama «56_cotizacion-20261006-ab12cd.pdf» y al
        # cliente hay que mandarle «cotizacion.pdf».
        $tmp = Join-Path $Carpeta "descarga-$id.tmp"
        $r = Invoke-WebRequest -Uri $enlace -OutFile $tmp -PassThru -UseBasicParsing -TimeoutSec 60

        $nombre = "adjunto-$id"
        $cd = $r.Headers['Content-Disposition']
        if ($cd -and $cd -match 'filename\*?=(?:UTF-8'''')?"?([^";]+)"?') {
            $nombre = [System.Uri]::UnescapeDataString($Matches[1].Trim())
        }
        # Lo que Windows no admite en un nombre de fichero
        foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $nombre = $nombre.Replace($c, '_') }

        $rutaDestino = Join-Path $Carpeta $nombre
        # Dos adjuntos con el mismo nombre no se pisan
        $n = 2
        while (Test-Path -LiteralPath $rutaDestino) {
            $sinExt = [System.IO.Path]::GetFileNameWithoutExtension($nombre)
            $ext    = [System.IO.Path]::GetExtension($nombre)
            $rutaDestino = Join-Path $Carpeta ($sinExt + " ($n)" + $ext)
            $n++
        }
        Move-Item -LiteralPath $tmp -Destination $rutaDestino -Force
        $rutas += $rutaDestino
    } catch {
        Write-Warning "No se pudo bajar el archivo $id : $($_.Exception.Message)"
    }
}

$rutas = @($rutas)
if ($ids.Count -gt 0 -and $rutas.Count -eq 0) { throw 'No se pudo bajar ningun adjunto' }

# ---------------------------------------------------------------------------
# 3-bis. EL CORREO, con el Outlook del puesto
#
# Por COM y no con un enlace mailto: por dos cosas que mailto no sabe hacer.
# Una, el formato: mailto manda texto llano, y el mensaje del asunto puede
# venir en HTML. Dos, los adjuntos: por mailto no viajan, y aquí ya están
# descargados.
#
# Se muestra, NO se envía. Outlook abre el correo escrito y quien lo manda es
# la persona, que es quien tiene que mirar a quién va antes de pulsar. Con
# -Enviar sale solo, para quien lo quiera así; y aun entonces Outlook puede
# pedir confirmación por su propia guardia contra programas que mandan correo.
# ---------------------------------------------------------------------------
if ($esCorreo) {
    if (-not $para) { throw 'Falta a quien se le escribe' }

    try {
        $outlook = New-Object -ComObject Outlook.Application
    } catch {
        throw 'No encuentro Outlook instalado en este equipo'
    }

    $correo = $outlook.CreateItem(0)   # 0 = olMailItem
    $correo.To = $para
    if ($asunto) { $correo.Subject = $asunto }

    # HTMLBody y no Body: con Body el HTML llegaría con las etiquetas a la
    # vista. Si el mensaje venía sin formato se envuelve, para que los saltos
    # de línea se vean como saltos y no como un párrafo seguido.
    if ($cuerpo) {
        $correo.HTMLBody = if ($cuerpo -match '<[a-z!/]') {
            $cuerpo
        } else {
            '<div style="font-family:Calibri,sans-serif;font-size:11pt">' +
            ($cuerpo -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace "`r?`n", '<br>') +
            '</div>'
        }
    }

    foreach ($r in $rutas) {
        try { $null = $correo.Attachments.Add($r) }
        catch { Write-Warning "No se pudo adjuntar $r : $($_.Exception.Message)" }
    }

    if ($Enviar) { $correo.Send() } else { $correo.Display($false) }

    if ($env:MICRM3_DEBUG -eq 'si') {
        Write-Host ("correo para=$para  asunto=$asunto  adjuntos=" + $rutas.Count + "  enviado=$Enviar")
    }
    exit 0
}

# ---------------------------------------------------------------------------
# 3. Al portapapeles, como ficheros
#
# -Path y no -Value: con -Value se copiarían las RUTAS como texto y al pegar en
# WhatsApp saldría «C:\Users\...\cotizacion.pdf» escrito en el chat.
# ---------------------------------------------------------------------------
if ($rutas.Count -gt 0) { Set-Clipboard -Path $rutas }

# ---------------------------------------------------------------------------
# 4. Abrir la conversación
#
# Lo abre ESTE script y no el navegador porque es el segundo aviso el que
# Chrome ya no deja salir (ver la cabecera). Aquí no hay límite de tiempo que
# valga: el permiso lo dio el usuario al pulsar Guardar.
# ---------------------------------------------------------------------------
if ($tel) {
    $internacional = if ($tel.StartsWith('0')) { '593' + $tel.Substring(1) } else { $tel }
    $sufijo = if ($texto) { [System.Uri]::EscapeDataString($texto) } else { '' }
    $enlace = if ($via -eq 'app') {
        "whatsapp://send?phone=$internacional" + $(if ($sufijo) { "&text=$sufijo" } else { '' })
    } else {
        "https://wa.me/$internacional" + $(if ($sufijo) { "?text=$sufijo" } else { '' })
    }
    Start-Process $enlace
    # WhatsApp tarda en abrir la conversación; sin esta pausa se busca su
    # ventana antes de que exista y se pega en lo que hubiera delante.
    Start-Sleep -Milliseconds $EsperaChat
}

# ---------------------------------------------------------------------------
# 5. WhatsApp al frente y pegar
#
# Sólo se pega si su ventana está REALMENTE delante: mandar un Ctrl+V a ciegas
# acabaría soltando los ficheros en cualquier otra aplicación que estuviera en
# pantalla. Y no se pulsa Intro: WhatsApp enseña la previsualización y el envío
# lo confirma la persona, que es quien tiene que mirar a qué chat va.
# ---------------------------------------------------------------------------
$pegado  = $false
$enviado = $false

# Corre oculto, así que un fallo aquí no deja rastro en ninguna parte. El
# registro es la única forma de saber en qué paso se quedó.
$bitacora = Join-Path $Carpeta 'ultimo.log'
function Anotar([string] $linea) {
    try { Add-Content -LiteralPath $bitacora -Value ((Get-Date -Format 'HH:mm:ss.fff') + '  ' + $linea) -Encoding UTF8 } catch { }
}
Set-Content -LiteralPath $bitacora -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "  === micrm3 ===") -Encoding UTF8 -ErrorAction SilentlyContinue
Anotar ("bajados=$($rutas.Count)  tel=$tel  via=$via  Pegar=$Pegar  SinPegar=$SinPegar  Enviar=$Enviar")

if ($rutas.Count -gt 0 -and -not $SinPegar -and $Pegar) {
    $ventana = [IntPtr]::Zero
    $levantada = $false
    foreach ($intento in 1..10) {
        $p = Buscar-VentanaDeWhatsapp
        if ($p) {
            $ventana = $p.MainWindowHandle
            $levantada = Levantar-Ventana $ventana
            Anotar ("intento $intento : proceso=$($p.ProcessName) pid=$($p.Id) ventana=$ventana levantada=$levantada frente=$([Win.Api]::GetForegroundWindow())")
            if ($levantada) { break }
        } else {
            Anotar "intento $intento : no encuentro ventana de WhatsApp"
        }
        Start-Sleep -Milliseconds 400
    }

    Anotar ("tras los intentos: levantada=$levantada ventana=$ventana frente=$([Win.Api]::GetForegroundWindow())")

    if ($levantada -and [Win.Api]::GetForegroundWindow() -eq $ventana) {
        # Un respiro: recién traída al frente, WhatsApp todavía está colocando
        # su interfaz y se come las primeras pulsaciones.
        Start-Sleep -Milliseconds $EsperaFoco

        # Se vuelve a mirar quién está delante justo antes de teclear: entre la
        # comprobación de arriba y este punto han pasado más de un segundo, y
        # en ese rato el usuario pudo cambiar de ventana. Sin esto, el adjunto
        # acabaría pegado en lo que tuviera en pantalla.
        Anotar ("antes de teclear: frente=$([Win.Api]::GetForegroundWindow())")
        if ([Win.Api]::GetForegroundWindow() -eq $ventana) {
            $sh = New-Object -ComObject WScript.Shell
            $sh.SendKeys('^v')
            $pegado = $true

            if ($Enviar) {
                # Que termine de montarse la previsualización. Pulsar antes
                # manda el texto solo, sin el adjunto.
                Start-Sleep -Milliseconds $EsperaEnvio

                # Tercera y última comprobación del foco. Es la que más
                # importa: a partir de aquí el mensaje sale y no hay vuelta
                # atrás, así que si el usuario se cambió de ventana en estos
                # segundos, mejor dejarlo sin enviar que mandarlo a otro sitio.
                if ([Win.Api]::GetForegroundWindow() -eq $ventana) {
                    $sh.SendKeys('{ENTER}')
                    $enviado = $true
                }
            }
        }
    }
}

Anotar ("FIN  pegado=$pegado  enviado=$enviado")

if ($env:MICRM3_DEBUG -eq 'si') {
    Write-Host ("ids=" + ($ids -join ',') + "  bajados=" + $rutas.Count + "  tel=$tel  via=$via  pegado=$pegado  enviado=$enviado")
    $rutas | ForEach-Object { Write-Host "   $_" }
}
