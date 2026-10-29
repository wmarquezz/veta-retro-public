# Importación desde la nube191

En Agregar juegos → Desde Drive, OneDrive o Dropbox, abre el servicio en Explorar, entra a la carpeta de una consola, selecciona sus juegos y portadas (puedes usar Seleccionar todo) y toca Abrir. Instala e inicia sesión en la app del servicio y actívalo en Archivos → Explorar → ⋯ → Editar. VETA no pide sus contraseñas ni sincroniza automáticamente.

Drive y OneDrive aparecen deshabilitados en el selector de carpetas completas de iOS probado. Por eso la ruta principal usa selección múltiple de archivos. Para iCloud Drive o En mi iPhone, la opción Carpeta de iCloud o del iPhone permite seleccionar una carpeta y recorrer subcarpetas; depende de los permisos del proveedor. No se promete importar una carpeta entera directamente de Drive/OneDrive.

La ruta de nube mantiene los permisos de la selección y realiza lecturas coordinadas fuera del hilo principal para descargar los archivos. Sólo prepara extensiones admitidas, omite archivos ocultos, rechaza enlaces y limita el recorrido a 10.000 entradas/20 niveles. Snapshot local único, originales de sólo lectura. Una selección explícita de archivos de nube se agrupa cuando sus nombres son únicos, porque algunos proveedores entregan un directorio aislado por archivo; así se reúnen ROM/imagen y CUE/pistas. Las selecciones de directorio y los nombres duplicados conservan límites separados para evitar sobrescrituras. Importa un disco a la vez cuando haya nombres de pistas ambiguos.

Para la portada usa el mismo nombre, por ejemplo Juego.nes + Juego.png. Selecciona todas las pistas CUE/BIN/WAV. El importador existente conserva duplicados, portadas anteriores y partidas. La copia temporal se retira al terminar.

Hay progreso por archivos y cancelación durante preparación; el tiempo de cancelación depende del proveedor. Mantén VETA abierta mientras descarga. Se necesita espacio local e Internet para archivos aún no descargados. Después de importar, VETA usa su copia interna para jugar sin conexión; no hace streaming.

## Validación del 28-10-2026

Public191-e Release0.191.0 instalada por USB en iPhone15Pro. El candidato e conserva el código d probado y corrige la numeración del paquete, que en b/c/d seguía indicando190. Catorce pruebas iOS Simulator aprobadas (6 preparación, 8 importación/portadas), sin fallos: carpetas anidadas, mismos nombres separados, ROM/portada, archivos de proveedor aislados, pistas CUE, repetición/preservación, cancelación/limpieza, enlaces, ausentes y persistencia después de retirar el origen. Antes de la corrección d, 5 pruebas Mac y12 Simulator aprobadas; no sustituían la prueba física.

OneDrive físico: selección real, importación de A_KANOID y repetición sin duplicar el juego. El candidato c no asociaba su portada: fallo conservado y corregido en d agrupando la selección explícita. Google Drive: navegación intermitente con «Contenido no disponible» durante duplicación del iPhone; al usar el teléfono directamente, el usuario confirmó acceso a Game Boy y, tras instalar d, «Portadas añadidas: 1». Esta es aceptación manual física de Drive, no una prueba automática de todos los proveedores. Dropbox no estaba disponible y queda sin validación física. iCloud/carpeta completa conserva pruebas de componente, no certificación remota física.

Se creó en el Drive personal del usuario retro-veta con19subcarpetas de las consolas públicas y se subió A_KANOID (MIT), imagen y licencia a Game Boy por autorización explícita. No se subieron ROMs comerciales. Los enlaces privados del usuario no se incluyen en fuentes públicas.

Respaldo42archivos persistentes anterior a la instalación; lectura idéntica tras191-b. Ocho juegos anteriores conservados; nuevo juego de prueba añadido, sin reemplazar guardados ni skins. Evidencia final detallada en el informe privado de entrega. Motores/skins conservados, sin cambios a PS2/JIT, cobros o estado AppStore.

Referencias: https://developer.apple.com/documentation/uikit/providing-access-to-directories y https://support.apple.com/102238
