"""Lanza una imagen pequeña de 1 paso para cargar los modelos en la GPU antes de dar la instancia por lista."""
import json, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import app

COMFY = "http://127.0.0.1:8188"


def pedir(ruta, datos=None):
    req = urllib.request.Request(COMFY + ruta, data=json.dumps(datos).encode() if datos else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


app.info_nodos.update(pedir("/object_info"))
g, _ = app.flujo({"prompt": "calentamiento", "width": 512, "height": 512, "steps": 1, "rapido": True})
for nodo in g.values():
    if nodo["class_type"] == "SaveImage":
        nodo["inputs"]["filename_prefix"] = "calentamiento"
pid = pedir("/prompt", {"prompt": g})["prompt_id"]
t0 = time.time()
while time.time() - t0 < 600:
    h = pedir(f"/history/{pid}")
    if pid in h:
        estado = h[pid].get("status", {}).get("status_str")
        print(f"Calentamiento: {estado} en {time.time() - t0:.0f} s")
        sys.exit(0 if estado == "success" else 1)
    time.sleep(2)
sys.exit(1)
