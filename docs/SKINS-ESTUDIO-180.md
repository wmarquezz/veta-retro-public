# Skins Estudio · VETA Retro 180

Se integran los diseños aportados en VETA-Skins-19-Estudio Update.zip:19consolas,
38orientaciones, PS2 excluida. Los dibujos y sus mapas se empaquetan juntos como
skins VETA. No se incluyen fotografías de referencia, pantallas de ejemplo ni
scripts ejecutables procedentes del ZIP.

Estudio es el estilo predeterminado cuando no existe una elección guardada.
Las preferencias anteriores y los skins personales tienen prioridad; se conservan
Clásica, VETA, Noche y Transparente. Para elegir el nuevo diseño: Skins y controles,
orientación, Estilo → Estudio. Crear desde plantilla permite personalizarlo.
Editar posiciones desde Estudio abre una copia con su imagen y ambas orientaciones.
Los archivos personales siguen siendo independientes del catálogo incluido.

DS vertical usa un lienzo explícito400×188 (versión4). Los diseños anteriores
versión1 conservan400×276;3DS conserva su versión2,400×240. Se ajusta el espacio
del reproductor junto con el control; no se cambia el motor ni se inventa una
segunda pantalla. La presentación y el toque de la pantalla emulada conservan
su recorrido existente.

Cinco dibujos verticales recibieron separaciones mínimas de2–4puntos en su SVG
y mapa juntos: N64,DS,GameCube,PSP yDreamcast. Evitan que los blancos táctiles
mínimos44pt se crucen al reducir el mando a375pt. El manifiesto de arte registra
los desplazamientos y el hash del ZIP original; las fuentes originales se conservan.
El render de producción emplea el PNG correspondiente, no las vistas de presentación.

Verificación de componente UIKit/Simulator:19consolas×2orientaciones,
171combinaciones de tamaño,4.604comprobaciones PASS (geometría, mínimos44pt,
centros de dibujo frente a toque, máscaras digitales, cruceta, estabilidad al
relayout y compatibilidad de versiones). Regresión de skins personales:
1.313comprobaciones PASS. Se revisaron mosaicos de las38salidas reales de UIKit.
No equivale a probar19juegos físicos, rendimiento, TV o multijugador.

Release iPhone0.180.0/build180 compilada. Los15frameworks de motores se comparan
por secciones Mach-O con179; la identidad exacta se registra en el recibo del
producto. Continúan los requisitos de distribución pendientes; la firma USB
no es aprobación de App Store.

Fuentes y recetas de arte: apple/native/Content/StudioSkins.
Recursos importables: apple/native/Sources/Resources/studio-*.vetaskin.
La compilación usa los recursos ya preparados. Regenerar desde el ZIP requiere
Node y @resvg/resvg-js; no es una dependencia del runtime del emulador.

## Instalación física completada · 28-10-2026

Public180-c instalada porUSB sobre la edición pública179 en iPhone15Pro, sin
desinstalar. Respaldo previo y comparación de datos persistentes PASS; arranque
normal, versión0.180.0/build180 y biblioteca vacía comprobados. Los38skins están
en el producto instalado. Las comprobaciones detalladas de geometría/entrada
corresponden a UIKit/Simulator; no se afirma una nueva matriz de19juegos físicos.
