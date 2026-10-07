<#
  QUITAR EL MARCADOR DE miCRM3 DE UN PUESTO

  Devuelve el protocolo zoiper: a como estaba y borra la copia del script.

      powershell -ExecutionPolicy Bypass -File desinstalar-marcador.ps1

  Si el puesto tenía antes su propio registro de Zoiper, el instalador lo
  guardó en un .reg junto al script y aquí se vuelve a aplicar. Si no había
  nada, se borra la clave y Windows deja de reconocer zoiper:.
#>
param(
    [string] $Carpeta = (Join-Path $env:LOCALAPPDATA 'miCRM3'),
    [string] $Protocolo = 'zoiper'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$clave = "HKCU:\Software\Classes\$Protocolo"
$copia = Join-Path $Carpeta "handler-anterior-$Protocolo.reg"

if (Test-Path -LiteralPath $copia) {
    & reg.exe import $copia 2>&1 | Out-Null
    Write-Host "  Restaurado el registro anterior desde $copia"
} elseif (Test-Path $clave) {
    Remove-Item -Path $clave -Recurse -Force
    Write-Host "  Borrada la clave $clave (no habia ninguna anterior que restaurar)"
} else {
    Write-Host "  No habia nada registrado en $clave"
}

$script = Join-Path $Carpeta 'marcar-zoiper.ps1'
if (Test-Path -LiteralPath $script) {
    Remove-Item -LiteralPath $script -Force
    Write-Host "  Borrado $script"
}

Write-Host '  Hecho.' -ForegroundColor Green
