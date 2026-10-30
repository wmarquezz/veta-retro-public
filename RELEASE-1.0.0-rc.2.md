# VETA Retro 1.0.0 · candidata 2 · compilación 201

29 de octubre de 2026. Revisión de coherencia de la edición pública, sin cambios en los motores, los juegos incluidos ni los skins.

## Correcciones

- Game Center deja de ofrecerse cuando no está configurado; el multijugador cercano se mantiene.
- Una preferencia heredada de máximo rendimiento ya no fuerza JIT en la edición pública. La ayuda explica el funcionamiento local sin dirigir a ajustes inexistentes.
- Ayuda de AirPlay distingue audio y Duplicar pantalla, sin indicar una posición incorrecta del selector.
- Enlaces compartidos identifica los portales compatibles y explica que la contraseña sólo se conserva si activas Recordar acceso.
- Manifiesto de privacidad declara la consulta de espacio libre usada antes de importar archivos; el control previo comprueba esa declaración.
- Acceso al nombre del skin resuelto dentro del actor principal; textos actualizados en ocho idiomas y pruebas de regresión incluidas.

## Fuentes completas

Archivo VETA-Retro-1.0.0-rc.2-sources.tar.gz, independiente de entregas anteriores. Extrae y ejecuta `python3 apple/native/BuildSupport/source_release/verify.py .` dentro de veta-public-source. Sigue la receta README.md para tu compilación y firma. Los clientes OAuth necesitan configuración propia; no se incluyen credenciales privadas.

## Alcance

19 consolas públicas, sin PS2 ni extensiones JIT/VPN, dos juegos MIT. Fuentes de terceros y avisos conservados. Las pruebas de lógica y navegación no acreditan una matriz física completa de juegos, mandos Bluetooth o TV. No se recompilaron desde cero todos los motores. No se enviaron compras reales ni una compilación a revisión de Apple.

DIST-01/ART-01 mantienen su estado en el expediente. Aportes requieren acuerdos, Sandbox y revisión. Drive directo continúa en Testing privado y OneDrive/Dropbox directos no están habilitados públicamente. Esta candidata no equivale a aprobación de App Store.
