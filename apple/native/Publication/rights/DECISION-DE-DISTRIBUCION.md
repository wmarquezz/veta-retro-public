> Estado28-10-2026: fuentes181 publicadas; GPL propia autorizada. El texto de
> preparación local que sigue es histórico. La revisión vigente y los únicos
> bloqueos documentados de esta ronda están en REVIEW-182.md y LICENSE-REVIEW.json.

# Decisión de distribución de VETA Retro

**Decisión vigente · 27-10-2026: abrir también el código propio de la app bajo GPL-3.0-or-later.** Preparación local autorizada; publicación pendiente. Sustituye la decisión anterior limitada a dos motores.

## Ruta aceptada: VETA Retro con código abierto

El usuario pidió «oka, entonces gtenemos qeu hacer lo mismo» después de comparar Delta y otras apps de código abierto. Esta decisión posterior sustituye la limitación anterior a sólo dos motores. Se adopta **GPL-3.0-or-later para las contribuciones originales de VETA Retro**, según la propuesta previa. Delta usa AGPLv3; seguimos el modelo de publicar las fuentes de la app, sin afirmar que elegimos exactamente su misma licencia.

La concesión y su alcance están en `apple/native/LICENSE.md`, con el texto GPLv3 en `COPYING`. Los terceros conservan sus licencias. Krafify, sus servicios independientes, la biblioteca personal, datos, credenciales y claves de firma quedan fuera.

Puede cobrarse por la app y funciones adicionales cumpliendo la GPL. Los extras incorporados al mismo programa no se mantienen cerrados simplemente por cobrarlos por separado. La licencia permite a terceros estudiar, modificar y redistribuir el código conforme a sus condiciones.

Se prepara una copia local para revisión; **no hay publicación del repositorio ni autorización de envío a App Store en esta entrega**. La elección de licencia resuelve la decisión sobre el código propio. La compatibilidad de todos los componentes y la entrega completa de fuentes siguen requiriendo evidencia.

## Antecedente: por qué no bastaba abrir sólo los motores

No basta con entregar sólo los motores GPL o declarar que son gratuitos. Habría que obtener permisos adicionales aplicables de sus titulares o sustituir los componentes que impidan esa distribución. Puede cambiar la cobertura de consolas y requiere nuevas pruebas. No existe evidencia de que los titulares hayan concedido a VETA esas excepciones.

## Alcance de la revisión actual

El candidato público tiene dos juegos MIT y bloquea la búsqueda remota de portadas sin permisos acreditados. La app personal instalada permanece intacta. La biblioteca web privada y la web principal Krafify quedan fuera de esta decisión.

Se debe entregar el código correspondiente a la versión final realmente distribuida. Un archivo de fuentes parcial o un enlace genérico a GitHub no equivale a una entrega completa.

Referencias: [GPL FAQ](https://www.gnu.org/licenses/gpl-faq.html.en#GPLCommercially), [GPLv3](https://www.gnu.org/licenses/gpl-3.0.html), [App Review 5.2](https://developer.apple.com/app-store/review/guidelines/#intellectual-property).

## Ejemplos comprobados

- Delta publica el código de la aplicación bajo **AGPLv3**: https://github.com/rileytestut/Delta#licensing . No publica solamente sus motores.
- RetroArch publica código bajo **GPLv3**; los núcleos conservan sus licencias propias: https://github.com/libretro/RetroArch/blob/master/COPYING .
- PPSSPP publica código, declara **GPL2 o posterior**, y ofrece Gold, incluida una compra integrada en iOS: https://github.com/hrydgard/ppsspp/blob/master/README.md y https://www.ppsspp.org/buygold/ . Es evidencia de que código abierto y monetización pueden coexistir, no una excepción para distribuir VETA cerrada.

La FAQ GNU considera que el enlace estático o dinámico forma una obra combinada: https://www.gnu.org/licenses/gpl-faq.html.en#GPLStaticVsDynamic . El alcance legal depende de la integración y los permisos aplicables; no se presume una excepción por separar frameworks o cobrar sólo los extras.

## Comprobación local de los dos motores

Archivo existente commercial170-core-sources.tar.gz: SHA256 6eaa6d805cd101c462705972e2d2e622fbbc303e2b76b9f9829e8022fa10966f. Manifiestos internos verificados:1196 archivos bsnes y626 jgenesis, cero discrepancias de hash. No contiene apple/native/Sources ni las rutas de secretos y firmware32X expresamente excluidas. Esta comprobación verifica el archivo, no la compatibilidad jurídica de toda la app ni una nueva reconstrucción.

La comprobación anterior no resuelve el punto global de derechos de distribución. Se mantienen sin aprobar los flags globales de derechos y fuentes completas. Motores, versión instalada e infraestructura permanecen intactos. Recibo privado de esa comprobación: ../veta172-rights-validation/two-core-check.json.
