# Revisión vigente de derechos · producto188

28 de octubre de2026. Resultado: **comprobaciones técnicas terminadas; autorización global de distribución AppStore no acreditada**. No se cambia el estado a aprobado sólo por petición de cierre. Esta revisión sustituye los datos de versión181 del registro principal; los informes182 se conservan como historial.

## Comprobado en Public188-a

- Versión0.188.0/build188: catálogo de dos juegos incluidos; licencias y archivos de fuentes presentes según inventario. La auditoría no encuentra los nombres de firmware comercial conocidos que comprueba; no prueba ausencia de todo firmware posible.
- Las fuentes188 ya publicadas contienen103.806entradas. SHA256 del archivo: `9510602ebb3090ac737078fd4c8f1447346b73b44f5af6ec8722c51c183f8fe7`. URL: https://github.com/wmarquezz/veta-retro-public/releases/download/v0.188.0/VETA-Retro-public-sources-188.tar.gz. El recibo188 verifica digest remoto y descargaHTTP200.
- La entrega188 ya verificó15frameworks y19paquetes de skins intactos respecto187. No se modifican motores, controles ni contenidos del iPhone en esta revisión.
- Se inspeccionaron726archivos cuyo nombre contiene LICENSE/COPYING/EXCEPTION/WAIVER en las fuentes188. No se encontró una cláusula de terceros referida expresamente a AppStore/marketplaces en esa búsqueda. Es una búsqueda acotada, no prueba de inexistencia de permisos en otros lugares ni de que cada proyecto necesite una excepción.
- Inventario actualizado de38SVG de ejecución: sin elementos de imagen incrustada ni referenciasHTTP externas. Los dibujos y sus hashes están identificados. Esa constatación estructural no verifica derechos sobre el diseño visual ni las fotografías de referencia.
- El logo vigente es la V con mando integrado de187. El CRT antiguo ya no identifica el icono vigente; no seguir describiendo sólo el CRT como el arte actual.

## DIST-01 · qué falta exactamente

La GPL concede redistribución y restringe condiciones adicionales; la EULA estándar de Apple limita transferencia/redistribución. Su salvedad de código abierto aparece en la cláusula de copia/modificación. Los mínimos de una EULA propia también contienen reglas de uso/no transferencia. El expediente no acredita cómo queda resuelto ese conflicto para las versiones integradas en VETA y los términos efectivos de distribución.

No es una prohibición universal de appsGPL, ni una exigencia de sustituir todos los motores. Es una cuestión concreta sin resolver en este expediente. Para cerrarla conservando el conjunto se necesita un análisis aplicable que justifique la compatibilidad o, donde corresponda, permisos adicionales válidos. No basta añadir una frase a los créditos ni publicar de nuevo las mismas fuentes. No se conceden excepciones en nombre de terceros. La práctica de RetroArch distingue núcleos propios y autorizaciones de equipos upstream; sus permisos no se transfieren por copiar su configuración.

## ART-01 · qué falta exactamente

La procedencia declarada es ChatGPT con fotografías propias paraNES/SNES y referencias deInternet para los demás controles. Faltan las referencias concretas y sus condiciones para evaluar la relación entre entrada y resultado. No se afirma infracción por usar referencias deInternet ni exclusividad de un resultadoIA.

Se puede resolver obteniendo la evidencia que corresponda para conservar los diseños o reemplazando los diseños afectados por arte independiente con procedencia documentada. Los cambios anteriores de tamaño/posición, remuestreo y conversiónSVG no solucionan por sí mismos esa cuestión. El usuario aprobó los skins y pidió conservar los motores; no se elimina ni reemplaza todo el conjunto por inferencia.

## Estado y próximos pasos acotados

La publicación de fuentes, avisos y elección GPL propia están completadas. No requieren otra investigación de rendimiento ni pruebas del teléfono. El punto global queda bloqueado exclusivamente por DIST-01 yART-01 ya existentes. No se crean nuevos bloqueos genéricos ni se marca `licensesAndContentRightsReviewed` como aprobado. La revisión de Apple tampoco reemplaza los derechos de terceros.

No se contactó a autores/abogados/Apple, no se aceptaron contratos, no se publicó unaEULA nueva y no se operó el teléfono. Para actuar sobre esos caminos hay que respetar la instrucción vigente del usuario de conservar motores y evitar gestiones externas.

## Fuentes consultadas28-10-2026

- [EULA estándar deApple, apartadoa](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/).
- [Mínimos deEULA propia, apartados1–2](https://www.apple.com/legal/internet-services/itunes/dev/minterms/).
- [GPLFAQ, restricciones y excepciones](https://www.gnu.org/licenses/gpl-faq.en.html); texto íntegroGPLv3 en `apple/native/COPYING`, secciones6 y10.
- [RetroArch, diferenciasAppStore/sideloading](https://docs.libretro.com/guides/install-ios/).
- [AppleReview5.2](https://developer.apple.com/app-store/review/guidelines/#intellectual-property).
