# VETA Retro 1.0.0 · candidata 4 · compilación 203

30 de octubre de 2026. Administración masiva de juegos por consola.

- Tus consolas → consola → Administrar juegos: selección múltiple, búsqueda, seleccionar toda la consola, quitar selección y eliminación con confirmación del total.
- Acceso adicional desde Biblioteca → Administrar juegos → consola. La búsqueda no altera la selección; seleccionar toda la consola incluye los juegos ocultos por la búsqueda, como indica la pantalla.
- Borra sólo la selección capturada al confirmar, con sus portadas y partidas dentro de VETA. Conserva otros juegos, skins y originales de Archivos/nube. La operación no se puede deshacer desde la app.
- Una sola actualización atómica del índice por lote. Antes de confirmar ese índice, los directorios se pueden recuperar; al reiniciar se restaura o termina la limpieza según el índice persistido.
- Interfaz y errores en ocho idiomas. Motores y contenido incluido sin cambios.

## Validación

Pruebas de componente: 500 juegos con 2500 archivos, selección parcial, conservación de originales/skins/otra consola, errores de almacenamiento, recuperación antes y después del commit, entradas ausentes e identificadores inválidos. Regresión del borrado individual. Pruebas de interfaz y resultado de instalación documentados en el informe de entrega 203; no se eliminan juegos personales como prueba.

## Fuentes

VETA-Retro-1.0.0-rc.4-sources.tar.gz contiene las fuentes completas sin archivos previos. Verifica con `python3 apple/native/BuildSupport/source_release/verify.py .` dentro de veta-public-source. Sigue README.md para compilar y firmar. No incluye secretos, cuentas ni ROM personales.

## Alcance

19 consolas públicas; sin PS2 ni extensiones JIT/VPN. DIST-01/ART-01 y pendientes administrativos de Apple se mantienen separados. No supone envío ni aprobación de App Store. Drive directo sigue en Testing privado. No se recompilaron todos los motores ni se realizaron nuevas partidas.
