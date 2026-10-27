# Funciones compartidas por subir.ps1 y bajar.ps1.
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Api = "https://rest.runpod.io/v1"
$FichPod = Join-Path $PSScriptRoot "pod.json"

function Get-Clave($nombre, $explicacion) {
    $v = [Environment]::GetEnvironmentVariable($nombre, "User")
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($nombre, "Process") }
    if ($v) { return $v }
    Write-Host $explicacion -ForegroundColor Yellow
    $seg = Read-Host "Pega $nombre (no se mostrara)" -AsSecureString
    $v = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($seg))
    if (-not $v) { return "" }
    $r = Read-Host "Guardar $nombre en tu usuario de Windows para no volver a pedirla? (s/N)"
    if ($r -match '^[sS]') { [Environment]::SetEnvironmentVariable($nombre, $v, "User") }
    return $v
}

function Invoke-RunPod($metodo, $ruta, $cuerpo = $null) {
    $h = @{ Authorization = "Bearer $script:ClaveRunPod" }
    if ($cuerpo) {
        $json = $cuerpo | ConvertTo-Json -Depth 6
        return Invoke-RestMethod -Method $metodo -Uri "$Api$ruta" -Headers $h -ContentType "application/json" `
            -Body ([Text.Encoding]::UTF8.GetBytes($json))
    }
    return Invoke-RestMethod -Method $metodo -Uri "$Api$ruta" -Headers $h
}

function Get-Estado($e) {
    # Devuelve el codigo HTTP de una excepcion de Invoke-WebRequest/RestMethod (0 si no hubo respuesta).
    try { return [int]$e.Exception.Response.StatusCode } catch { return 0 }
}

function Get-Pods {
    $r = Invoke-RunPod GET "/pods"
    # PowerShell 5.1 convierte una lista vacia en un elemento vacio: se filtra por id.
    return @(@($r) | Where-Object { $_ -and $_.id })
}

function Show-Pods($pods) {
    foreach ($p in $pods) {
        Write-Host ("  - {0} ({1}) estado {2}, {3} USD/h" -f $p.name, $p.id, $p.desiredStatus, $p.costPerHr)
    }
}
