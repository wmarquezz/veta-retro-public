# VETA Retro 1.0.0 · candidata 3 · compilación 202

30 de octubre de 2026. Corrección de importación de Mega Drive.

- Admite SMD, tanto suelto como dentro de ZIP, desde archivos, carpetas y nube. Convierte los bloques entrelazados una vez antes de guardar y calcular la identidad del juego; conserva el original.
- Reconoce dumps SMD etiquetados BIN cuando tienen la cabecera de copiador, así como cartuchos antiguos con campos de fabricante desplazados o vectores de arranque válidos.
- ZIP + portada sigue asociado aunque el nombre interno sea diferente. La versión SMD y su equivalente BIN normalizado no duplican el juego ni sustituyen sus partidas.
- Los fallos de importación identifican el archivo concreto; los ZIP anidados, la corrupción y las ROM incompletas siguen rechazándose.
- Mensaje nuevo traducido a ocho idiomas. Motores, juegos incluidos y skins sin cambios.

## Validación

21 pruebas de regresión y una prueba privada de colección aprobadas. Colección personal: 772 ZIP revisados, 769 procesados, 765 juegos únicos con 765 portadas; cuatro duplicados. Tres archivos rechazados por ZIP anidado, datos comprimidos dañados o ROM incompleta. Esa colección comercial no se redistribuye ni se incorpora a estas fuentes. Importar no acredita rendimiento o partida completa de todos los juegos.

## Fuentes

VETA-Retro-1.0.0-rc.3-sources.tar.gz contiene las fuentes completas sin necesitar archivos anteriores. Verifica con `python3 apple/native/BuildSupport/source_release/verify.py .` dentro de veta-public-source. Sigue README.md para compilar y firmar. No incluye secretos, cuentas ni ROM personales.

## Alcance de distribución

19 consolas públicas, sin PS2 ni extensiones JIT/VPN. Se mantienen los expedientes DIST-01/ART-01 y los pendientes administrativos de Apple; esta candidata no supone aprobación ni envío a App Store. Drive directo continúa en Testing privado; no habilita públicamente otros proveedores. No se recompilaron todos los motores desde cero.
