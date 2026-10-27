# Generar imágenes en la nube (FLUX.2 dev o Qwen-Image)

Crea una máquina con GPU en RunPod, la prepara sola en unos 10-15 minutos, abre la app en el navegador y, al terminar, la borra por completo.

## Una sola vez
1. Crea una cuenta en https://www.runpod.io y añade saldo (mínimo 10 USD).
2. Crea una clave de API en RunPod > Settings > API Keys (permiso "All" o "Read/Write").
3. Solo si los modelos lo piden: crea un token de lectura en https://huggingface.co/settings/tokens y acepta la licencia del modelo (FLUX.2-dev: https://huggingface.co/black-forest-labs/FLUX.2-dev).

Los scripts te piden las claves la primera vez y te ofrecen guardarlas en tu usuario de Windows.

## Cada vez
- **Subir-FLUX2.bat** o **Subir-Qwen.bat**: comprueba gratis las claves y los modelos, te enseña el coste y pide que escribas `SI`. Después crea la máquina y muestra el progreso. Cuando está lista, abre la app.
- **Bajar.bat**: descarga todas las imágenes a la carpeta `imagenes` (un .zip), borra la máquina, comprueba que ya no existe y que tu cuenta no tiene nada más cobrando.

Solo puede haber una máquina a la vez. Si ejecutas Subir con una ya en marcha, te vuelve a abrir la app.

## Redes de seguridad
- La máquina se borra sola tras **60 min sin generar** o a las **4 h**, lo que pase antes. Puedes cambiarlo: `subir.ps1 -Modelo qwen -MaxHoras 2 -InactividadMin 30`.
- Si la preparación falla, se borra sola a los 20 min.
- La app tiene el botón **Apagar y borrar la instancia**.
- Aun así, ejecuta siempre **Bajar.bat** al terminar: es lo único que confirma que no queda nada cobrando. El autoborrado usa la clave interna que RunPod da a cada máquina y no se ha podido probar todavía.

## Seguridad
- Solo se publica la app (puerto 7860), protegida con un token aleatorio que va en el enlace. ComfyUI no es accesible desde fuera.
- No se crea ningún disco persistente: todo se pierde al borrar la máquina, así que descarga las imágenes antes (Bajar.bat lo hace).

## Para que vaya rápido y barato
- Usa la imagen `ghcr.io/jcesarsa/ia-nube-comfyui` (ComfyUI ya instalado; se construye sola en GitHub al cambiar el repositorio). Si no está disponible, instala todo al arrancar.
- Antes de avisar de que está lista, carga el modelo en la GPU: la primera imagen ya sale rápida.
- Si Secure Cloud no tiene GPUs, pasa sola a Community Cloud (`-SoloSecure` para evitarlo, `-Comunidad` para ir directo).
- Al lanzarlo pregunta el modo: **rápida** (GPUs potentes, hasta 1 USD/h) o **económica** (menos de 0,50 USD/h). También con `-Velocidad rapida` o `-Velocidad economica`.
- Si RunPod asigna una GPU por encima de ese precio, la borra al instante y prueba otra (`-PrecioMax 1.5` para cambiar el límite).
- FLUX.2 necesita 48 GB: en modo económico casi nunca hay GPUs por debajo de 0,50; usa el rápido.
- Qwen: escribe el prompt en inglés y el texto que deba salir en la imagen, entre comillas.

## La app
- Cada imagen tiene botones para **borrarla** o usarla como **referencia**; arriba, **Borrar todas**.
- Referencia en Qwen: la nueva imagen parte de ella; la barra «Cuánto cambiar» va del 10 % (casi igual) al 100 % (la ignora).
- Referencia en FLUX.2: hasta 4 imágenes que el modelo tiene en cuenta (personas, objetos, estilo).

## Opciones
- Modelos: FLUX.2 dev fp8 (unos 54 GB de descarga, GPU de 48 GB) y Qwen-Image 2512 fp8 + Lightning 4 pasos (unos 31 GB, GPU de 24-48 GB).
