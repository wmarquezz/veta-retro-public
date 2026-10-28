# Revisión de licencias y distribución · VETA Retro182

28-10-2026. Revisión del producto público181 y corrección182.
**No se marca autorización de distribución App Store.** La preparación técnica
se puede comprobar automáticamente; las condiciones del canal no se resuelven
cambiando un booleano ni mediante la aprobación de una app distinta.

## Trabajo ejecutado

- Código propio GPL-3.0-or-later conforme a la decisión del titular; terceros
  conservan sus términos. No se añadió una excepción en nombre de terceros.
- Atari usa Tia GPL-2.0-or-later; BSNES/jgenesis sustituyen los componentes con
  restricciones previas. PS2, Xbox, PS3, Xbox360 y ayudantesJIT/VPN fuera del
  paquete público. No se alteraron los motores ni los juegos del usuario.
- Dos juegos MIT fijados, A_KANOID y Space Game, con licencia, fuente y hashes.
  Las imágenes, música y fuente incluidas permanecen dentro de esos archivos
  fijados; no se incluyeron copias privadas ni ofertas remotas del catálogo.
- Los DSP de Dolphin coinciden con sus sustitutos libres fijados; la búsqueda
  de nombres de BIOS conocidas no da coincidencias. La búsqueda por nombres
  no certifica todos los posibles datos incrustados.
- Font assets PSP coinciden con el manifiesto OFL/Ume ya revisado; atlas
  de procedencia anterior incierta excluidos. ShadersMIT/Apache y avisos
  conservados. Recursos y paquetes de skins corresponden a180/181.
- Fuente181 pública:103.712archivos; hashes y descarga anónima verificados.
  Incluye27árboles y recetas. No se declara reconstrucción bit a bit desde cero
  de todos los motores: se conserva la cadena de fuentes y secciones binarias.
- Hallazgo corregido182: avisos de dependencias presentes sólo en el archivo
  fuente (p. ej. cereal/BSD) pasan a los créditos empaquetados.667archivos de
  avisos,304textos únicos, texto íntegro con procedencia ySHA256. Inventario
  ampliado: no es una afirmación de que todas esas herramientas se enlacen.
- El empaquetador rechaza la omisión o modificación del nuevo archivo de
  avisos. Las licencias no se sustituyen por una lista de nombres o enlaces.

## DIST-01 · evidencia de compatibilidad del canal

Estado: **sin resolver; no autorización App Store**.
La GPLv3, sección10, impide añadir restricciones al ejercicio de los derechos
concedidos. La EULA estándar de Apple limita transferencia/redistribución y
contiene una salvedad para términos de componentes abiertos en la cláusula
sobre copia/modificación. No se presupone que esa salvedad solvente todas las
restricciones de distribución. La EULA personalizada tampoco es una solución
automática: sus mínimos2 exigen una licencia no transferible y el punto1
remite a las reglas de uso de Apple.

Apple Developer Program,3.3.4(A)(v), exige cumplir las licenciasFOSS;5.1 exige
compatibilidad con firma/protección y términos del programa. No se aceptaron
contratos nuevos, se modificó la EULA en Connect ni se enviaron mensajes.
La presencia de Delta/PPSSPP en la tienda no constituye una concesión para VETA.
La posturaFSF de2010 se registra como antecedente histórico, no como prueba de
que los términos2026 sean idénticos.

**Evidencia necesaria para cerrar DIST-01:** revisión aplicable al conjunto y
al contrato de distribución efectivamente aceptado que justifique compatibilidad;
o permisos adicionales válidos de los titulares afectados que cubran las
restricciones identificadas. VETA sólo puede conceder excepciones sobre sus
aportaciones propias, no sobre todos los motores. Una licencia personalizada
redactada unilateralmente no reemplaza esa evidencia.

Consulta preparada: verificar alcance de la salvedadFOSS, reglas de uso,
redistribución, firma/DRM y obligaciones de GPLv3§§3,6,10; revisar licencias
GPLv2-or-later/GPLv3/MPL/Apache de la matriz. No se asume que GPL§6 obligue a
entregar clavesApple: hay que analizar sus supuestos y excepciones, no pedir
ni publicar certificados privados. El archivo fuente no contiene esas claves.

## ART-01 · constancia del arte aportado

El usuario aclara que los diseños se generaron con ChatGPT: fotografías propias
para NES/SNES y referencias de Internet para los demás controles. No se aportaron
URLs o licencias de esas referencias; no afirmar que sean infractoras por eso.
Se registra la declaración en ART-PROVENANCE.json, sin atribuir autoría humana
exclusiva ni inventar una cesión de los fabricantes.

Inspección estructural de38SVG: cero elementos de imagen raster o referencias
externas. Se revisaron visualmente las vistas NES yPS1. Esto acredita dibujos
vectoriales, no una comparación de originalidad respecto de fotos no disponibles.
La foto propia resuelve su procedencia fotográfica, no todos los posibles derechos
sobre el diseño del mando. Los nombres/símbolos funcionales no se declaran
prohibidos por esta revisión.

Los términos deOpenAI asignan al usuario sus derechos sobre el resultado, hasta
donde permite la ley, y responsabilizan al usuario por sus entradas. No conceden
los derechos de terceros. Por tanto, ART-01 registra procedencia y deja pendiente
la evaluación específica de los diseños/referencias; no es una infracción probada.
No se eliminan ni rediseñan los skins aprobados unilateralmente.

## Estado de la corrección

182 compila y verifica avisos íntegros y guardia de empaquetado. Fuentes182
preparadas para la entrega pública; comprobar SOURCE-RELEASE.json y la release.
No instalado:181 permanece en el iPhone. Dictamen concreto en
DISTRIBUTION-DECISION-182.md. La publicación de fuentes no es distribuciónAppStore.
No se marca licensesAndContentRightsReviewed como true. Los dos asuntos concretos
son DIST-01 yART-01; no se sustituye ese estado por un «todo listo».

## Fuentes oficiales consultadas

- GPLv3 íntegra: apple/native/COPYING, secciones3,6,10; texto de licencia
  recibido en el repositorio. https://www.gnu.org/licenses/gpl-3.0.html
- Apple EULA: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
- Mínimos EULA: https://www.apple.com/legal/internet-services/itunes/dev/minterms/
- Acuerdo de desarrollador: https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- Apple Review5.2: https://developer.apple.com/app-store/review/guidelines/#intellectual-property
- AntecedenteFSF2010: https://www.fsf.org/news/2010-05-app-store-compliance/

No se subió una app a App Store ni se activaron cobros. La revisión de Apple,
firma de distribución, ficha yTestFlight siguen como etapas separadas; no
reabren las correcciones técnicas ya completadas.

- Términos OpenAI, contenido: https://openai.com/policies/row-terms-of-use/
