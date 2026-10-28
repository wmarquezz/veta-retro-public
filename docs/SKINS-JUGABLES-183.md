# Controles ampliados · 183

Los 19 skins Estudio incluidos se revisan en las dos orientaciones. Los originales
SVG del ZIP se conservan; refresh_studio_skins.py genera el SVG de ejecución,
el mapa táctil y el paquete juntos. No modifica archivos personales del usuario.

NES vertical: cruceta de 108 a 144 puntos y A/B de 56 a 76 puntos en el lienzo
400×276. A 375 puntos de ancho son 135 y 71,25 puntos respectivamente. Se amplía
además el dibujo visible dentro de las zonas y las teclas Select/Start. El resto
usa distribuciones por familia: dos botones, cuatro en rombo, seis en dos filas,
analógicos y pantallas dobles. DS mantiene su mando compacto de 188 puntos.

Horizontal: se elimina el multiplicador de opacidad 0,62; se conserva la opacidad
que el usuario haya elegido. Se retiran los paneles decorativos opacos sobre el
juego y se conservan las formas/colores de los controles. El centro queda libre,
los botones son opacos por defecto y las zonas táctiles coinciden con el arte.
La imagen sigue con exactamente la geometría anterior: ConsoleLayout y los
reproductores no cambian. Los controles de los bordes pueden cubrir parte de la
imagen en pantallas estrechas; no se promete separación sin reducir esa imagen.

Pruebas UIKit: 5.873 comprobaciones, 19 consolas, 38 variantes, 190 combinaciones
de orientación/tamaño, incluidas anchuras verticales 375/393/414/768 y horizontal
667/734/746/1000. Verifican límites, tamaño táctil ≥44pt, ausencia de colisiones,
correspondencia dibujo/entrada, opacidad sobre fondos distintos y centro libre.
Mosaicos revisados de las 38 variantes y composiciones con imagen de prueba.
Regresión personal: 1.313 comprobaciones aprobadas (importar/seleccionar/editar/
conservar; almacenamiento aislado). No equivale a jugar 19 títulos físicos.

Los intentos a/b detectaron colisiones 3DS/Wii; la revisión c las corrige, incluida
la fila −/HOME/+ de Wii en horizontal compacto. Se conservan esos fallos en las
evidencias privadas. Motores, juegos, guardados y licencias no cambian de alcance.
