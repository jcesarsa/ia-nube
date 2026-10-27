# Crea una instancia con GPU en RunPod, instala ComfyUI + FLUX.2 dev o Qwen-Image + la app web y abre el navegador.
# Uso: doble clic en Subir-FLUX2.bat o Subir-Qwen.bat (o: powershell -ExecutionPolicy Bypass -File subir.ps1 -Modelo qwen)
param(
    [ValidateSet("flux2", "qwen")][string]$Modelo = "flux2",
    [int]$MaxHoras = 4,           # la instancia se borra sola al llegar aqui, pase lo que pase
    [int]$InactividadMin = 60,    # ...o tras estos minutos sin generar nada
    [switch]$Comunidad,           # solo Community Cloud (por defecto: Secure y, si no hay GPUs, Community)
    [switch]$SoloSecure,          # no pasar a Community Cloud si Secure no tiene GPUs
    [int]$DiscoGb = 120,
    [double]$PrecioMax = 1.00,    # si RunPod asigna una GPU mas cara, se borra al instante
    [switch]$SinPreguntar         # no pide escribir SI (para lanzarlo de forma automatica)
)
. (Join-Path $PSScriptRoot "comun.ps1")

# Cada modelo: GPUs por orden de preferencia y ficheros por carpeta de ComfyUI.
# En cada carpeta se prueban las URLs en orden y se usa la primera que exista.
# Imagen propia con ComfyUI ya instalado (se construye en GitHub). Si no existe, se usa la base y se instala todo al arrancar.
$ImagenPropia = "ghcr.io/jcesarsa/ia-nube-comfyui:latest"
$ImagenBase = "runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04"
if ($Modelo -eq "flux2") {
    $Nombre = "FLUX.2 dev"
    # 48 GB: FLUX.2 dev en fp8 ocupa unos 35 GB solo el modelo.
    $Gpus = @("NVIDIA L40S", "NVIDIA RTX 6000 Ada Generation", "NVIDIA RTX A6000", "NVIDIA A40", "NVIDIA L40",
        "NVIDIA RTX PRO 6000 Blackwell Server Edition", "NVIDIA A100 80GB PCIe", "NVIDIA A100-SXM4-80GB", "NVIDIA H100 PCIe")
    $RamMin = 48
    $Precio = "0,45-1,00"
    $VramAltaMb = 75000   # con 80 GB o mas, los modelos se quedan en la GPU
    $Hf = "https://huggingface.co/Comfy-Org/Flux-2-Dev/resolve/main/split_files"
    $Ficheros = [ordered]@{
        diffusion_models = @("$Hf/diffusion_models/flux2_dev_fp8mixed.safetensors")
        text_encoders = @("$Hf/text_encoders/mistral_3_small_flux2_fp8.safetensors", "$Hf/text_encoders/mistral_3_small_flux2_bf16.safetensors")
        vae = @("$Hf/vae/flux2-vae.safetensors")
    }
    $Licencia = "https://huggingface.co/black-forest-labs/FLUX.2-dev"
} else {
    $Nombre = "Qwen-Image 2512"
    # Qwen-Image en fp8 (20 GB) + codificador (9 GB): con 48 GB va holgado; con 24 GB tambien funciona.
    # Sin GPUs caras (RTX PRO 6000, A100...): para Qwen no aportan y cuestan el doble.
    # Ordenadas de mas barata a mas cara (aprox.).
    $Gpus = @("NVIDIA A40", "NVIDIA RTX A6000", "NVIDIA GeForce RTX 4090", "NVIDIA L40", "NVIDIA L40S",
        "NVIDIA RTX 6000 Ada Generation", "NVIDIA GeForce RTX 5090")
    $RamMin = 24
    $Precio = "0,35-1,00"
    $VramAltaMb = 40000   # con 48 GB, modelo y codificador se quedan en la GPU
    $Hf = "https://huggingface.co/Comfy-Org/Qwen-Image/resolve/main/split_files"
    $Ficheros = [ordered]@{
        diffusion_models = @("$Hf/diffusion_models/qwen_image_2512_fp8_e4m3fn.safetensors", "$Hf/diffusion_models/qwen_image_fp8_e4m3fn.safetensors")
        text_encoders = @("$Hf/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors")
        vae = @("$Hf/vae/qwen_image_vae.safetensors")
        loras = @("https://huggingface.co/lightx2v/Qwen-Image-Lightning/resolve/main/Qwen-Image-Lightning-4steps-V2.0-bf16.safetensors")
    }
    $Licencia = "https://huggingface.co/Qwen/Qwen-Image-2512"
}
$NombrePod = "$Modelo-nube"

Write-Host "`n=== $Nombre en la nube: subir ===`n" -ForegroundColor Cyan

$script:ClaveRunPod = Get-Clave "RUNPOD_API_KEY" "Necesito tu clave de API de RunPod (runpod.io > Settings > API Keys)."
if (-not $script:ClaveRunPod) { throw "Sin clave de RunPod no puedo seguir." }

# 1. No crear una segunda instancia si ya hay una.
if (Test-Path $FichPod) {
    $guardado = Get-Content $FichPod -Raw | ConvertFrom-Json
    try {
        $p = Invoke-RunPod GET "/pods/$($guardado.id)"
        Write-Host "Ya tienes una instancia en marcha ($($p.desiredStatus), $($p.costPerHr) USD/h):" -ForegroundColor Yellow
        Write-Host "  $($guardado.url)"
        Write-Host "Usala o borrala con Bajar.bat antes de crear otra (solo una a la vez)."
        Start-Process $guardado.url
        exit 0
    } catch {
        if ((Get-Estado $_) -eq 404) { Remove-Item $FichPod } else { throw }
    }
}

# 2. Comprobaciones gratuitas antes de pagar nada.
Write-Host "Comprobando la clave de RunPod..."
try { $pods = Get-Pods } catch { throw "RunPod rechazo la clave (codigo $(Get-Estado $_)). Revisala en runpod.io > Settings > API Keys." }
if ($pods.Count -gt 0) {
    Write-Host "Aviso: ya tienes $($pods.Count) pod(s) en tu cuenta que pueden estar cobrando:" -ForegroundColor Yellow
    Show-Pods $pods
}

function Test-Modelo($url, $token) {
    # Pide solo las cabeceras. Sigue las redirecciones de Hugging Face (301/307/308, p. ej. repos renombrados)
    # pero no la del CDN (302), que es la que trae el tamano en x-linked-size. Devuelve el tamano,
    # 1 si existe pero no se sabe el tamano, o el codigo HTTP en negativo si no se puede descargar.
    for ($i = 0; $i -lt 4; $i++) {
        $a = @("-sI", "--max-time", "30")
        if ($token) { $a += @("-H", "Authorization: Bearer $token") }
        $salida = & curl.exe @a $url 2>$null
        $codigo = 0; $tam = [int64]0; $destino = $null
        foreach ($l in $salida) {
            if ($l -match '^HTTP/\S+\s+(\d+)') { $codigo = [int]$matches[1] }
            elseif ($l -match '^x-linked-size:\s*(\d+)') { $tam = [int64]$matches[1] }
            elseif ($l -match '^location:\s*(\S+)') { $destino = $matches[1] }
        }
        if (@(301, 307, 308) -contains $codigo -and $destino) {
            if ($destino.StartsWith("/")) { $destino = ([Uri]$url).GetLeftPart([UriPartial]::Authority) + $destino }
            $url = $destino
            continue
        }
        if ($codigo -ge 200 -and $codigo -lt 400) { if ($tam -gt 1) { return $tam } else { return [int64]1 } }
        return -$codigo
    }
    return [int64]1
}

Write-Host "Comprobando los modelos en Hugging Face..."
$HfToken = [Environment]::GetEnvironmentVariable("HF_TOKEN", "User")
$pedido = $false
$lista = @()
$total = [int64]0
foreach ($carpeta in $Ficheros.Keys) {
    $elegida = $null
    foreach ($u in $Ficheros[$carpeta]) {
        $t = Test-Modelo $u $HfToken
        if (($t -eq -401 -or $t -eq -403) -and -not $pedido) {
            $pedido = $true
            $HfToken = Get-Clave "HF_TOKEN" ("Hugging Face pide iniciar sesion. Acepta la licencia en $Licencia " +
                "y crea un token de lectura en https://huggingface.co/settings/tokens")
            $t = Test-Modelo $u $HfToken
        }
        if ($t -gt 0) { $elegida = $u; break }
    }
    if (-not $elegida) { throw "No puedo descargar el fichero de '$carpeta' de Hugging Face. Revisa el token y la licencia ($Licencia)." }
    Write-Host ("  {0}: {1}" -f $carpeta, (Split-Path $elegida -Leaf))
    $lista += "$carpeta|$elegida"
    if ($t -eq 1 -or $total -lt 0) { $total = -1 } else { $total += $t }
}
if ($total -lt 0) { $total = 0 }   # tamano desconocido: sin porcentaje de descarga
else { Write-Host ("  Total a descargar: {0:N1} GB" -f ($total / 1GB)) }
if (-not $HfToken) { $HfToken = "" }

function Test-ImagenGhcr($imagen) {
    # Comprueba sin credenciales que la imagen publica existe en GitHub Container Registry.
    if ($imagen -notmatch '^ghcr\.io/([^:]+):(.+)$') { return $false }
    $repo = $matches[1]; $tag = $matches[2]
    try {
        $tok = (Invoke-RestMethod "https://ghcr.io/token?scope=repository:$($repo):pull").token
        Invoke-WebRequest -Method Head -UseBasicParsing -Uri "https://ghcr.io/v2/$repo/manifests/$tag" -Headers @{
            Authorization = "Bearer $tok"; Accept = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json" } | Out-Null
        return $true
    } catch { return $false }
}
if (Test-ImagenGhcr $ImagenPropia) { $Imagen = $ImagenPropia; Write-Host "  Imagen: $Imagen (ComfyUI ya instalado)" }
else { $Imagen = $ImagenBase; Write-Host "  Imagen propia no disponible; uso la base e instalo ComfyUI al arrancar (unos minutos mas)" -ForegroundColor Yellow }

# 3. Empaquetar los ficheros de la instancia (carpeta remote) en una variable de entorno.
$tgz = Join-Path $env:TEMP "nube-remote.tgz"
& tar.exe -czf $tgz -C $PSScriptRoot remote
if ($LASTEXITCODE -ne 0) { throw "No pude empaquetar la carpeta remote (tar.exe)." }
$boot = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tgz))
Remove-Item $tgz

$bytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$AppToken = -join ($bytes | ForEach-Object { $_.ToString("x2") })

# 4. Confirmacion explicita: desde aqui se paga.
$nubes = if ($Comunidad) { @("COMMUNITY") } elseif ($SoloSecure) { @("SECURE") } else { @("SECURE", "COMMUNITY") }
Write-Host "`nVoy a crear una instancia de pago en RunPod para $($Nombre):" -ForegroundColor Cyan
Write-Host "  GPU (la primera libre): $($Gpus -join ', ')"
Write-Host "  Nube: $($nubes -join ', si no hay GPUs: ')   Disco temporal: $DiscoGb GB (se borra con la instancia)   Sin volumen persistente"
Write-Host "  Coste aproximado: $Precio USD por hora (maximo $PrecioMax; si toca mas cara se borra al instante) segun la GPU que toque (veras el precio exacto al crearla)"
Write-Host "  Se borrara sola a las $MaxHoras h, o tras $InactividadMin min sin generar."
$ok = if ($SinPreguntar) { "SI" } else { Read-Host "Escribe SI para crearla" }
if ($ok -ne "SI") { Write-Host "Cancelado. No se ha creado nada."; exit 0 }

$cuerpo = @{
    name = $NombrePod
    imageName = $Imagen
    cloudType = $nubes[0]
    gpuTypeIds = $Gpus
    gpuTypePriority = "custom"
    gpuCount = 1
    allowedCudaVersions = @("12.8", "12.9", "13.0")
    containerDiskInGb = $DiscoGb
    volumeInGb = 0
    minRAMPerGPU = $RamMin
    ports = @("7860/http")
    env = @{
        BOOT_B64 = $boot; APP_TOKEN = $AppToken; HF_TOKEN = $HfToken
        MODELO = $Modelo; MODELOS = ($lista -join ";"); BYTES_TOTAL = "$total"
        MAX_HORAS = "$MaxHoras"; INACTIVIDAD_MIN = "$InactividadMin"; VRAM_ALTA_MB = "$VramAltaMb"
    }
    dockerStartCmd = @("bash", "-c",
        'mkdir -p /opt && echo "$BOOT_B64" | base64 -d | tar -xz -C /opt && find /opt/remote -type f -exec sed -i "s/\r$//" {} + && exec bash /opt/remote/setup.sh')
}

$pod = $null
foreach ($n in $nubes) {
    $cuerpo.cloudType = $n
    Write-Host "Creando la instancia en $n Cloud..."
    try { $pod = Invoke-RunPod POST "/pods" $cuerpo; break }
    catch {
        $msg = $_.ErrorDetails.Message
        if ($msg -match "no instances currently available" -and $n -ne $nubes[-1]) {
            Write-Host "  No hay GPUs libres en $n Cloud; pruebo en la siguiente." -ForegroundColor Yellow
            continue
        }
        throw "RunPod no creo la instancia (codigo $(Get-Estado $_)): $msg`nSi dice que no hay GPUs libres, prueba otra vez en unos minutos."
    }
}
if ([double]$pod.costPerHr -gt $PrecioMax) {
    Write-Host ("  RunPod asigno una GPU de {0} USD/h, por encima del maximo de {1}. La borro ya." -f $pod.costPerHr, $PrecioMax) -ForegroundColor Red
    Invoke-RunPod DELETE "/pods/$($pod.id)" | Out-Null
    throw "Instancia descartada por precio. Prueba en unos minutos o sube el limite con -PrecioMax."
}
$Url = "https://$($pod.id)-7860.proxy.runpod.net"
@{ id = $pod.id; modelo = $Modelo; token = $AppToken; base = $Url; url = "$Url/?t=$AppToken"; creada = (Get-Date).ToString("s") } |
    ConvertTo-Json | Set-Content $FichPod -Encoding UTF8
Write-Host ("  Creada: {0} en {1} Cloud, {2} USD/h" -f $pod.id, $cuerpo.cloudType, $pod.costPerHr) -ForegroundColor Green
Write-Host "  Si cierras esta ventana, la instancia sigue (y cobra). Para borrarla: Bajar.bat`n"

# 5. Esperar a que termine de prepararse.
$inicio = Get-Date
$listo = $false
while (((Get-Date) - $inicio).TotalMinutes -lt 35) {
    Start-Sleep 15
    $min = [int]((Get-Date) - $inicio).TotalMinutes
    try {
        $h = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec 10
        $txt = $h.fase
        if ($h.descarga -ne $null -and -not $h.listo) { $txt += " (modelos: $($h.descarga) %)" }
        Write-Host "  [$min min] $txt"
        if ($h.listo) { $listo = $true; break }
        if ($h.fase -like "ERROR*") {
            # Guardar los registros de la instancia para poder ver la causa.
            $log = Join-Path $PSScriptRoot "error_instancia.log"
            try {
                Invoke-WebRequest -Uri "$Url/api/registro" -Headers @{ "X-Token" = $AppToken } -UseBasicParsing -OutFile $log
                Write-Host "  Registros de la instancia guardados en $log" -ForegroundColor Yellow
                Get-Content $log -Tail 25 | ForEach-Object { Write-Host "    $_" }
            } catch { Write-Host "  No pude leer los registros de la instancia." }
            break
        }
    } catch { Write-Host "  [$min min] Arrancando el contenedor..." }
}

if ($listo) {
    Write-Host "`nLista en $([int]((Get-Date) - $inicio).TotalMinutes) min. Abriendo la app:" -ForegroundColor Green
    Write-Host "  $Url/?t=$AppToken"
    Write-Host "La primera imagen tarda mas (carga el modelo en la GPU). Cuando acabes: Bajar.bat"
    Start-Process "$Url/?t=$AppToken"
} else {
    Write-Host "`nLa instancia no quedo lista. Para no pagar por nada, borrala ya con Bajar.bat" -ForegroundColor Red
    Write-Host "(Si la preparacion fallo, se borrara sola en 20 min de todos modos.)"
}
