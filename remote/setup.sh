#!/bin/bash
# Prepara la instancia: ComfyUI + el modelo elegido (FLUX.2 o Qwen-Image) + app web. Lo lanza el arranque del pod.
set -uo pipefail
R=/opt/remote
exec > >(tee -a /opt/setup.log) 2>&1
fase() { echo "$1" > /opt/estado.txt; echo "[$(date +%T)] $1"; }
fallo() { fase "ERROR: $1"; sleep infinity; }

export DEBIAN_FRONTEND=noninteractive PIP_ROOT_USER_ACTION=ignore
touch /opt/ultima_actividad

# Con la imagen propia (ia-nube-comfyui) ya está todo instalado y estos pasos se saltan.
PREPARADA=0; [ -f /opt/.imagen-preparada ] && PREPARADA=1
if [ $PREPARADA = 0 ]; then
  fase "Instalando herramientas"
  apt-get update -qq && apt-get install -y -qq aria2 git zip >/dev/null || fallo "no se pudo instalar aria2/git"
  if ! command -v runpodctl >/dev/null; then
    wget -qO /usr/local/bin/runpodctl https://github.com/runpod/runpodctl/releases/latest/download/runpodctl-linux-amd64 \
      && chmod +x /usr/local/bin/runpodctl
  fi
  pip install -q aiohttp || fallo "no se pudo instalar aiohttp"
fi

# Vigilante (autodestrucción) y app web desde el primer minuto, para ver el progreso.
nohup bash $R/vigilante.sh > /opt/vigilante.log 2>&1 &
nohup python3 $R/app.py > /opt/app.log 2>&1 &

C=/opt/ComfyUI
fase "Descargando modelos e instalando ComfyUI"
# Se resuelve la URL firmada del CDN con el token (curl no reenvía el token a otro dominio)
# y aria2 descarga esa URL sin cabeceras, con muchas conexiones en paralelo.
firmada() {
  local h=()
  [ -n "${HF_TOKEN:-}" ] && h=(-H "Authorization: Bearer $HF_TOKEN")
  curl -sfL "${h[@]}" -r 0-0 -o /dev/null -w '%{url_effective}' "$1"
}
: > /opt/descargas.txt
# MODELOS = "carpeta|url;carpeta|url;..."
IFS=';' read -ra LISTA <<< "$MODELOS"
for par in "${LISTA[@]}"; do
  d=${par%%|*}; u=${par#*|}
  mkdir -p "$C/models/$d"
  f=$(firmada "$u") || fallo "Hugging Face no deja descargar $(basename "$u") (revisa el token y la licencia)"
  printf '%s\n  dir=%s\n  out=%s\n' "$f" "$C/models/$d" "$(basename "$u")" >> /opt/descargas.txt
done
# Se guarda el total esperado para que la app muestre el porcentaje.
echo "${BYTES_TOTAL:-0}" > /opt/bytes_total
# Los modelos se descargan a la vez que se instala ComfyUI.
aria2c -i /opt/descargas.txt -j3 -x16 -s16 -k8M --file-allocation=none --max-tries=5 --retry-wait=5 \
  --console-log-level=warn --summary-interval=60 --auto-file-renaming=false --allow-overwrite=true &
DL=$!

if [ $PREPARADA = 0 ] && [ ! -d $C/.git ]; then
  # Versión fija de ComfyUI: la última del repositorio puede romperse sin aviso.
  git clone -q --depth 1 --branch "${COMFY_VERSION:-v0.42.5}" https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI.tmp || fallo "no se pudo clonar ComfyUI ${COMFY_VERSION:-v0.42.5}"
  cp -a /opt/ComfyUI.tmp/. $C/ && rm -rf /opt/ComfyUI.tmp
fi
[ $PREPARADA = 0 ] && { pip install -q -r $C/requirements.txt || fallo "no se pudieron instalar las dependencias de ComfyUI"; }
# Comprobar que PyTorch ve la GPU antes de seguir (driver del servidor demasiado antiguo, GPU no soportada...).
python3 -c "import torch; print('torch', torch.__version__, 'cuda', torch.version.cuda); assert torch.cuda.is_available(), 'CUDA no disponible'; print('GPU', torch.cuda.get_device_name(0)); torch.zeros(1).cuda()" \
  || { bash $R/eliminar.sh "PyTorch no puede usar la GPU de este servidor"; fallo "PyTorch no puede usar la GPU de este servidor (instancia borrada)"; }

wait $DL || fallo "falló la descarga de modelos (revisa el token de Hugging Face y la licencia)"
rm -f /opt/descargas.txt

fase "Arrancando ComfyUI"
# Si la GPU tiene memoria de sobra, los modelos se quedan en ella entre imágenes (no se recargan).
VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
EXTRA="${COMFY_FLAGS:---fast fp8_matrix_mult}"
[ "${VRAM_MB:-0}" -ge "${VRAM_ALTA_MB:-999999}" ] && EXTRA="$EXTRA --highvram"
echo "VRAM ${VRAM_MB} MB, opciones de ComfyUI: $EXTRA"
cd $C
nohup python3 main.py --listen 127.0.0.1 --port 8188 --output-directory /opt/salidas --disable-assets $EXTRA > /opt/comfy.log 2>&1 &
COMFY=$!
for i in $(seq 1 180); do
  curl -sf http://127.0.0.1:8188/system_stats >/dev/null && break
  kill -0 $COMFY 2>/dev/null || fallo "ComfyUI se cerró al arrancar (mira /opt/comfy.log)"
  sleep 2
done
curl -sf http://127.0.0.1:8188/system_stats >/dev/null || fallo "ComfyUI no respondió"
# Generación mínima para dejar los modelos cargados: así la primera imagen de verdad ya sale rápida.
fase "Cargando el modelo en la GPU"
python3 $R/calentar.py || echo "Aviso: el calentamiento falló (la primera imagen tardará algo más)"
rm -f /opt/salidas/calentamiento*
fase "LISTO"
touch /opt/ultima_actividad
wait $COMFY
fase "ERROR: ComfyUI se detuvo (mira /opt/comfy.log)"
sleep infinity
