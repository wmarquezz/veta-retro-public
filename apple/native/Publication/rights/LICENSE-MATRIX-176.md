# Licencias y fuentes · candidato público 179 (revisión de 176)

Revisión técnica del 28-10-2026. No concede permisos de titulares, no cambia las
licencias de terceros y no declara aprobado el conjunto para distribuirlo.

## Matriz de componentes

| Componente distribuido | Licencia principal / evidencia en las fuentes | Material preparado |
|---|---|---|
| Código propio VETA | GPL-3.0-or-later, LICENSE.md y COPYING | Frontend, adaptadores, parches, recursos originales y recetas actuales |
| FCEUmm | GPLv2, encabezados con opción de versiones posteriores | Archivo original fijado, lista de compilación y avisos |
| mGBA | MPL-2.0 y avisos de dependencias | Archivo0.10.5, configuración y fuentes compiladas |
| Tia (Atari2600) | GPL-2.0-or-later explícita en los archivos compilados; cabecera Libretro MIT | Fuente6ae5bf99 fijada, receta y modificaciones VETA; sustituye Stella2014 |
| Beetle PCE / Saturn | GPL-2.0-or-later; encabezados mednafen, más LGPL y permisivas | Archivos fijados, manifiestos y avisos |
| PCSX ReARMed / DeSmuME | GPLv2 con encabezados que permiten versiones posteriores; dependencias propias | Archivos fijados y recetas |
| bsnes-mercury / jgenesis | GPLv3; dependencias con avisos propios | Árboles modificados, adaptadores, fuente SPC700 libre y Cargo vendor |
| melonDS DS | FrontendGPLv3; motorGPLv3 y dependencias propias | Frontend,11 dependencias fijadas y parche freeBIOS |
| PPSSPP | GPL-2.0-or-later; dependencias propias, incluido FFmpeg | Archivo con submódulos, parches y receta |
| Flycast | GPL-2.0-or-later en encabezados, componentes permisivos | Árbol fijado, submódulos y cambios locales |
| Play! / PS2 | Fuera de la edición pública179 | Motor y fuentes conservados exclusivamente en el entorno personal |
| Azahar | GPLv2 con opción posterior; dependencias propias | Árbol fijado, submódulos y cambios locales |
| Dolphin | README declara GPL-2.0-or-later; dependencias conservan términos | Árbol fijado, submódulos, cambios y fuentes de sustitutos libres DSP |
| Mupen64Plus Next | Componentes GPL/LGPL y permisivos; avisos por subcomponente | Árbol fijado, cambios y lista exacta de fuentes del target |
| MoltenVK1.4.2 | Apache-2.0 y dependencias permisivas | Fuentes de la etiqueta y7 dependencias fijadas; receta y hashes del binario oficial |
| Roboto / Inconsolata / Noto / Source Han Sans | OFL-1.1 | Textos íntegros, hashes y procedencia; entradas y receta de atlas |
| Ume Gothic / Mincho | Licencia Ume: permite uso, copia y distribución comercial con o sin modificación | Licencia original conservada, procedencia e inventario PGF |
| A_KANOID / Space Game | MIT | Dos juegos fijados con fuentes y avisos; catálogo personal excluido |

Las licencias principales no sustituyen las de cada dependencia. El paquete
conserva los textos en sus ubicaciones y añade un índice de avisos. La presencia
de una licencia en un repositorio no demuestra por sí sola que se enlace esa
parte; tampoco se considera automáticamente GPLv3 a un archivo por contener
el ejemplo «or later» dentro del texto estándar de GPLv2.

## Compatibilidad Atari: reemplazo local completado

Por decisión del usuario se conserva Atari2600. El candidato público usa Tia,
commit6ae5bf998fe7a7842294089db17fc86fd73db1f0 de warmenhoven/tia, cuyos archivos
compilados declaran SPDX GPL-2.0-or-later; la interfaz Libretro conserva MIT.
No se modifica la licencia de Stella2014: se excluyen su framework y su archivo
de fuentes de este paquete. El archivo original permanece en el entorno privado.

`public_atari.py` verifica el archivo fijado, aplica dos modificaciones originales
VETA (carga de DPC10496 y conservación de imagen/región en estados), selecciona
TIACore y genera los avisos. El identificador de estados es nuevo y utiliza una
carpeta separada: no se convierte ni sobrescribe un estado Stella.

Las pruebas locales incluyen Berta, Adventure y PitfallII. No acreditan todos
los cartuchos ni equivalencia universal con Stella. La versión upstream declara
limitaciones de mapeadores (por ejemplo CDF/DPC+); no ocultarlas al distribuir.
Los detalles de pruebas y fallos corregidos están en el informe176.

El bloqueo específico de combinar Stella2014 con GPLv3 queda retirado del
candidato público. La aprobación de distribución sigue exigiendo comprobar el
Archive final y las condiciones del canal; esta revisión técnica no garantiza
aceptación de Apple ni sustituye permisos adicionales de titulares.

## Fuentes PSP

Se verificaron los18 PGF de la revisión usada. Los encabezados anteriores al
commit upstream de compatibilidad dc34bea identifican Ume Hy Gothic/Ume P Mincho
para ltn0–15 y Source Han Sans para japonés/coreano. Los nombres compatibles
con PSP no se usan como prueba de una procedencia Sony. Se conservan hashes,
licencias y referencias en `thirdparty-notices/ppsspp`.

Las recetas originales de atlas referenciaban Arial Unicode y Kozuka. El
candidato público usa atlas nuevos generados desde Roboto y Noto OFL, con
símbolos geométricos originales. Se conservan fuentes de entrada, herramienta,
modificaciones, pruebas y hashes; no se acredita cobertura universal de glifos.

## Entrega de fuentes y límite de cierre

El exportador176 reúne los materiales, en lugar de ofrecer sólo enlaces a
repositorios. La verificación compara cada archivo y comprueba los caminos de
compilación. La reconstrucción total desde cero y la relación con el Archive
final se documentan por separado; no se deducen de que los archivos existan.
Las fuentes179 se preparan para el repositorio veta-retro-public y su release v0.179.0.
La app enlaza esa entrega. El Archive enviado a Apple deberá corresponder a estas
fuentes o a una entrega posterior identificada; la publicación del código no acredita aprobación de Apple.

Fuentes: [Tia: concesión explícita](https://github.com/warmenhoven/tia/blob/6ae5bf998fe7a7842294089db17fc86fd73db1f0/src/cpu.c),
[Stella2014 fijado](https://github.com/libretro/stella2014-libretro/tree/7d1361e407e63f29e52892655069e5fb4096e691),
[Fedora](https://packages.fedoraproject.org/pkgs/libretro-stella2014/libretro-stella2014/),
[GPL: compatibilidad de versiones](https://www.gnu.org/licenses/gpl-faq.html.en#v2v3Compatibility),
[PGF upstream](https://github.com/hrydgard/ppsspp/commit/dc34bea8d4dee77629da3cbaedc83fc8c05af159),
[Adobe OFL](https://github.com/adobe-fonts/source-han-sans/blob/master/LICENSE.txt).
