# Reconstruir fuentes completas190

1. Descarga VETA-Retro-public-sources-189.tar.gz de la entrega v0.189.0 y VETA-Retro-source-update-190.tar.gz de v0.190.0.
2. Comprueba sus SHA256 con SOURCE-RELEASE.json de190.
3. En una carpeta nueva, ejecuta:

```sh
tar -xzf VETA-Retro-public-sources-189.tar.gz
tar -xzf VETA-Retro-source-update-190.tar.gz
python3 veta-retro-public/apple/native/BuildSupport/source_release/verify.py veta-retro-public
```

El segundo archivo reemplaza únicamente archivos propios y añade la funcionalidad190; contiene el manifiesto completo nuevo. Los motores y dependencias permanecen en el primer archivo. Sigue las instrucciones de construcción del proyecto resultante. Esta forma de entrega no modifica las licencias de cada componente ni afirma aprobación AppStore.
