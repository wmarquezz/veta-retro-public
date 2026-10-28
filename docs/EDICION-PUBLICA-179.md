# VETA Retro 179 · separación de la edición pública

28-10-2026. Por decisión del titular, PS2 se excluye de la edición pública hasta
validar una alternativa local con rendimiento utilizable. La edición personal,
sus fuentes y el motor Play! con JIT se conservan por separado. No se ha eliminado
esa investigación ni se ha afirmado que PS2 funcione sin JIT.

## Alcance

- Catálogo público de 19 consolas; PS2 no se ofrece para añadir, importar ni jugar.
- Se conserva la decodificación de metadatos PS2 antiguos para evitar destruir
  archivos al leer una biblioteca anterior; esto no habilita el motor.
- PS2Core se retira del enlace/empaquetado público; el preflight rechaza tanto
  ese framework como PS2Wasm, StikJIT y las extensiones JIT/VPN de desarrollo.
- Dos juegos MIT revisados (A_KANOID y Space Game) en el catálogo incluido.
- Motores locales de Dreamcast, Dolphin y N64 preservados del producto personal;
  fuentes y recetas de esos motores incluidas en el paquete correspondiente.
- La app enlaza las fuentes públicas desde Ajustes → Créditos → Código fuente.

## Fuentes

Repositorio separado: https://github.com/wmarquezz/veta-retro-public
Entrega: https://github.com/wmarquezz/veta-retro-public/releases/tag/v0.179.0

El repositorio privado de trabajo conserva su historial y los experimentos.
La publicación separada no incluye biblioteca personal, guardados, certificados,
archivos de emparejamiento ni secretos. El código propio conserva GPL-3.0-or-later;
las dependencias mantienen sus respectivas licencias y avisos.

## Instalación limpia solicitada

El usuario pide probar el producto público en su iPhone, sin conservar allí la
edición personal. Antes de retirarla se respalda Documents y Library (excepto
caché transitoria), con segunda lectura independiente por SHA-256. El producto
personal178 también se conserva para una recuperación futura. La firma caduca
y puede requerir renovación; guardar el .app no elimina los requisitos de iOS.
Xbox/PS3/Xbox360 siguen archivadas y fuera de ambas selecciones activas; no se
reinstalan ni se consideran universalmente compatibles por conservar sus fuentes.

## Límite de esta entrega

La copia de prueba usa el target público Release y una firma de desarrollo para
instalar por USB. No es una descarga de App Store ni un Archive de distribución
aprobado. No se realiza una nueva certificación de todos los juegos, rendimiento,
TV o multijugador. Los resultados finales de paquete, respaldo, instalación y
publicación se registran en el informe de entrega179; no se deducen de esta nota.

## Verificación de instalación · 28-10-2026

Public179-c (0.179.0/build179) instalada y abierta en iPhone15Pro como única
VETA, con contenedor nuevo y biblioteca vacía. La edición personal se retiró
únicamente después del respaldo completo y doble verificación de sus archivos.
El paquete público contiene los dos juegos MIT del catálogo; se añaden desde
Juegos gratis. Inventario y procesos finales confirman la ausencia de la app
personal y de su proveedor JIT/VPN. No se inició una nueva matriz de juegos.
Esta verificación no sustituye la firma de distribución ni la revisión de Apple.
