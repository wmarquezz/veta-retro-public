# Edición de controles185

Mover o redimensionar un skin personal sólo cambiaba sus zonas táctiles; la imagen
PNG permanecía fija. Además, Guardar arriba conservaba el archivo sin seleccionar
el skin nuevo. Ambos comportamientos se corrigen en185.

- Guardar arriba guarda y activa la orientación editada y cierra el editor. Se
  retira el botón inferior duplicado. La otra orientación conserva su selección.
- Los19skins Estudio/38orientaciones incorporan fondo y sprites de controles
  separados, obtenidos de sus propios SVG retenidos. Los PNG originales no cambian.
- Las posiciones ya guardadas con una imagen Estudio reconocida se recuperan en
  memoria con esas capas; no se reemplazan archivos del usuario. Las plantillas
  procedurales reconocidas se vuelven a dibujar con su distribución guardada.
- El editor, la prueba de controles, la galería y TouchDeck durante el juego usan
  el dibujo actualizado. Mover repetidamente no degrada las capas originales.
- El editor de estilos incluidos permite cambiar ancho y alto, además de posición.
- Los PNG personalizados se separan en recortes al importarlos. Deben conservar las
  posiciones de la plantilla: un PNG plano no contiene las capas ni el fondo oculto.
  Fondos planos o transparentes dan mejor resultado; la app no reconstruye detalles
  fotográficos tapados por botones. No se infieren posiciones antiguas desconocidas.
- Se conservan validación de límites, colisiones, mínimo táctil y fallback en una
  ventana que no admite la distribución. Transparente sigue siendo el valor
  horizontal por defecto, respetando elecciones explícitas.

## Validación

2.917 comprobaciones de edición,190 combinaciones (19consolas ×2orientaciones
×5estilos): cambio visual, guardar/reabrir, selección, mapa táctil, caché y recuperación
de plantillas anteriores. Incluye reproducción con un archivo personal privado,
que no forma parte de estas fuentes. Regresión:6.025checks Estudio y1.313personales.
Navegación real en Simulator: mover/agrandar A, Guardar superior, cierre del editor,
selección activa y reapertura; botón inferior retirado. Las pruebas de componentes
no son una certificación física de190juegos.

15frameworks conservan sus secciones respecto184. Sin motores nuevos, PS2, ayudantes
JIT/VPN ni cambio al tamaño de imagen del juego. La edición pública mantiene su
alcance de licencias documentado en182; esto no declara aprobación App Store.
