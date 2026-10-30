# VETA Retro 1.0.0 · candidata 1 · compilación 200

29 de octubre de 2026. Primera numeración de publicación: versión visible 1.0.0, compilación interna 200, etiqueta de fuentes v1.0.0-rc.1. No implica aprobación de Apple.

Este archivo completo sustituye la cadena de archivos base y actualizaciones de las entregas anteriores. Incluye las mejoras 192–199: conexión directa con Drive en pruebas privadas, portadas y ZIP, menú de importación, enlaces compartidos y recuerdo local de acceso, guardados manuales/automáticos, controles externos y consolas con juegos, revisión de Ajustes y ocho idiomas. La entrega 200 unifica versiones y documentación; no modifica los motores.

## Reconstrucción

Extrae VETA-Retro-1.0.0-rc.1-sources.tar.gz y entra en veta-public-source. Ejecuta `python3 apple/native/BuildSupport/source_release/verify.py .` y sigue la receta de README.md. Las dependencias y parches están dentro del paquete. No necesitas los archivos de 189, 190 o 191. Para una compilación propia configura tu equipo de firma y los clientes OAuth de tus servicios; los identificadores públicos de cliente no conceden acceso a cuentas ni son claves privadas.

## Numeración

1.0.1: corrección compatible. 1.1.0: funciones nuevas compatibles. 2.0.0: cambios mayores. El número de compilación siempre aumenta. `apple/native/Publication/version.json` es la fuente única; `python3 apple/native/BuildSupport/app_version.py --write` sincroniza el proyecto y `python3 apple/native/BuildSupport/app_version.py` verifica que no haya discrepancias.

## Alcance y límites

19 consolas, sin PS2 ni extensiones JIT/VPN en esta edición pública. Dos juegos de ejemplo MIT; no incluye la biblioteca personal. GPL-3.0-or-later para contribuciones propias; terceros conservan sus licencias. Fuentes y avisos no equivalen a una autorización de App Store: DIST-01 y ART-01 siguen documentados en el expediente de derechos. No se realizó una reconstrucción integral de todos los motores desde cero en esta entrega. Google Drive sigue en Testing privado; OneDrive/Dropbox directos no están habilitados para el público. Los aportes aún requieren acuerdos, pruebas y revisión de Apple.
