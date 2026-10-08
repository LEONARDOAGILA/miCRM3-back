<#
  QUITAR EL COPIADOR DE ADJUNTOS DE miCRM3 DE UN PUESTO

  Devuelve el protocolo micrm3: a como estaba, borra la copia del script y la
  carpeta donde se dejaban las descargas.

      powershell -ExecutionPolicy Bypass -File desinstalar-copiador.ps1

  Si el puesto tenía antes su propio registro con ese nombre, el instalador lo
  guardó en un .reg junto al script y aquí se vuelve a aplicar. Si no había
  nada, se borra la clave y Windows deja de reconocer micrm3:.
#>
param(
    [string] $Carpeta = (Join-Path $env:LOCALAPPDATA 'miCRM3'),
    [string] $Protocolo = 'micrm3',
    [string] $Descargas = (Join-Path $env:TEMP 'miCRM3-adjuntos')
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

$script = Join-Path $Carpeta 'copiar-archivos.ps1'
# El de las capturas se instala con el otro, asi que se va con el otro
$capturas = Join-Path $Carpeta 'capturar-whatsapp.ps1'
if (Test-Path -LiteralPath $capturas) { Remove-Item -LiteralPath $capturas -Force }
if (Test-Path -LiteralPath $script) {
    Remove-Item -LiteralPath $script -Force
    Write-Host "  Borrado $script"
}

# Las copias de los adjuntos: son del cliente, no tienen por que quedarse en
# el disco de nadie despues de quitar esto.
if (Test-Path -LiteralPath $Descargas) {
    Remove-Item -LiteralPath $Descargas -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Borrada la carpeta de descargas $Descargas"
}

Write-Host '  Hecho.' -ForegroundColor Green
