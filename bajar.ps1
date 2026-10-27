# Descarga las imagenes generadas y borra la instancia de RunPod por completo. Comprueba que no queda nada cobrando.
# Uso: doble clic en Bajar.bat (o: powershell -ExecutionPolicy Bypass -File bajar.ps1 [-SinDescargar])
param([switch]$SinDescargar, [switch]$SinPreguntar)
. (Join-Path $PSScriptRoot "comun.ps1")

Write-Host "`n=== Imagenes en la nube: bajar ===`n" -ForegroundColor Cyan
$script:ClaveRunPod = Get-Clave "RUNPOD_API_KEY" "Necesito tu clave de API de RunPod (runpod.io > Settings > API Keys)."

$objetivos = @()
$guardado = $null
if (Test-Path $FichPod) {
    $guardado = Get-Content $FichPod -Raw | ConvertFrom-Json
    $objetivos += $guardado.id
}
# Tambien cualquier otra instancia creada por estos scripts (por si se perdio pod.json).
foreach ($p in Get-Pods) { if (@("flux2-nube", "qwen-nube") -contains $p.name -and $objetivos -notcontains $p.id) { $objetivos += $p.id } }

if ($objetivos.Count -eq 0) { Write-Host "No hay ninguna instancia de FLUX.2 ni de Qwen-Image creada." }

foreach ($id in $objetivos) {
    if (-not $SinDescargar -and $guardado -and $guardado.id -eq $id) {
        $carpeta = Join-Path $PSScriptRoot "imagenes"
        New-Item -ItemType Directory -Force $carpeta | Out-Null
        $zip = Join-Path $carpeta ("{0}_{1}.zip" -f $guardado.modelo, (Get-Date -Format "yyyyMMdd_HHmm"))
        Write-Host "Descargando las imagenes a $zip ..."
        try {
            Invoke-WebRequest -Uri "$($guardado.base)/api/imagenes.zip?t=$($guardado.token)" -OutFile $zip -UseBasicParsing -TimeoutSec 600
            Write-Host ("  OK ({0:N1} MB)" -f ((Get-Item $zip).Length / 1MB))
        } catch {
            Write-Host "  No pude descargarlas (la instancia no responde)." -ForegroundColor Yellow
            if (-not $SinPreguntar -and (Read-Host "Borrar igualmente? (S/n)") -match '^[nN]') { Write-Host "No he borrado nada."; exit 1 }
        }
    }
    Write-Host "Borrando la instancia $id ..."
    try { Invoke-RunPod DELETE "/pods/$id" | Out-Null }
    catch { if ((Get-Estado $_) -ne 404) { throw } }
    # Confirmar que ya no existe.
    $borrada = $false
    for ($i = 0; $i -lt 24; $i++) {
        try { Invoke-RunPod GET "/pods/$id" | Out-Null; Start-Sleep 5 }
        catch { if ((Get-Estado $_) -eq 404) { $borrada = $true; break } else { Start-Sleep 5 } }
    }
    if ($borrada) { Write-Host "  Borrada." -ForegroundColor Green }
    else { Write-Host "  RunPod aun la muestra. Revisa https://www.runpod.io/console/pods" -ForegroundColor Red }
}
if ($guardado -and $objetivos -contains $guardado.id) { Remove-Item $FichPod -ErrorAction SilentlyContinue }

# Repaso final: nada mas debe estar cobrando.
$quedan = Get-Pods
$vols = @()
try { $vols = @(@(Invoke-RunPod GET "/networkvolumes") | Where-Object { $_ -and $_.id }) } catch {}
if ($quedan.Count -eq 0 -and $vols.Count -eq 0) {
    Write-Host "`nTu cuenta de RunPod no tiene ningun pod ni volumen: no se esta cobrando nada." -ForegroundColor Green
} else {
    Write-Host "`nOjo, en tu cuenta sigue habiendo recursos que pueden cobrar:" -ForegroundColor Yellow
    Show-Pods $quedan
    foreach ($v in $vols) { Write-Host "  - volumen $($v.name) ($($v.size) GB)" }
}
