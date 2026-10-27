"""App web de FLUX.2 / Qwen-Image en la nube. Habla con ComfyUI en 127.0.0.1:8188 y solo deja pasar a quien tenga el token."""
import io, os, random, subprocess, time, zipfile
from pathlib import Path
import aiohttp
from aiohttp import web

COMFY = "http://127.0.0.1:8188"
TOKEN = os.environ.get("APP_TOKEN", "")
AQUI = Path(__file__).parent
SALIDAS = Path("/opt/salidas")
MODELOS = Path("/opt/ComfyUI/models")
MODELO = os.environ.get("MODELO", "flux2")
# Nombre de fichero por carpeta de ComfyUI, sacado de MODELOS = "carpeta|url;carpeta|url;..."
ARCH = {d: os.path.basename(u) for d, u in (x.split("|", 1) for x in os.environ.get("MODELOS", "").split(";") if "|" in x)}
NODOS = {
    "flux2": ["UNETLoader", "CLIPLoader", "VAELoader", "CLIPTextEncode", "LoadImage", "ImageScaleToTotalPixels",
              "VAEEncode", "ReferenceLatent", "FluxGuidance", "BasicGuider", "KSamplerSelect", "Flux2Scheduler",
              "RandomNoise", "EmptyFlux2LatentImage", "SamplerCustomAdvanced", "VAEDecode", "SaveImage"],
    "qwen": ["UNETLoader", "LoraLoaderModelOnly", "CLIPLoader", "VAELoader", "ModelSamplingAuraFlow", "CLIPTextEncode",
             "EmptySD3LatentImage", "KSampler", "VAEDecode", "SaveImage"],
}[MODELO]
info_nodos = {}


def leer(p, defecto=""):
    try:
        return Path(p).read_text().strip()
    except OSError:
        return defecto


def actividad():
    Path("/opt/ultima_actividad").touch()


@web.middleware
async def auth(req, handler):
    if req.path == "/health":
        return await handler(req)
    t = req.query.get("t") or req.cookies.get("t") or req.headers.get("X-Token")
    if not TOKEN or t != TOKEN:
        return web.Response(status=401, text="Falta el token. Abre el enlace que te dio subir.ps1.")
    if req.query.get("t") and req.path == "/":
        r = web.HTTPFound("/")
        r.set_cookie("t", TOKEN, max_age=86400, httponly=True, secure=True, samesite="Strict")
        raise r
    return await handler(req)


def progreso_descarga():
    total = int(leer("/opt/bytes_total", "0") or 0)
    # st_blocks cuenta solo lo escrito (aria2 deja ficheros dispersos del tamaño final)
    hecho = sum(f.stat().st_blocks * 512 for d in ARCH
                for f in (MODELOS / d).glob("*") if f.is_file()) if MODELOS.exists() else 0
    return min(99, round(100 * hecho / total)) if total else None


async def health(req):
    fase = leer("/opt/estado.txt", "Arrancando")
    listo = fase.startswith("LISTO")
    if listo and not info_nodos:
        await cargar_nodos()
    faltan = [n for n in NODOS if n not in info_nodos] if listo else []
    if faltan:
        fase, listo = "ERROR: esta versión de ComfyUI no tiene los nodos " + ", ".join(faltan), False
    return web.json_response({"listo": listo, "fase": fase, "descarga": progreso_descarga()})


async def cargar_nodos():
    async with aiohttp.ClientSession() as s:
        async with s.get(f"{COMFY}/object_info") as r:
            info_nodos.update(await r.json())


def completar(clase, entradas):
    """Rellena con su valor por defecto las entradas obligatorias que falten (por si ComfyUI añade alguna)."""
    req = info_nodos.get(clase, {}).get("input", {}).get("required", {})
    for nombre, spec in req.items():
        if nombre in entradas or not isinstance(spec, list):
            continue
        if isinstance(spec[0], list) and spec[0]:
            entradas[nombre] = spec[0][0]
        elif len(spec) > 1 and isinstance(spec[1], dict) and "default" in spec[1]:
            entradas[nombre] = spec[1]["default"]
    return {"class_type": clase, "inputs": entradas}


def semilla(p):
    s = str(p.get("seed", "")).strip()
    return int(s) if s.lstrip("-").isdigit() and s != "-1" else random.randint(0, 2**48)


def flujo(p):
    return flujo_qwen(p) if MODELO == "qwen" else flujo_flux2(p)


def flujo_qwen(p):
    w, h = int(p.get("width", 1328)), int(p.get("height", 1328))
    seed = semilla(p)
    rapido = bool(p.get("rapido")) and "loras" in ARCH
    g = {
        "1": completar("UNETLoader", {"unet_name": ARCH["diffusion_models"], "weight_dtype": "default"}),
        "2": completar("CLIPLoader", {"clip_name": ARCH["text_encoders"], "type": "qwen_image"}),
        "3": completar("VAELoader", {"vae_name": ARCH["vae"]}),
    }
    modelo = ["1", 0]
    if rapido:
        g["1b"] = completar("LoraLoaderModelOnly", {"model": modelo, "lora_name": ARCH["loras"], "strength_model": 1.0})
        modelo = ["1b", 0]
    g.update({
        "4": completar("ModelSamplingAuraFlow", {"model": modelo, "shift": 3.1}),
        "5": completar("CLIPTextEncode", {"text": p.get("prompt", ""), "clip": ["2", 0]}),
        "6": completar("CLIPTextEncode", {"text": p.get("negativo", ""), "clip": ["2", 0]}),
        "7": completar("EmptySD3LatentImage", {"width": w, "height": h, "batch_size": 1}),
        "8": completar("KSampler", {"model": ["4", 0], "seed": seed, "steps": int(p.get("steps", 4 if rapido else 30)),
                                    "cfg": 1.0 if rapido else float(p.get("guidance", 2.5)), "sampler_name": "euler",
                                    "scheduler": "simple", "positive": ["5", 0], "negative": ["6", 0],
                                    "latent_image": ["7", 0], "denoise": 1.0}),
        "9": completar("VAEDecode", {"samples": ["8", 0], "vae": ["3", 0]}),
        "10": completar("SaveImage", {"images": ["9", 0], "filename_prefix": "qwen"}),
    })
    return g, seed


def flujo_flux2(p):
    w, h = int(p.get("width", 1024)), int(p.get("height", 1024))
    seed = semilla(p)
    g = {
        "1": completar("UNETLoader", {"unet_name": ARCH["diffusion_models"], "weight_dtype": "default"}),
        "2": completar("CLIPLoader", {"clip_name": ARCH["text_encoders"], "type": "flux2"}),
        "3": completar("VAELoader", {"vae_name": ARCH["vae"]}),
        "4": completar("CLIPTextEncode", {"text": p.get("prompt", ""), "clip": ["2", 0]}),
    }
    cond = ["4", 0]
    for i, nombre in enumerate(p.get("refs", [])[:4]):
        a, b, c, d = (f"r{i}{x}" for x in "abcd")
        g[a] = completar("LoadImage", {"image": nombre})
        g[b] = completar("ImageScaleToTotalPixels", {"image": [a, 0], "upscale_method": "lanczos", "megapixels": 1.0})
        g[c] = completar("VAEEncode", {"pixels": [b, 0], "vae": ["3", 0]})
        g[d] = completar("ReferenceLatent", {"conditioning": cond, "latent": [c, 0]})
        cond = [d, 0]
    g.update({
        "5": completar("FluxGuidance", {"conditioning": cond, "guidance": float(p.get("guidance", 4.0))}),
        "6": completar("BasicGuider", {"model": ["1", 0], "conditioning": ["5", 0]}),
        "7": completar("KSamplerSelect", {"sampler_name": "euler"}),
        "8": completar("Flux2Scheduler", {"steps": int(p.get("steps", 20)), "width": w, "height": h}),
        "9": completar("RandomNoise", {"noise_seed": seed}),
        "10": completar("EmptyFlux2LatentImage", {"width": w, "height": h, "batch_size": 1}),
        "11": completar("SamplerCustomAdvanced", {"noise": ["9", 0], "guider": ["6", 0], "sampler": ["7", 0],
                                                  "sigmas": ["8", 0], "latent_image": ["10", 0]}),
        "12": completar("VAEDecode", {"samples": ["11", 0], "vae": ["3", 0]}),
        "13": completar("SaveImage", {"images": ["12", 0], "filename_prefix": "flux2"}),
    })
    return g, seed


async def generar(req):
    actividad()
    p = await req.json()
    if not info_nodos:
        await cargar_nodos()
    g, seed = flujo(p)
    async with aiohttp.ClientSession() as s:
        async with s.post(f"{COMFY}/prompt", json={"prompt": g}) as r:
            d = await r.json()
            if r.status != 200:
                return web.json_response({"error": d}, status=400)
    return web.json_response({"id": d["prompt_id"], "seed": seed})


async def subir(req):
    actividad()
    form = await req.post()
    f = form["image"]
    datos = aiohttp.FormData()
    datos.add_field("image", f.file.read(), filename=f.filename, content_type=f.content_type)
    async with aiohttp.ClientSession() as s:
        async with s.post(f"{COMFY}/upload/image", data=datos) as r:
            return web.json_response(await r.json())


async def trabajo(req):
    actividad()
    pid = req.match_info["id"]
    async with aiohttp.ClientSession() as s:
        async with s.get(f"{COMFY}/history/{pid}") as r:
            h = await r.json()
        if pid not in h:
            async with s.get(f"{COMFY}/queue") as r:
                q = await r.json()
            corriendo = any(x[1] == pid for x in q.get("queue_running", []))
            return web.json_response({"estado": "generando" if corriendo else "en cola"})
    item = h[pid]
    st = item.get("status", {})
    if st.get("status_str") == "error":
        msgs = [m[1].get("exception_message", "") for m in st.get("messages", []) if m[0] == "execution_error"]
        return web.json_response({"estado": "error", "error": " ".join(msgs) or "error en ComfyUI"})
    imgs = [i["filename"] for o in item.get("outputs", {}).values() for i in o.get("images", []) if i.get("type") == "output"]
    return web.json_response({"estado": "hecho", "imagenes": imgs})


async def imagen(req):
    f = SALIDAS / Path(req.match_info["nombre"]).name
    if not f.is_file():
        raise web.HTTPNotFound()
    return web.FileResponse(f)


async def lista(req):
    fs = sorted(SALIDAS.glob("*.png"), key=lambda f: f.stat().st_mtime, reverse=True) if SALIDAS.exists() else []
    return web.json_response([f.name for f in fs])


async def zip_salidas(req):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for f in SALIDAS.glob("*.png") if SALIDAS.exists() else []:
            z.write(f, f.name)
    return web.Response(body=buf.getvalue(), content_type="application/zip",
                        headers={"Content-Disposition": f"attachment; filename={MODELO}_imagenes.zip"})


async def estado(req):
    limite = int(leer("/opt/limite", "0") or 0)
    inact = int(leer("/opt/inactividad_s", "0") or 0)
    ultima = os.path.getmtime("/opt/ultima_actividad") if os.path.exists("/opt/ultima_actividad") else time.time()
    ahora = time.time()
    return web.json_response({
        "modelo": MODELO, "rapido": "loras" in ARCH,
        "gpu": os.environ.get("RUNPOD_GPU_NAME") or leer("/opt/gpu", ""),
        "min_hasta_limite": max(0, round((limite - ahora) / 60)) if limite else None,
        "min_hasta_inactividad": max(0, round((ultima + inact - ahora) / 60)) if inact else None,
    })


async def destruir(req):
    subprocess.Popen(["bash", str(AQUI / "eliminar.sh"), "pedido desde la app web"])
    return web.json_response({"ok": True})


async def registro(req):
    """Últimas líneas de los registros, para diagnosticar fallos de arranque."""
    partes = []
    for f in ("/opt/setup.log", "/opt/comfy.log", "/opt/vigilante.log"):
        try:
            lineas = Path(f).read_text(errors="replace").splitlines()[-60:]
        except OSError:
            continue
        partes.append(f"===== {f} =====\n" + "\n".join(lineas))
    return web.Response(text="\n\n".join(partes) or "Sin registros todavía")


async def index(req):
    return web.FileResponse(AQUI / "index.html")


def main():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
        Path("/opt/gpu").write_text(out)
    except Exception:
        pass
    app = web.Application(middlewares=[auth], client_max_size=50 * 2**20)
    app.add_routes([
        web.get("/", index), web.get("/health", health), web.get("/api/estado", estado),
        web.post("/api/generar", generar), web.post("/api/subir", subir), web.get("/api/trabajo/{id}", trabajo),
        web.get("/api/imagen/{nombre}", imagen), web.get("/api/lista", lista),
        web.get("/api/imagenes.zip", zip_salidas), web.post("/api/destruir", destruir),
        web.get("/api/registro", registro),
    ])
    web.run_app(app, host="0.0.0.0", port=7860, access_log=None)


if __name__ == "__main__":
    main()
