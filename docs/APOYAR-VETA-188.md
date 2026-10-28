# Apoyar VETA · 188

VETA mantiene sus funciones gratuitas. Ajustes → Apoyar VETA permite un aporte voluntario, consumible, independiente y de pago único mediante StoreKit 2. No es una suscripción, no concede ventajas y no bloquea juegos, partidas ni controles.

## Configuración

App Store Connect: VETA Retro, 6828144522, idioma principal Español (México). País base Chile (CLP); los precios solicitados son **$4.990 / $9.990 / $15.990 CLP**. Apple calcula los demás territorios. IDs y estado: `apple/native/Publication/support-products.json`.

La app utiliza exclusivamente `Product.displayPrice`. Si Apple no devuelve productos muestra que todavía no están disponibles y permite volver a consultar. No presenta importes ficticios ni inicia pagos automáticamente. Cancelación, espera de aprobación, fallo y verificación rechazada tienen mensajes distintos. Sólo se agradecen y finalizan transacciones verificadas de estos productos; un listener recupera transacciones pendientes. No hay funciones de pago que restaurar.

## Privacidad

Apple procesa el pago. VETA verifica la transacción en el dispositivo, sin solicitar datos de tarjeta ni subir juegos, partidas o biblioteca a un servidor de VETA. El aporte no constituye una donación benéfica ni promete beneficios fiscales.

## Validación y límites

Release 0.188.0/build188 compilada e instalada por USB. Los 15 frameworks y 19 paquetes de skins mantienen su contenido respecto187; Release no incorpora StoreKitTest ni el catálogo simulado. No se amplía la certificación de motores ni el alcance legal182.

La configuración local `Testing/VetaSupport.storekit`, esquema `VetaSupportPreview`, permite probar sin cobrar. La confirmación nativa muestra explícitamente entorno Xcode y ausencia de cobro. Prueba manual en iPhone17 Simulator: compra de los tres importes, repetición del pequeño y cancelación del mediano aprobadas, con agradecimiento sólo después de éxito y botones recuperados. El catálogo gratuito tiene prueba aprobada. La suite automatizada de compra/error falló en este Mac con `SKInternalErrorDomain Code=3 (Error saving configuration file)`; las escrituras de SKTestSession y la inyección de errores no funcionan en el runtime instalado. No se declara esa suite aprobada. Se añadió una comprobación de `disableDialogs` que omite la prueba si no se aplica, para evitar esperas de compra interactivas. Fallos conservados en la evidencia privada. Referencia: https://developer.apple.com/forums/thread/826971 .

## Antes de habilitar cobros reales

Los tres productos y sus precios/localización/notas están guardados como borradores, no enviados a revisión. Quedan disponibilidad por territorios, captura para revisión y asociación con la primera versión enviada. Se debe comprobar y completar el contrato de apps de pago y los datos fiscales/bancarios por el titular; este trabajo no acepta contratos. Falta prueba Sandbox/TestFlight independiente de la configuración local y aprobación de Apple. La instalación por USB no acredita disponibilidad de compra en producción.

Referencias: https://developer.apple.com/app-store/review/guidelines/#in-app-purchase y https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/ .
