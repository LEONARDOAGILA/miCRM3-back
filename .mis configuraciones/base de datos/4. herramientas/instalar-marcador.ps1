<#
  INSTALAR EL MARCADOR DE miCRM3 EN UN PUESTO

  Deja el CRM listo para marcar: al pulsar un teléfono en la aplicación, Zoiper
  se restaura, pasa al frente, recibe el número y llama.

  Qué hace, exactamente:
    1. Copia marcar-zoiper.ps1 a una carpeta del usuario (no hace falta que el
       puesto tenga el proyecto).
    2. Registra el protocolo zoiper: para que apunte a esa copia.

  NO necesita permisos de administrador: todo va en HKCU, la rama del usuario.
  Hay que ejecutarlo UNA VEZ POR USUARIO de Windows en cada equipo.

      powershell -ExecutionPolicy Bypass -File instalar-marcador.ps1

  Para que sólo pegue el número y no llame sola:
      powershell -ExecutionPolicy Bypass -File instalar-marcador.ps1 -SinLlamar

  Para quitarlo: desinstalar-marcador.ps1
#>
param(
    # Dónde queda el script. Por defecto, en el perfil del usuario.
    [string] $Carpeta = (Join-Path $env:LOCALAPPDATA 'miCRM3'),
    # Pega el número pero no pulsa llamar
    [switch] $SinLlamar,
    # El protocolo a registrar. Se cambia sólo para probar sin tocar el de verdad.
    [string] $Protocolo = 'zoiper'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$origen = Join-Path $PSScriptRoot 'marcar-zoiper.ps1'
if (-not (Test-Path -LiteralPath $origen)) { throw "No encuentro marcar-zoiper.ps1 junto a este instalador ($PSScriptRoot)" }

Write-Host ''
Write-Host '  MARCADOR DE miCRM3' -ForegroundColor Cyan
Write-Host '  ------------------'

# --- 1. Zoiper instalado? -----------------------------------------------------
$zoiper = @(
    "${env:ProgramFiles(x86)}\Zoiper5\Zoiper5.exe",
    "$env:ProgramFiles\Zoiper5\Zoiper5.exe",
    "${env:ProgramFiles(x86)}\Zoiper\Zoiper.exe",
    "$env:ProgramFiles\Zoiper\Zoiper.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

if ($zoiper) { Write-Host "  Zoiper      : $zoiper" }
else {
    Write-Host '  Zoiper      : NO ESTA INSTALADO' -ForegroundColor Yellow
    Write-Host '                Instalalo y configura la cuenta SIP antes de usar esto.'
    Write-Host '                El registro se hace igual: funcionara en cuanto lo instales.'
}

# --- 2. Copiar el script ------------------------------------------------------
$null = New-Item -ItemType Directory -Path $Carpeta -Force
$destino = Join-Path $Carpeta 'marcar-zoiper.ps1'
Copy-Item -LiteralPath $origen -Destination $destino -Force
Write-Host "  Script      : $destino"

# --- 3. Registrar el protocolo ------------------------------------------------
# Se guarda lo que hubiera antes: si el puesto ya tenia Zoiper registrado a su
# manera, asi se puede volver atras.
$clave = "HKCU:\Software\Classes\$Protocolo"
$claveCmd = Join-Path $clave 'shell\open\command'

if (Test-Path $claveCmd) {
    $previo = (Get-ItemProperty $claveCmd).'(default)'
    if ($previo -and $previo -notlike "*marcar-zoiper.ps1*") {
        $copia = Join-Path $Carpeta "handler-anterior-$Protocolo.reg"
        & reg.exe export "HKCU\Software\Classes\$Protocolo" $copia /y | Out-Null
        Write-Host "  Copia previa: $copia"
    }
}

$null = New-Item -Path $claveCmd -Force
Set-ItemProperty -Path $clave -Name '(default)' -Value "URL:$Protocolo protocol"
Set-ItemProperty -Path $clave -Name 'URL Protocol' -Value ''

$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$comando = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destino`" `"%1`""
if (-not $SinLlamar) { $comando += ' -Llamar' }
Set-ItemProperty -Path $claveCmd -Name '(default)' -Value $comando

# Las llaves no son adorno: «$Protocolo:» lo lee PowerShell como una unidad
# (estilo $env:) y da error de sintaxis.
$modo = if ($SinLlamar) { '(solo pega el numero)' } else { '(pega y llama)' }
Write-Host "  Protocolo   : ${Protocolo}:  ->  el script  $modo"
Write-Host ''
Write-Host '  Listo.' -ForegroundColor Green
Write-Host ''
Write-Host '  Lo que falta, y lo tiene que hacer el usuario una vez:' -ForegroundColor Cyan
Write-Host '    1. Abrir Zoiper y dejar la cuenta SIP conectada.'
Write-Host '    2. En el CRM, pulsar el telefono de un cliente. Chrome preguntara'
Write-Host '       si permite abrir la aplicacion: marcar "Permitir siempre".'
Write-Host ''
Write-Host '  Si el antivirus pone el script en cuarentena, el marcado deja de'  -ForegroundColor Yellow
Write-Host '  funcionar: hay que darle permiso a esa carpeta.' -ForegroundColor Yellow
