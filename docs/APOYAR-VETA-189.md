# Apoyar VETA · cabecera189

La biblioteca ofrece un corazón y «Apoyar VETA» junto a Ajustes. La cabecera adapta texto e iconos al espacio disponible y conserva las etiquetas de accesibilidad.

Tras una transacción StoreKit2 verificada, de un producto de aporte permitido, consumible y no revocado, la invitación desaparece. Se registra una preferencia local antes de terminar la transacción; cerrar y reabrir conserva el agradecimiento. Cancelación, error, pendiente y resultado no verificado no activan esta preferencia. Ajustes mantiene «Apoyar VETA» para aportes voluntarios posteriores. Ninguna función depende de pagar.

## Alcance de la persistencia

Es una preferencia local, no un derecho de acceso ni un registro de compras sincronizado. Borrar los datos o reinstalar puede hacer reaparecer la invitación; no se promete reconocimiento en otro dispositivo. No se consulta el historial completo de consumibles ni se añade un servidor.

## Validación

- Release189 compilada y firmada para instalación por USB.
- Componente Simulator con las fuentes reales SupportVeta.swift y LibraryHeader.swift: invitación visible, navegación al apoyo, diseño normal y tamaño accesible; tras inyectar el reconocimiento local, invitación ausente y Ajustes conserva el acceso. Reinicio del componente mantiene la ocultación.
- Cuatro aserciones sobre el almacén real y preferencias aisladas: inicialmente falso, reconocimiento, nueva instancia y aislamiento. PASS. Se añade SupportReminderTests.swift como regresión XCTest; ese archivo XCTest no se ejecutó en esta ronda.
- La inyección del componente no representa una compra Apple. No hubo nuevos cobros ni una compra Sandbox/TestFlight. La validación simulada de compra188 y sus límites se conservan en APOYAR-VETA-188.md.
- 15 motores comparados por secciones y 19 paquetes de skins idénticos a188; sin PS2, ayudantes JIT/VPN ni StoreKitTest dentro del producto Release.

Los tres aportes y precios no cambian: CLP $4.990 / $9.990 / $15.990. Los productos siguen en borrador; no se envía la app ni se habilitan cobros en esta entrega. Tampoco constituye cierre global de licencias ni aprobación App Store.
