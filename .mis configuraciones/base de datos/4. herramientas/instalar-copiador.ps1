<#
  INSTALAR EL COPIADOR DE ADJUNTOS DE miCRM3 EN UN PUESTO

  Deja el CRM listo para mandar adjuntos por WhatsApp: al guardar una gestión
  con archivos, se descargan, quedan en el portapapeles y se pegan en WhatsApp
  con Ctrl+V (o solo, si se instala con -Pegar).

  Qué hace, exactamente:
    1. Copia copiar-archivos.ps1 a una carpeta del usuario (no hace falta que
       el puesto tenga el proyecto).
    2. Registra el protocolo micrm3: apuntando a esa copia, con la dirección
       del servidor dentro del comando.

  La dirección del servidor se graba AQUÍ y no viaja en el enlace a propósito:
  si viniera en el enlace, cualquier página que alguien abriera podría mandar
  al script a descargar de donde fuera.

  NO necesita permisos de administrador: todo va en HKCU, la rama del usuario.
  Hay que ejecutarlo UNA VEZ POR USUARIO de Windows en cada equipo.

      powershell -ExecutionPolicy Bypass -File instalar-copiador.ps1 -Api http://192.168.2.173:8009/

  Por defecto trae WhatsApp al frente y pega. No envía: WhatsApp enseña la
  previsualización y el envío lo confirma la persona. Para que sólo copie y se
  pegue a mano:
      powershell -ExecutionPolicy Bypass -File instalar-copiador.ps1 -Api ... -SinPegar

  Para quitarlo: desinstalar-copiador.ps1
#>
param(
    # La dirección del API del CRM. Es lo único obligatorio.
    [Parameter(Mandatory = $true)] [string] $Api,
    # Dónde queda el script. Por defecto, en el perfil del usuario.
    [string] $Carpeta = (Join-Path $env:LOCALAPPDATA 'miCRM3'),
    # Deja los adjuntos copiados pero no toca WhatsApp
    [switch] $SinPegar,

    # Pulsa Intro y manda el mensaje sin que nadie lo revise.
    # Léase el aviso del final de este archivo antes de usarlo.
    [switch] $Enviar,

    # Los tiempos de espera. Se suben si el adjunto no llega a pegarse: en un
    # equipo lento WhatsApp tarda más en cargar la conversación.
    [int] $EsperaChat  = 3000,   # a que abra el chat
    [int] $EsperaFoco  = 1200,   # a que la ventana esté lista tras traerla al frente
    [int] $EsperaEnvio = 1800,   # a que pinte la previsualización, antes del Intro

    # El protocolo a registrar. Se cambia sólo para probar sin tocar el de verdad.
    [string] $Protocolo = 'micrm3'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$origen = Join-Path $PSScriptRoot 'copiar-archivos.ps1'
if (-not (Test-Path -LiteralPath $origen)) { throw "No encuentro copiar-archivos.ps1 junto a este instalador ($PSScriptRoot)" }

if ($Api -notmatch '^https?://') { throw "La direccion del API tiene que empezar por http:// o https:// (recibi: $Api)" }
if ($Api -notmatch '/$') { $Api = $Api + '/' }

Write-Host ''
Write-Host '  COPIADOR DE ADJUNTOS DE miCRM3' -ForegroundColor Cyan
Write-Host '  ------------------------------'

# --- 1. Se llega al servidor? -------------------------------------------------
try {
    $null = Invoke-WebRequest -Uri $Api -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
    Write-Host "  Servidor    : $Api  (responde)"
} catch {
    Write-Host "  Servidor    : $Api" -ForegroundColor Yellow
    Write-Host '                NO RESPONDE AHORA MISMO. El registro se hace igual:' -ForegroundColor Yellow
    Write-Host '                funcionara en cuanto se llegue a esa direccion.' -ForegroundColor Yellow
}

# --- 2. Copiar el script ------------------------------------------------------
$null = New-Item -ItemType Directory -Path $Carpeta -Force
$destino = Join-Path $Carpeta 'copiar-archivos.ps1'
Copy-Item -LiteralPath $origen -Destination $destino -Force
Write-Host "  Script      : $destino"

# --- 3. Registrar el protocolo ------------------------------------------------
# Se guarda lo que hubiera antes, por si el puesto ya tenia algo con ese nombre.
$clave = "HKCU:\Software\Classes\$Protocolo"
$claveCmd = Join-Path $clave 'shell\open\command'

if (Test-Path $claveCmd) {
    $previo = (Get-ItemProperty $claveCmd).'(default)'
    if ($previo -and $previo -notlike "*copiar-archivos.ps1*") {
        $copia = Join-Path $Carpeta "handler-anterior-$Protocolo.reg"
        & reg.exe export "HKCU\Software\Classes\$Protocolo" $copia /y | Out-Null
        Write-Host "  Copia previa: $copia"
    }
}

$null = New-Item -Path $claveCmd -Force
Set-ItemProperty -Path $clave -Name '(default)' -Value "URL:$Protocolo protocol"
Set-ItemProperty -Path $clave -Name 'URL Protocol' -Value ''

$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$comando = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destino`" `"%1`" -Api `"$Api`""
if (-not $SinPegar) {
    $comando += ' -Pegar'
    # Los tiempos viajan en el comando: así se ajustan reinstalando, sin tener
    # que editar el script en cada puesto.
    $comando += " -EsperaChat $EsperaChat -EsperaFoco $EsperaFoco"
    if ($Enviar) { $comando += " -Enviar -EsperaEnvio $EsperaEnvio" }
}
Set-ItemProperty -Path $claveCmd -Name '(default)' -Value $comando

# Las llaves no son adorno: «$Protocolo:» lo lee PowerShell como una unidad
# (estilo $env:) y da error de sintaxis.
$modo = if ($SinPegar) { '(copia; se pega con Ctrl+V)' }
        elseif ($Enviar) { '(copia, pega Y ENVIA sin revisar)' }
        else { '(copia y pega en WhatsApp)' }
Write-Host "  Protocolo   : ${Protocolo}:  ->  el script  $modo"
Write-Host ''
Write-Host '  Listo.' -ForegroundColor Green
Write-Host ''
Write-Host '  Lo que falta, y lo tiene que hacer el usuario una vez:' -ForegroundColor Cyan
Write-Host '    1. Tener WhatsApp Web o WhatsApp Desktop abierto y con sesion.'
Write-Host '    2. En el CRM, guardar una gestion con archivos adjuntos. Chrome'
Write-Host '       preguntara si permite abrir la aplicacion: marcar "Permitir siempre".'
if ($SinPegar) {
    Write-Host '    3. En la conversacion de WhatsApp, pulsar Ctrl+V.'
} else {
    Write-Host '    3. Nada mas: se pega solo. Si WhatsApp no estaba delante, Ctrl+V.'
}
Write-Host ''
Write-Host '  WhatsApp NO envia nada solo: al pegar ensena la previsualizacion y' -ForegroundColor Cyan
Write-Host '  el envio lo confirma la persona.' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Si el antivirus pone el script en cuarentena, los adjuntos dejan de' -ForegroundColor Yellow
Write-Host '  copiarse: hay que darle permiso a esa carpeta.' -ForegroundColor Yellow
