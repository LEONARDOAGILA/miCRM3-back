# ===========================================================================
# CAPTURAR UNA CONVERSACIÓN DE WHATSAPP
# ===========================================================================
# Lo llama copiar-archivos.ps1 cuando el enlace es
#
#   micrm3://capturas?tel=0987742070&gestion=1520&cliente=1055&token=…&max=25
#
# y deja cada pantallazo colgado de esa gestión, como un adjunto más.
#
# POR QUÉ FUNCIONA SIN ROBAR LA PANTALLA (medido en este equipo):
#
#   · PrintWindow a secas devuelve una imagen de 3 colores —en blanco—, que es
#     lo que pasa siempre con las ventanas de Chromium. Con la bandera
#     PW_RENDERFULLCONTENT (2) devuelve la captura de verdad: 99 colores
#     distintos en un muestreo escaso, con la ventana DETRÁS de otras.
#   · La rueda del ratón hay que mandarla con PostMessage al hijo
#     «Chrome_WidgetWin_0», no a la ventana principal: a la principal no le
#     hace nada. Al hijo sí, y tampoco necesita el foco.
#
# CUÁNDO PARA: cuando dos capturas seguidas tienen la misma huella. Eso es que
# el scroll ya no mueve nada, o sea que se llegó al principio del chat. No es
# un número inventado de pantallazos: es una señal que se puede comprobar.
#
# LO QUE ESTO NO ARREGLA, y conviene saberlo:
#
#   · Son imágenes. No se busca dentro, no se copia un número de ellas y pesan
#     lo que pesan. Para tener el texto está «Importar» con el .txt que exporta
#     WhatsApp, que además trae la conversación entera y en 10 KB.
#   · Las capturas se solapan: se sube media pantalla cada vez a propósito, que
#     es preferible a que se pierda un mensaje entre dos.
#   · Las fotos del chat cargan cuando se las mira; si el scroll va rápido,
#     alguna sale como recuadro gris.
#   · Abrir el chat sí trae WhatsApp al frente un momento (lo hace el propio
#     WhatsApp al recibir whatsapp://send). Después se devuelve el foco a la
#     ventana que lo tenía.
# ===========================================================================

param(
    [Parameter(Mandatory = $true)] [string] $Url,
    [Parameter(Mandatory = $true)] [string] $Api,

    # Cuántas pantallas subir como mucho. El tope existe por si el chat es de
    # tres años: sin él, esto estaría media hora subiendo imágenes.
    [int] $Tope = 25,

    # Cuánto esperar a que WhatsApp abra la conversación
    [int] $EsperaChat = 3000,

    # Entre rueda y captura: lo que tarda en repintar y en cargar las fotos
    [int] $EsperaScroll = 700
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

Add-Type -Namespace Cap -Name Api -MemberDefinition @'
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
'@

$PW_RENDERFULLCONTENT = 2
$WM_MOUSEWHEEL        = 0x020A

# ---------------------------------------------------------------------------
# Lo que viene en el enlace
# ---------------------------------------------------------------------------
function Leer([string] $nombre) {
    if ($Url -match ('[?&]' + $nombre + '=([^&]*)')) {
        try { return [System.Uri]::UnescapeDataString($Matches[1].Replace('+', ' ')) } catch { return '' }
    }
    return ''
}

$tel     = (Leer 'tel') -replace '[^\d+]', ''
$gestion = (Leer 'gestion') -replace '\D', ''
$cliente = (Leer 'cliente') -replace '\D', ''
$token   = Leer 'token'
$max     = (Leer 'max') -replace '\D', ''
if ($max) { $Tope = [int]$max }
if ($Tope -lt 1)  { $Tope = 1 }
if ($Tope -gt 60) { $Tope = 60 }

if (-not $tel -or -not $gestion -or -not $cliente -or -not $token) { exit 0 }
if ($Api -notmatch '/$') { $Api = $Api + '/' }

$carpeta = Join-Path $env:TEMP ('micrm3-capturas-' + $PID)
if (Test-Path -LiteralPath $carpeta) { Remove-Item -LiteralPath $carpeta -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $carpeta -Force | Out-Null

$bitacora = Join-Path $carpeta 'ultimo.log'
function Anotar([string] $t) {
    "$([DateTime]::Now.ToString('HH:mm:ss'))  $t" | Out-File -FilePath $bitacora -Append -Encoding utf8
}
Anotar "capturas de $tel para la gestion $gestion (tope $Tope)"

# ---------------------------------------------------------------------------
# Abrir la conversación
# ---------------------------------------------------------------------------
$teniaElFoco = [Cap.Api]::GetForegroundWindow()

$internacional = if ($tel.StartsWith('0')) { '593' + $tel.Substring(1) } else { $tel }
Start-Process ("whatsapp://send?phone=$internacional")
Start-Sleep -Milliseconds $EsperaChat

$proc = Get-Process -Name 'WhatsApp.Root' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Anotar 'no encuentro la ventana de WhatsApp'; exit 0 }
$ventana = $proc.MainWindowHandle

# El hijo que recibe la rueda. Sin él no hay scroll: a la ventana principal el
# WM_MOUSEWHEEL no le hace nada (comprobado).
$rueda = [IntPtr]::Zero
$cb = [Cap.Api+EnumProc]{
    param($h, $p)
    $sb = New-Object System.Text.StringBuilder 256
    [void][Cap.Api]::GetClassName($h, $sb, 256)
    if ($sb.ToString() -like 'Chrome_WidgetWin*') { $script:rueda = $h; return $false }
    return $true
}
[void][Cap.Api]::EnumChildWindows($ventana, $cb, [IntPtr]::Zero)
if ($rueda -eq [IntPtr]::Zero) { $rueda = $ventana }

# ---------------------------------------------------------------------------
# Capturar y subir
# ---------------------------------------------------------------------------
function Capturar([IntPtr] $h) {
    $r = New-Object Cap.Api+RECT
    [void][Cap.Api]::GetWindowRect($h, [ref]$r)
    $w = $r.R - $r.L; $a = $r.B - $r.T
    if ($w -lt 50 -or $a -lt 50) { return $null }

    $bmp = New-Object System.Drawing.Bitmap($w, $a)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][Cap.Api]::PrintWindow($h, $hdc, $PW_RENDERFULLCONTENT)
    $g.ReleaseHdc($hdc); $g.Dispose()
    return $bmp
}

function Huella([System.Drawing.Bitmap] $bmp) {
    $suma = [long]0
    for ($x = 5; $x -lt $bmp.Width;  $x += 13) {
        for ($y = 5; $y -lt $bmp.Height; $y += 13) { $suma += $bmp.GetPixel($x, $y).ToArgb() }
    }
    return $suma
}

function Subir([string] $ruta, [int] $n) {
    # Subir y registrar van separados, igual que en la pantalla de archivos.
    #
    # El multipart va con HttpClient y NO con «Invoke-RestMethod -Form»: ese
    # parametro es de PowerShell 7 y aqui corre la 5.1, que es la que trae
    # Windows. Con -Form la 5.1 responde «No se encuentra ningun parametro que
    # coincida con el nombre del parametro 'Form'» y no sube nada.
    $nombre = [IO.Path]::GetFileName($ruta)

    $http = New-Object System.Net.Http.HttpClient
    $http.Timeout = [TimeSpan]::FromSeconds(60)
    $http.DefaultRequestHeaders.Authorization =
        New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token)
    $http.DefaultRequestHeaders.Accept.ParseAdd('application/json')

    try {
        $cuerpo = New-Object System.Net.Http.MultipartFormDataContent
        $cuerpo.Add((New-Object System.Net.Http.StringContent($cliente)), 'cliente_id')
        $cuerpo.Add((New-Object System.Net.Http.StringContent('gestion')), 'origen')

        $bytes = [IO.File]::ReadAllBytes($ruta)
        # La coma no sobra: sin ella PowerShell desenrolla el array y el
        # constructor recibe un byte suelto en vez del fichero entero.
        $fichero = New-Object System.Net.Http.ByteArrayContent(,$bytes)
        $fichero.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('image/png')
        $cuerpo.Add($fichero, 'archivo', $nombre)

        $resp = $http.PostAsync(($Api + 'ventas/archivoCliente/subirArchivo'), $cuerpo).Result
        $codigo = [int]$resp.StatusCode
        $txt    = $resp.Content.ReadAsStringAsync().Result
    } finally {
        $http.Dispose()
    }

    # El codigo y un trozo del cuerpo en el mensaje: sin eso, un 401 o un 500
    # acaban en la bitacora como «no existe la propiedad status» y hay que
    # adivinar. Esto corre oculto: el log es lo unico que queda.
    if ($codigo -ne 200) { throw "subirArchivo: HTTP $codigo - $($txt.Substring(0, [Math]::Min(120, $txt.Length)))" }

    $subida = $null
    try { $subida = $txt | ConvertFrom-Json } catch { throw "subirArchivo: respuesta que no es json - $($txt.Substring(0, [Math]::Min(120, $txt.Length)))" }
    if (-not $subida.PSObject.Properties['status'] -or $subida.status -ne 'success') {
        throw "subirArchivo: $txt"
    }

    $d = $subida.data
    # Las cabeceras aqui y no arriba: la subida del fichero ya va por su
    # propio HttpClient, que lleva las suyas.
    $cab = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

    $registro = Invoke-RestMethod -Uri ($Api + 'ventas/archivoCliente/addArchivo') -Method Post -Headers $cab `
        -ContentType 'application/json' -Body (@{
            cliente_id = [int]$cliente
            gestion_id = [int]$gestion
            origen     = 'gestion'
            nombre     = ('Captura {0:d2}' -f $n)
            archivo    = $d.archivo
            tipo       = $d.tipo
            extension  = $d.extension
            mime       = $d.mime
            tamano     = $d.tamano
        } | ConvertTo-Json)
    if ($registro.status -ne 'success') { throw "addArchivo: $($registro.message)" }
}

$anterior = $null
$subidas  = 0

for ($i = 1; $i -le $Tope; $i++) {
    $bmp = Capturar $ventana
    if (-not $bmp) { Anotar 'la ventana no tiene tamaño util'; break }

    $h = Huella $bmp
    if ($null -ne $anterior -and $h -eq $anterior) {
        # El scroll ya no mueve nada: se llegó al principio del chat
        $bmp.Dispose()
        Anotar "fin: la pantalla $i es igual que la anterior"
        break
    }
    $anterior = $h

    $ruta = Join-Path $carpeta ('captura-{0:d2}.png' -f $i)
    $bmp.Save($ruta, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    try {
        Subir $ruta $i
        $subidas++
        Anotar "subida la $i"
    } catch {
        Anotar "fallo al subir la $i : $($_.Exception.Message)"
    }

    # En la ultima vuelta no se desplaza: con -max=1 (capturar solo la pantalla
    # de ahora) mover la rueda dejaria el chat del usuario donde no estaba.
    if ($i -ge $Tope) { break }

    # Media pantalla hacia arriba: con el solape no se pierde ningún mensaje
    # entre dos capturas, que es peor que repetir uno.
    $r = New-Object Cap.Api+RECT
    [void][Cap.Api]::GetWindowRect($ventana, [ref]$r)
    $px = $r.L + [int](($r.R - $r.L) * 0.65)
    $py = $r.T + [int](($r.B - $r.T) * 0.5)
    $lp = [IntPtr](($py -shl 16) -bor ($px -band 0xFFFF))
    for ($k = 0; $k -lt 5; $k++) {
        [void][Cap.Api]::PostMessage($rueda, $WM_MOUSEWHEEL, [IntPtr](120 -shl 16), $lp)
        Start-Sleep -Milliseconds 90
    }
    Start-Sleep -Milliseconds $EsperaScroll
}

# Devolver el foco a quien lo tenía antes de abrir el chat
if ($teniaElFoco -ne [IntPtr]::Zero) { [void][Cap.Api]::SetForegroundWindow($teniaElFoco) }

Anotar "terminado: $subidas capturas"
# Las imágenes ya están en el servidor; en el disco no hacen falta
Get-ChildItem -LiteralPath $carpeta -Filter '*.png' | Remove-Item -Force -ErrorAction SilentlyContinue
exit 0
