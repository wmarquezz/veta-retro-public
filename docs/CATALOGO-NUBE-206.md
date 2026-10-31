# Catálogo personal de nube · VETA Retro 1.0.0 (206)

En **Agregar juegos → Conectar mi nube**, conecta Drive y abre la carpeta que contiene `veta-catalog.json`. VETA detecta el archivo automáticamente y muestra sus consolas. Puedes abrir una consola, buscar por nombre, marcar varios juegos o seleccionar una consola completa. **Importar disponibles** omite los que ya están en tu biblioteca.

Las tarjetas muestran una portada cuando está disponible; en caso contrario, el símbolo de un mando y el nombre. La selección del juego incluye su portada. Un juego instalado muestra **Ya instalado** y no se puede marcar. La comparación usa el contenido del juego, incluso si llegó en ZIP o con otro nombre, siempre que el catálogo registre su identificador correcto. Otra versión regional o una ROM modificada puede ser un juego distinto. Si lo eliminas de la biblioteca, vuelve a estar disponible para importar.

El archivo pertenece al usuario. No contiene contraseñas, credenciales ni direcciones externas de descarga. Cada consola usa una carpeta directa con sus juegos e imágenes; no hay subcarpetas de juegos en este formato. El proveedor se mantiene en modo de lectura. Los errores por archivo siguen en el historial de importaciones y una ROM rechazada no deja una portada suelta en la biblioteca.

## Formato 1

JSON UTF-8, máximo 16 MiB, `format: "veta.catalog"`, `version: 1`, título, fecha de generación y lista `consoles`. Cada consola contiene `id` (identificador interno público), `name`, `folder` y `games`. Cada juego contiene:

- `id`: SHA-256 de la ROM tal como VETA la almacena, tras descomprimir/normalizar cuando corresponde.
- `title`: nombre para mostrar y buscar.
- `file`: `path`, `bytes` y `sha256` del archivo descargable (ZIP o ROM).
- `cover`: opcional; los mismos campos para la imagen.
- `validation`: `import` (importación comprobada), `boot` (arranque con imagen comprobado) o `user` (confirmación del usuario). Ninguna categoría acredita una partida completa o rendimiento universal.

Las rutas son relativas a la carpeta del catálogo: `Game Boy/Juego.zip` y `Game Boy/Juego.png`. Se rechazan rutas externas, saltos de directorio, consolas fuera del catálogo público, identidades duplicadas y archivos fuera de los límites. Se verifica el tamaño y SHA-256 antes de usar cada descarga. Los discos con varios archivos CUE/M3U se siguen importando por el navegador normal; no pertenecen al formato 1.

El catálogo es una instantánea. Añadir o retirar juegos en Drive requiere regenerarlo. Si está dañado, VETA conserva la navegación normal de carpetas. Entrar a una carpeta sin catálogo tampoco cambia el flujo habitual. La conexión directa de Google sigue sujeta a la configuración y disponibilidad de la cuenta de prueba; este cambio no publica la autorización OAuth ni registra otros proveedores.
