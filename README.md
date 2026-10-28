# VETA Retro — fuentes de la edición pública

Fuentes de la edición pública 0.179.0, preparadas el 28-10-2026. Contribuciones originales bajo
GPL-3.0-or-later; se conservan las licencias individuales de terceros.
Repositorio: https://github.com/wmarquezz/veta-retro-public
Paquete completo: https://github.com/wmarquezz/veta-retro-public/releases/tag/v0.179.0
No es una aprobación de App Store.

## Contenido y alcance

- Fuentes actuales del frontend nativo y sus recursos originales.
- Archivos originales fijados de FCEUmm, mGBA, Tia, PCE, PCSX ReARMed,
  DeSmuME, Saturn y PPSSPP; las recetas incluyen sus modificaciones.
- Atari2600 usa Tia6ae5bf99 (GPL-2.0-or-later), con parches VETA reproducibles
  para imágenes DPC de10496bytes y restauración de imagen tras reabrir. Stella2014
  está excluido de este candidato. Los guardados antiguos no se convierten.
- Variantes locales de Dreamcast, Dolphin y N64 usadas en iPhone, con sus fuentes exactas y recetas.
- Instantáneas de Flycast, Azahar, Dolphin y Mupen64Plus Next, con
  submódulos, cambios locales, hashes y revisiones.
- melonDS DS, sus once dependencias y parche freeBIOS aplicado.
- bsnes-mercury y jgenesis con adaptadores, sustituto libre SPC700 y dependencias
  Cargo vendorizadas. No se incluyen las BIOS32X retiradas de ese paquete.
- MoltenVK1.4.2 y sus siete dependencias fijadas; la receta de VETA usa los
  binarios oficiales verificando sus hashes, con fuentes y receta upstream
  conservadas para poder reconstruirlos por separado.
- Dos juegos MIT y sus fuentes/licencias; tipografías y atlas libres de PSP.

`SOURCE-MANIFEST.json` identifica cada archivo; `source-evidence/COMPONENTS.json`
identifica revisiones, modificaciones y exclusiones de artefactos precompilados.
`source-evidence/NOTICE-INDEX.json` permite localizar los avisos originales.
Las exclusiones no deben interpretarse como una licencia nueva de terceros.

PS2 queda excluida de esta edición pública hasta validar un motor local utilizable.
Se conserva la decodificación de metadatos antiguos sin ofrecer importación ni ejecución.
Esta copia corresponde al candidato público nativo, no a la edición integrada de
uso personal: no incluye ayudantes JIT/VPN ni los motores experimentales de esa
edición. No incluye la biblioteca personal, partidas, certificados, claves,
emparejamientos, historial Git ni servicios privados de Krafify.

El archivo PPSSPP de esta copia omite los seis atlas antiguos; su metadato
registra el hash original, las exclusiones y el hash nuevo. Las fuentes del
motor se conservan. Los tests físicos que usan una biblioteca privada no
forman parte del proyecto exportado.

## Descarga de las fuentes completas

Este repositorio permite revisar el frontend y las recetas. Para reconstruir,
descarga y descomprime **VETA-Retro-public-sources-179-c.tar.gz** desde la entrega
v0.179.0 enlazada arriba. Ese archivo incluye también los árboles de terceros,
los recursos, las dependencias vendorizadas y SOURCE-MANIFEST.json. Los archivos
de motores y recursos pesados se distribuyen allí, no como submódulos incompletos.

## Reconstrucción

Requisitos: macOS, Xcode con SDK iOS, Python3.9+, Git, CMake, Ninja, XcodeGen y
Rust/Cargo con aarch64-apple-ios y aarch64-apple-ios-sim. Estas herramientas
estándar se instalan por separado. Usar un directorio nuevo y rutas sin espacios
si algún Makefile upstream lo exige. No ejecutar el antiguo `prepare.py`: esa
receta histórica también prepara el catálogo de desarrollo y regenera ajustes.

Desde la raíz de esta copia:

```sh
python3 apple/native/BuildSupport/source_release/verify.py .
python3 apple/native/BuildSupport/source_release/rebuild_public.py --prepare-only
python3 apple/native/BuildSupport/source_release/rebuild_public.py
cd apple/native
xcodebuild -project VetaNative.xcodeproj -scheme VetaNative -configuration Release -sdk iphoneos ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

Para instalar en un dispositivo, elegir equipo e identidad propios en Xcode.
Las credenciales privadas del autor no son necesarias ni forman parte de las
fuentes. Cargo usa las fuentes locales indicadas en `.cargo/config.toml`.
`VETA-SOURCE-PIN.json` permite verificar los árboles sin incluir metadatos Git.
Si se modifica deliberadamente un motor, actualizar o retirar ese manifiesto
según el nuevo proceso de desarrollo; no presentar el nuevo binario como idéntico.

Para regenerar los atlas (FreeType, libpng, zstd y pkg-config instalados):

```sh
python3 apple/native/BuildSupport/source_release/build_free_atlases.py --ppsspp apple/native/.build/ppsspp --fonts third-party/font-inputs --output atlas-build
```

La reproducción de recursos utiliza entradas y recetas conservadas. La versión
local de FreeType puede cambiar píxeles; las salidas que se incluyen tienen sus
propios hashes. No se promete identidad binaria entre versiones de Xcode.

## Relación con el binario y distribución

Antes de enviar a Apple, relacionar el Archive definitivo con su paquete de fuentes
mediante hashes y publicar ambos con una URL estable. La app enlaza esta entrega desde Ajustes → Créditos → Código fuente.
La instalación por USB usa firma de desarrollo del target público; no es una descarga de App Store.
El resultado de auditoría de licencias y sus excepciones pendientes está en
`apple/native/Publication/rights/LICENSE-MATRIX-176.md`; conservarlo al revisar.
