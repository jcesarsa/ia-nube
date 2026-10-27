# Imagen con todo instalado salvo los modelos (se descargan al arrancar: desde Hugging Face va más rápido
# que meterlos en la imagen, y así la imagen se puede publicar sin problemas de licencia).
FROM runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04

ARG COMFY_VERSION=v0.42.5
ENV DEBIAN_FRONTEND=noninteractive PIP_ROOT_USER_ACTION=ignore PIP_NO_CACHE_DIR=1 COMFY_VERSION=${COMFY_VERSION}

RUN apt-get update -qq && apt-get install -y -qq aria2 git zip && rm -rf /var/lib/apt/lists/* \
 && wget -qO /usr/local/bin/runpodctl https://github.com/runpod/runpodctl/releases/latest/download/runpodctl-linux-amd64 \
 && chmod +x /usr/local/bin/runpodctl

RUN git clone -q --depth 1 --branch ${COMFY_VERSION} https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
 && pip install -q -r /opt/ComfyUI/requirements.txt aiohttp \
 && touch /opt/.imagen-preparada

COPY remote /opt/remote
RUN find /opt/remote -type f -exec sed -i 's/\r$//' {} +

CMD ["bash", "/opt/remote/setup.sh"]
