# Aviso de temperatura190

Durante los juegos de las19consolas de la edición pública, VETA observa ProcessInfo.thermalState de iOS. Normal y elevada (nominal/fair) no muestran aviso. Alta y crítica (serious/critical) muestran una recomendación de descanso. No se informan grados Celsius.

«Pausar juego» llama al menú de pausa existente; mostrar el aviso no pausa automáticamente, guarda ni modifica los motores. Minimizar conserva un indicador; una transición a crítica vuelve a abrir la recomendación. Al bajar a fair/nominal desaparece y se prepara para otro episodio. Al regresar a primer plano se lee el estado actual.

No hay sondeo periódico, red, notificaciones push ni permisos nuevos. El aviso es local a la pantalla del iPhone/iPad; no se agrega a la superficie externa de TV ni al mando remoto.

## Validación y límites

- Tres pruebas XCTest sobre la política real, ejecutadas como módulo SwiftPM en Mac: umbrales, minimizar/escalar y enfriamiento/reaparición. Cero fallos.
- Componente SwiftUI real en Simulator con estados inyectados: aparición, minimizar, crítica, acción de pausa y desaparición al enfriar; vertical/horizontal y texto accesible. La pausa del componente confirma la acción; en producción se conecta a Emulation.openMenu, que ya pausa la sesión.
- Compilación Release190 y comparación de motores/skins. No se provoca sobrecalentamiento físico, ni se certifica haber recibido una notificación térmica real en el iPhone. No nueva matriz de juegos/TV/multijugador.

Referencia oficial: https://developer.apple.com/documentation/foundation/processinfo/thermalstatedidchangenotification

## Fuentes completas

Los motores y dependencias son idénticos a189. Para evitar repetir457MB sin cambios, la entrega190 se obtiene extrayendo el paquete completo189 y después el paquete de actualización190 en la misma carpeta. SOURCE-MANIFEST.json de190 verifica cada archivo del árbol resultante. Ambos enlaces, tamaños y SHA256 están en SOURCE-RELEASE.json. Las fuentes revisables del frontend también están en el repositorio.
