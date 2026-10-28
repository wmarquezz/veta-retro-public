# Portadas locales186

Cada usuario puede acompañar sus juegos con imágenes propias. La importación
busca una imagen en la misma carpeta y con el mismo nombre completo sin extensión:

```
NES/
  Juego (USA).nes
  Juego (USA).png
```

En Agregar juegos, selecciona la carpeta de esa consola o la ROM junto con su
imagen. También se intenta leer la imagen vecina si se puede acceder a la carpeta;
los proveedores de Archivos pueden exigir seleccionar ambos archivos o la carpeta.
No se buscan títulos aproximados, otras regiones ni otras carpetas. Se ignoran
mayúsculas/minúsculas. Las subcarpetas se importan por separado.

Formatos de portada: PNG, JPG, JPEG, HEIC y WebP, hasta30MB según las validaciones
de imágenes existentes. Si hay varias, prioridad PNG/JPG/JPEG/HEIC/WebP. La copia
se optimiza para biblioteca y no incorpora metadatos ni una URL de origen remoto.
El archivo original queda intacto. La imagen sigue disponible sin conexión.

Sin imagen, se importa el juego normalmente. Una imagen ilegible no hace fallar
la importación de la ROM; el resultado informa de ello. Las portadas existentes
siempre se conservan, incluso al reimportar un juego duplicado. Para reemplazarlas,
usa Cambiar portada. Si añades la imagen después, vuelve a importar la ROM o su
carpeta: no se duplica el juego ni se reemplazan partidas.

El selector abre archivos en su ubicación original para mantener la relación de
carpeta entre ROM/imagen y CUE/pistas. Los permisos temporales de Archivos se liberan
al terminar. No se escanean subcarpetas, no se importan enlaces y no se solicita
un servicio de imágenes ni una conexión a Internet. Las imágenes personales no
forman parte del catálogo ni del paquete público de VETA.

Esto no concede derechos sobre imágenes externas: cada usuario elige archivos
que pueda usar. La edición pública mantiene desactivadas las descargas remotas.
