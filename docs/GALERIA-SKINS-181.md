# Galería de skins por consola · 181

Ajustes → Mis skins por consola muestra las 19 consolas públicas con imágenes y
nombres de los diseños activos en vertical y horizontal, aunque no tengan juegos.
Cada consola abre Skins y controles: vista previa del diseño activo, selector de
orientación, cinco estilos incluidos con miniaturas y acceso a los personales.

Las vistas previas usan TouchDeck.applySkin, igual que el reproductor, respetando
el diseño personal de cada orientación. Elegir un estilo incluido desactiva sólo
la selección personal de esa orientación, sin borrar su archivo ni cambiar la otra.
Editar posiciones abre el diseño realmente seleccionado; el editor conserva la
orientación desde la que se abrió. Visitar la galería no guarda nuevas preferencias.

Validación: compilación Release iOS; navegación real en Simulator del componente
SwiftUI, elección Clásica vertical, vuelta con resumen actualizado, horizontal
con Estudio conservado y captura de ambos. Los controles y recursos de180 no se
modifican; los15frameworks de motores conservan sus secciones Mach-O. No nueva
matriz de juegos físicos ni certificación App Store.

El validador global de traducciones conserva faltantes anteriores (diagnóstico,
QA y textos previos); los cinco nuevos textos se añaden explícitamente a los ocho
idiomas sin reemplazar las traducciones existentes.

## Instalación comprobada

Public181-a,0.181.0/build181 instalada sobre180 en iPhone15Pro. Respaldo previo
verificado, datos persistentes idénticos tras instalar y arranque normal PASS.
Biblioteca0juegos, sin restaurar datos privados. Las interacciones de la galería
se probaron en Simulator; en el teléfono se verificaron instalación y apertura.
No nuevas pruebas de motores ni operación del iPhone11.
