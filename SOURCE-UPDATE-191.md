# Reconstruir fuentes completas191

Descarga la base VETA-Retro-public-sources-189.tar.gz y VETA-Retro-source-update-191.tar.gz. Comprueba los tamaños y SHA256 de SOURCE-RELEASE.json. Extrae ambos, en ese orden, en una carpeta nueva:

```sh
tar -xzf VETA-Retro-public-sources-189.tar.gz
tar -xzf VETA-Retro-source-update-191.tar.gz
python3 veta-retro-public/apple/native/BuildSupport/source_release/verify.py veta-retro-public
```

La actualización191 incluye también los cambios190; no necesitas el paquete190. Los motores y dependencias completos están en la base189. Sigue las instrucciones de construcción del árbol resultante. Las licencias de cada componente y el alcance de distribución previo se conservan.
