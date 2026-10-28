# VETA Retro — copia local de fuentes para revisión

El código propio de la aplicación nativa se ofrece bajo GPL-3.0-or-later;
`apple/native/LICENSE.md` delimita el alcance. Los avisos de terceros prevalecen
para sus aportaciones. Krafify y sus servicios independientes no forman parte
de esta copia.

## Contenido

- Fuentes del target público nativo, configuración, recetas, parches y pruebas
  de componente seleccionados en `source-review-files.json`.
- Licencia GPL completa y avisos conservados.
- Archivo de fuentes de bsnes-mercury y jgenesis de la entrega170, con sus
  dependencias y adaptadores. Sus manifiestos y reconstrucción corresponden
  a esa entrega; las recetas actuales del frontend se entregan por separado.
- `SOURCE-MANIFEST.json` con SHA-256 de cada archivo de esta copia.

Es una **copia de revisión**, todavía no una entrega completa del código
correspondiente a un binario publicado. No contiene la biblioteca personal,
guardados, claves, certificados, emparejamientos ni el historial Git.

## Para terminar la entrega de fuentes

1. Incorporar las fuentes exactas y dependencias de los otros motores del
   Archive final, aplicando las recetas y parches correspondientes. Los pins
   de `BuildSupport` ayudan a identificarlos; los enlaces por sí solos no
   sustituyen los materiales exigidos por sus licencias.
2. Resolver los avisos de licencia pendientes del conjunto y la procedencia
   de recursos PPSSPP (PGF y atlas de fuentes); conservar las licencias
   individuales. La GPL del código propio no concede derechos sobre ellos.
3. Comprobar la reconstrucción en un directorio limpio y relacionar el paquete
   de fuentes con el Archive distribuido. Esta copia no es autocontenida para
   compilar toda la app: faltan fuentes y recursos enumerados en los puntos
   anteriores. No incluye credenciales de firma; cada desarrollador usa las suyas.
4. Publicar las fuentes completas en una ubicación estable junto a la versión
   correspondiente y añadir ese enlace real en la app. No se inventa una URL
   de fuentes ni se da el repositorio por publicado.

La elección de licencia ya está resuelta. Estos pasos son la ejecución de las
obligaciones de distribución ya identificadas, no pruebas nuevas de motores.
Los flags `correspondingSourcesPrepared` y `licensesAndContentRightsReviewed`
deben permanecer en `false` hasta reunir su evidencia.

## Generación local

Desde la raíz del proyecto:

```sh
python3 apple/native/BuildSupport/export_source_review.py --output /ruta/local/veta-source-review.tar.gz
```

El exportador usa una lista explícita, rechaza enlaces simbólicos y algunos
patrones de datos privados, verifica el archivo de motores y crea un paquete
determinista. Ese control es una ayuda de revisión, no una certificación de
ausencia de secretos ni de derechos sobre cada recurso. No publica ni opera
el iPhone. Se rechaza sobrescribir un archivo existente.
