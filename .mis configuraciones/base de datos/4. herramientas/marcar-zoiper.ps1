<#
  MARCAR CON ZOIPER Y TRAERLO AL FRENTE

  Se engancha al protocolo zoiper: en vez de llamar al softphone directamente.
  Hace lo mismo que hacía antes —pasarle el número— y además levanta su
  ventana, que es lo que Zoiper no hace solo cuando ya está abierto.

  Por qué hace falta un intermediario: el navegador no puede tocar las ventanas
  de otros programas, y Zoiper, al recibir el --dial con una instancia ya en
  marcha, marca pero se queda donde estaba.

  Uso (lo llama Windows, no se ejecuta a mano):
      powershell -File marcar-zoiper.ps1 "zoiper:0987654321"

  Para probar sin llamar a nadie:
      powershell -File marcar-zoiper.ps1 "zoiper:0987654321" -NoLlamar
#>
param(
    [Parameter(Position = 0)] [string] $Url = '',
    # Levanta la ventana pero NO marca: para probar sin molestar a nadie
    [switch] $NoLlamar,
    # No tocar el portapapeles ni pegar nada
    [switch] $SinPegar,
    # Además de pegar, pulsar Intro para que llame directamente
    [switch] $Llamar,
    # Una vez marcando, apartarse: el vendedor vuelve al CRM a escribir la
    # gestión mientras habla. La llamada sigue, sólo se esconde la ventana.
    [switch] $Minimizar,
    # Vacío = se busca solo. Se pasa sólo si está en un sitio raro.
    [string] $Zoiper = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Traer una ventana al frente en Windows no es una sola llamada: el sistema
# protege al que está delante para que nadie le robe el foco. SetForegroundWindow
# a secas falla y la ventana sólo parpadea en la barra de tareas. El truco que
# sí funciona es engancharse al hilo de la ventana que tiene el foco
# (AttachThreadInput): mientras dura el enganche, Windows nos trata como si
# fuéramos ella y nos deja pasar al frente.
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

$SW_RESTORE  = 9
$SW_MINIMIZE = 6

function Buscar-Ejecutable {
    <#
      Dónde está Zoiper en ESTA máquina.

      No se fija una ruta porque en los puestos cambia: Zoiper 5 y Zoiper 3 se
      instalan en carpetas distintas, y en los Windows de 64 bits puede caer en
      «Program Files» o en «Program Files (x86)» según el instalador. Primero
      se le pregunta al propio proceso si ya está corriendo, que es la
      respuesta más fiable.
    #>
    $p = Get-Process -Name 'Zoiper*' -ErrorAction SilentlyContinue |
         Where-Object { $_.Path } | Select-Object -First 1
    if ($p) { return $p.Path }

    $candidatos = @(
        "${env:ProgramFiles(x86)}\Zoiper5\Zoiper5.exe",
        "$env:ProgramFiles\Zoiper5\Zoiper5.exe",
        "${env:ProgramFiles(x86)}\Zoiper\Zoiper.exe",
        "$env:ProgramFiles\Zoiper\Zoiper.exe",
        "$env:LOCALAPPDATA\Programs\Zoiper5\Zoiper5.exe"
    )
    foreach ($c in $candidatos) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return ''
}

function Buscar-VentanaDeZoiper {
    # Zoiper abre varios procesos (es Electron); sólo uno tiene ventana
    Get-Process -Name 'Zoiper*' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1
}

function Levantar-Ventana([IntPtr] $h) {
    if ($h -eq [IntPtr]::Zero) { return $false }

    # Minimizada, restaurarla primero: al frente pero minimizada no se ve
    if ([Win.Api]::IsIconic($h)) { [void][Win.Api]::ShowWindow($h, $SW_RESTORE) }

    $delante = [Win.Api]::GetForegroundWindow()
    $hiloDelante = [Win.Api]::GetWindowThreadProcessId($delante, [IntPtr]::Zero)
    $hiloNuestro = [Win.Api]::GetCurrentThreadId()

    $enganchado = $false
    if ($hiloDelante -ne 0 -and $hiloDelante -ne $hiloNuestro) {
        $enganchado = [Win.Api]::AttachThreadInput($hiloNuestro, $hiloDelante, $true)
    }
    try {
        [void][Win.Api]::BringWindowToTop($h)
        [void][Win.Api]::SetForegroundWindow($h)
    } finally {
        if ($enganchado) { [void][Win.Api]::AttachThreadInput($hiloNuestro, $hiloDelante, $false) }
    }

    return ([Win.Api]::GetForegroundWindow() -eq $h)
}

# ---------------------------------------------------------------------------
# 1. El número: viene como «zoiper:0987654321», a veces con barras que añade
#    Windows. Se queda sólo con los dígitos y el + inicial.
# ---------------------------------------------------------------------------
$numero = ($Url -replace '^\s*zoiper:/*', '') -replace '[^\d+]', ''

# ---------------------------------------------------------------------------
# 2. Marcar (salvo en modo prueba)
#
# La variable de entorno sirve para probar la cadena entera —el protocolo, el
# registro, este script— sin llamarle a nadie, que al invocar zoiper: no hay
# forma de pasarle el parámetro -NoLlamar:
#     $env:ZOIPER_SIN_LLAMAR = 'si'
# ---------------------------------------------------------------------------
if ($env:ZOIPER_SIN_LLAMAR -eq 'si') { $NoLlamar = $true }

if (-not $NoLlamar -and $numero) {
    if (-not $Zoiper) { $Zoiper = Buscar-Ejecutable }
    if (-not $Zoiper -or -not (Test-Path -LiteralPath $Zoiper)) { throw 'No encuentro Zoiper instalado en este equipo' }
    Start-Process -FilePath $Zoiper -ArgumentList "--dial=$numero"
    # Zoiper tarda un poco en atender el --dial; sin esta pausa se levanta la
    # ventana antes de que reaccione y a veces vuelve a quedarse detrás.
    Start-Sleep -Milliseconds 700
}

# ---------------------------------------------------------------------------
# 3. Traerlo al frente, reintentando: si no estaba abierto, tarda en aparecer
# ---------------------------------------------------------------------------
$levantada = $false
$ventana = [IntPtr]::Zero
foreach ($intento in 1..12) {
    $p = Buscar-VentanaDeZoiper
    if ($p) {
        $ventana = $p.MainWindowHandle
        $levantada = Levantar-Ventana $ventana
        if ($levantada) { break }
    }
    Start-Sleep -Milliseconds 400
}

# ---------------------------------------------------------------------------
# 4. El número, al portapapeles y pegado en Zoiper
#
# Hace falta porque Zoiper, con una instancia ya abierta, IGNORA el --dial de
# la línea de comandos: levanta la ventana y se queda esperando. Así que se le
# deja el número puesto en el campo y sólo falta pulsar llamar.
#
# El pegado sólo se intenta si la ventana de Zoiper está REALMENTE delante:
# mandar pulsaciones a ciegas acabaría escribiendo el teléfono en cualquier
# otra aplicación que estuviera en pantalla.
# ---------------------------------------------------------------------------
$pegado = $false
$minimizada = $false
if (-not $SinPegar -and $numero) {
    try { Set-Clipboard -Value $numero } catch { }

    if ($levantada -and [Win.Api]::GetForegroundWindow() -eq $ventana) {
        # Un respiro: recién restaurada, Zoiper todavía está colocando su
        # interfaz y se come las primeras pulsaciones.
        Start-Sleep -Milliseconds 450
        $sh = New-Object -ComObject WScript.Shell
        # Seleccionar lo que hubiera antes y sustituirlo, para no encadenar
        # números si se marca dos veces seguidas
        $sh.SendKeys('^a')
        Start-Sleep -Milliseconds 120
        $sh.SendKeys('^v')
        if ($Llamar) { Start-Sleep -Milliseconds 250; $sh.SendKeys('{ENTER}') }
        $pegado = $true

        # Apartarse para que el vendedor vuelva al CRM a escribir la gestión.
        # La espera es para que Zoiper llegue a cursar la llamada: minimizar en
        # el mismo instante en que se pulsa Intro le quita el foco a media
        # tecla. La llamada sigue; sólo se esconde la ventana.
        if ($Minimizar -and $ventana -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 900
            [void][Win.Api]::ShowWindow($ventana, $SW_MINIMIZE)
            $minimizada = $true
        }
    }
}

if ($env:ZOIPER_DEBUG -eq 'si') {
    Write-Host ("numero=$numero  ventana=$ventana  al frente=$levantada  pegado=$pegado  pulsar-llamar=$Llamar  minimizada=$minimizada")
}
