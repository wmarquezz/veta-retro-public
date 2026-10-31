# VETA Retro 1.0.0 · candidata 5 · compilación 204

30 de octubre de 2026. Importación por lotes con errores aislados e historial.

- Las rutas de usuario Archivos/carpetas, nube directa y portal compartido continúan con los archivos válidos cuando otro archivo falla al leerse, descargarse, extraerse o importarse. Límites globales de seguridad, falta de espacio global y cancelación siguen deteniendo la preparación cuando corresponde.
- Si un ZIP o ROM falla, no se incorpora su portada a la biblioteca. Las imágenes preparadas temporalmente se eliminan con el lote; los originales no se modifican. Un fallo sólo de portada conserva el juego válido y se identifica en el informe.
- Agregar juegos → Historial de importación muestra fecha, juegos procesados y nombre/motivo de cada incidencia. También hay acceso desde el resultado de Archivos. Conserva hasta 20 informes recientes, con un límite total de 20000 incidencias. No se envían automáticamente ni se guardan URLs privadas o credenciales en errores de sistema.
- Se conserva el nombre original del ZIP aunque la ROM interna tenga otro nombre. Las pistas de un CUE incompleto no se importan como juegos independientes. Duplicados y guardados existentes se conservan.
- Gestión masiva por consola de 203 incluida. Textos en ocho idiomas. Motores, contenido incluido y skins sin cambios.

## Validación y alcance

Pruebas de lote mixto: ZIP dañado, ROM inválida y juego válido con sus imágenes; sólo el juego correcto y su portada se incorporan. Cobertura adicional de descarga parcial, permisos, tamaño/hash, persistencia/retención del historial, errores al escribirlo, ausencia de credenciales, CUE y regresiones ZIP/proveedores. El informe de entrega documenta las ejecuciones y la instalación.

Fuentes completas en VETA-Retro-1.0.0-rc.5-sources.tar.gz, sin necesitar archivos anteriores. Verificar con `python3 apple/native/BuildSupport/source_release/verify.py .`. No incluye ROM personales, credenciales ni historial del usuario.

19 consolas públicas, sin PS2 ni extensiones JIT/VPN. No es envío o aprobación de App Store. DIST-01/ART-01 y pendientes administrativos siguen separados. No se habilitan nuevos proveedores ni se recompilan todos los motores. Drive directo continúa en Testing privado.
