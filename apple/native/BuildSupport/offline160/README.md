# Motores locales de VETA 160: reconstrucción desde fuentes

Este directorio conserva las recetas y la procedencia de DreamcastInterpreterCore,
DukeXInterpreterCore y Play! WebAssembly v2. Contiene texto, parches y avisos de
licencia; no contiene ejecutables, juegos, firmware, datos de dispositivos ni
perfiles de firma. Ningún comando instala una app o controla un teléfono.

Los pins y hashes están en `pins.json`. Los hashes de productos identifican los
artefactos históricos auditados; no prometen igualdad binaria entre compiladores,
rutas, SDK o firmas diferentes. Estas recetas se contrastaron con las fuentes
privadas que produjeron esos artefactos, sin ejecutar una nueva compilación.

| Motor | Fuente exacta | Cambio para ejecución local |
| --- | --- | --- |
| Flycast | `flyinghead/flycast`, `6d81b998169b916ad7d7d6f403f7dc2c18e2aea5` | `TARGET_NO_REC` desactiva recompiladores SH4, ARM7 y DSP. La excepción del requisito de JIT al cargar se limita a ese build. |
| DukeX | `MaftyManicEMU/DukeX`, `56898d11be3eca4d50961fba4f5e12b27eddb634` | QEMU TCI interpreta bytecode en memoria escribible. Se excluyen rutas Universal JIT y se exporta una capacidad explícita. |
| Play! | `jpd002/Play-`, `505dac73149fece41b04dd961078ce3011a8bed5` | El backend genera WebAssembly que ejecuta WebKit. El proceso nativo de VETA no necesita preparar páginas de código JIT. |

## Uso aislado

Desde la raíz del repositorio, elige una carpeta nueva sin espacios para los
productos. Los ejemplos no modifican el entorno de inicio de sesión. Python
3.10 o posterior, Git, CMake y las herramientas de Xcode deben estar disponibles.
Los builds nativos originales usaron el SDK iPhoneOS 26.2; las versiones mínimas
de despliegue son 17.4 para Flycast y 17.0 para DukeX. Se limita la concurrencia
a cuatro procesos.

```sh
RECIPE="$PWD/apple/native/BuildSupport/offline160"
OFFLINE_WORK="$(mktemp -d /tmp/veta-offline160.XXXXXX)"
python3 "$RECIPE/prepare_sources.py" flycast --destination "$OFFLINE_WORK/flycast"
python3 "$RECIPE/build.py" flycast --source "$OFFLINE_WORK/flycast" --output "$OFFLINE_WORK/flycast-product"
```

`prepare_sources.py` exige un destino inexistente. Clona el pin y aplica la serie
completa. La opción `--reference /ruta/a/checkout` reutiliza objetos Git locales,
sin copiar sus modificaciones. Los submódulos se descargan desde sus orígenes
públicos sólo cuando se usaron en el build de referencia; no se descargan los
submódulos de firmware de DukeX. La preparación y primera compilación necesitan
acceso a las fuentes y herramientas; la ejecución de los motores ya empaquetados
no debe descargar nada.

### Play! WebAssembly v2

Instala el SDK oficial dentro de la misma carpeta aislada. El SDK requiere una
versión de Python compatible; no cambies el Python del sistema para esta receta.

```sh
git clone https://github.com/emscripten-core/emsdk.git "$OFFLINE_WORK/emsdk"
git -C "$OFFLINE_WORK/emsdk" checkout --detach d7b4130688bfa348392b921ab04015aa15c4f154
python3 "$OFFLINE_WORK/emsdk/emsdk.py" install 4.0.1
python3 "$OFFLINE_WORK/emsdk/emsdk.py" activate 4.0.1
python3 "$RECIPE/prepare_sources.py" play --destination "$OFFLINE_WORK/play"
python3 "$RECIPE/build.py" play --source "$OFFLINE_WORK/play" --output "$OFFLINE_WORK/play-product" --emsdk "$OFFLINE_WORK/emsdk"
```

El build fija Emscripten 4.0.1 y su release
`5ff495a591978fdf8a16f2d172be3616f3150d1e`, Release, `BUILD_PLAY=ON`,
`BUILD_TESTS=OFF`, `BUILD_PSFPLAYER=OFF`, `USE_QT=OFF`. Se conserva la
configuración upstream de WebGL2, dos workers pthread, memoria compartida,
crecimiento de memoria/tablas y exportación ES module. Los productos son
`artifacts/Play.js` y `artifacts/Play.wasm`.

`play-web-api.txt` documenta controles, pausa, operaciones asíncronas y estados.
No se copió ningún parche de congelación del campo de entrelazado. Los parches
heredados de VETA se conservan para reconstruir la misma fuente, aunque algunos
afectan únicamente al frontend libretro nativo. Se omitieron las líneas Git de
submódulos con sufijo `-dirty`; el cambio real de CodeGen se aplica por separado.
La desaparición de `deps/libchdr/deps/zlib-1.3.1/zconf.h` es una operación del
CMake de zlib que genera su configuración, no un cambio de VETA.

Integración: servir ambos assets y el juego desde un origen loopback local con
COOP `same-origin`, COEP `require-corp` y workers del mismo origen. WebKit debe
admitir WebAssembly, SharedArrayBuffer y WebGL2. El audio OpenAL requiere gestionar
el gesto del usuario y el ciclo de AudioContext. No incluir el shim de audio
silencioso usado en pruebas.

El formato `play-505dac7-vmzip-timing-v1` contiene el estado de CPS2VM, incluida
su temporización. No es intercambiable automáticamente con `.vstate` del frontend
libretro. Las tarjetas HLE son árboles `vfs/mc0` y `vfs/mc1`; mantenerlos en su
propio espacio del motor, sin reemplazar los guardados nativos existentes.

### DukeX TCI

Se reutiliza **por hash** `../nextgen/dukex_source.patch`, que contiene el puente
VETA, ciclo de vida, entrada/audio/vídeo, escalado y soporte de compilación ya
existentes. Después se aplica `patches/dukex-tci.patch`; aplicar sólo ese último
parche a DukeX upstream no produce el motor de VETA.

Las dependencias se compilan desde el pin de vcpkg, su parche ya existente y el
triplet ya existente. Instálalas en una carpeta nueva; no reutilices una carpeta
de herramientas ajena sin comprobar esos pins. Homebrew u otro gestor puede
proporcionar las herramientas host CMake, pkg-config, autoconf, automake, libtool,
flex y bison. No instalar bibliotecas iOS en el prefijo global del host.

```sh
python3 -m venv "$OFFLINE_WORK/tools"
"$OFFLINE_WORK/tools/bin/python" -m pip install meson==1.11.2 ninja==1.13.2 tomli==2.5.0 PyYAML==6.0.3
git clone https://github.com/microsoft/vcpkg.git "$OFFLINE_WORK/vcpkg"
git -C "$OFFLINE_WORK/vcpkg" checkout --detach 0c2a9ace1964b818b15f7ae50ba1c42404918a7b
git -C "$OFFLINE_WORK/vcpkg" apply --check "$RECIPE/../nextgen/dukex_vcpkg.patch"
git -C "$OFFLINE_WORK/vcpkg" apply "$RECIPE/../nextgen/dukex_vcpkg.patch"
mkdir "$OFFLINE_WORK/triplets"
cp "$RECIPE/../nextgen/dukex_arm64_ios.cmake" "$OFFLINE_WORK/triplets/arm64-veta-ios.cmake"
"$OFFLINE_WORK/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
"$OFFLINE_WORK/vcpkg/vcpkg" install curl glib libepoxy libpcap libpng libsamplerate pixman --triplet arm64-veta-ios --overlay-triplets="$OFFLINE_WORK/triplets"
git clone https://github.com/KhronosGroup/Vulkan-Headers.git "$OFFLINE_WORK/vulkan-headers"
git -C "$OFFLINE_WORK/vulkan-headers" checkout --detach 29f979ee5aa58b7b005f805ea8df7a855c39ff37
python3 "$RECIPE/prepare_sources.py" dukex --destination "$OFFLINE_WORK/dukex"
python3 "$RECIPE/build.py" dukex --source "$OFFLINE_WORK/dukex" --output "$OFFLINE_WORK/dukex-product" --tools "$OFFLINE_WORK/tools" --vcpkg-prefix "$OFFLINE_WORK/vcpkg/installed/arm64-veta-ios" --vulkan-headers "$OFFLINE_WORK/vulkan-headers"
```

El build usa `--enable-tcg-interpreter`, colocado después del valor predeterminado
upstream, y comprueba `CONFIG_TCG_INTERPRETER`. El export
`xemu_veta_execution_mode()` devuelve 1 sólo en este build; el frontend debe
comprobarlo antes de omitir la preparación JIT. El build JIT convencional conserva
sus comprobaciones. TCI no garantiza velocidad suficiente para cualquier juego.

La receta produce un `DukeXSlirp.framework` desde el mismo build para hacer
explícita esa dependencia. El artefacto físico histórico reutilizó el Slirp
existente de VETA159, auditado por ABI; no era idéntico byte a byte al rebuild.
El producto aquí generado tiene identidad propia y necesita una nueva validación
integrada. MoltenVK/DukeXMetal pertenece a la integración previa y no se obtiene
de un IPA con esta receta. El renderer, sus dependencias y los recursos legales
del sistema Xbox deben conservar el contrato del frontend; no se suministran
BIOS, MCPX, EEPROM ni discos Xbox.

## Verificación sin compilar

```sh
python3 "$RECIPE/verify_sources.py" flycast --source /ruta/a/flycast-preparado
python3 "$RECIPE/verify_sources.py" play --source /ruta/a/play-preparado
python3 "$RECIPE/verify_sources.py" dukex --source /ruta/a/dukex-preparado
python3 "$RECIPE/test_recipes.py"
```

La verificación crea índices Git temporales independientes, aplica las series al
pin y compara cada archivo modificado con el checkout suministrado. Comprueba
pins de submódulos inicializados, integridad de parches/licencias y los wraps
Meson de DukeX. No certifica el resto de un checkout arbitrariamente modificado;
para construir se exige el marcador de `prepare_sources.py`, y se recomienda
usar siempre sus checkouts nuevos.

`source-verification.json` registra esa comprobación sobre las fuentes de
referencia: 5 archivos Flycast, 12 Play/CodeGen y 42 DukeX. Es evidencia de
fuentes, no una nueva prueba de rendimiento, partidas, TV o teléfono. Los
resultados físicos y el producto exacto probado pertenecen al informe de entrega
de VETA, no a esta receta.

## Procedencia y licencias

`OfflineEngineLicenses.txt` es el recurso de texto que puede mostrar la app.
Se genera con `python3 write_notices.py`; `--check` comprueba que coincide con
el inventario y los originales. Su generación no cambia los avisos originales
y sólo normaliza los saltos de línea en el recurso combinado.

Se conservan 63 avisos originales en `licenses/`; `pins.json` identifica el origen
relativo y SHA-256 de cada copia. Las fuentes completas y sus avisos adicionales
siguen disponibles en los repositorios fijados, incluidos los submódulos y wraps.

- Flycast: GPL versión 2 y archivos con opción de versiones posteriores;
  conservar los avisos de cada archivo y dependencia. El cambio de modo no
  cambia su licencia.
- DukeX/QEMU: el archivo `LICENSE` declara el emulador como GPL versión 2, con
  licencias compatibles específicas por archivo. TCI contiene código MIT/BSD;
  eso no convierte al conjunto del motor en MIT. `COPYING.LIB` conserva LGPL
  para componentes que la utilicen. Slirp tiene avisos BSD; SDL, bibliotecas
  gráficas, FSR y dependencias de vcpkg mantienen sus propias licencias.
- Play!: BSD de dos cláusulas. Framework, CodeGen y Nuanceur conservan sus
  avisos originales. Se incluyen también avisos de libchdr, zlib, zstd, LZMA,
  bzip2, xxHash, JSON y ghc_filesystem, además de la licencia de Emscripten.
  El checkout del SDK conserva los avisos adicionales de sus componentes.

Los parches son modificaciones de las fuentes identificadas; deben distribuirse
con sus avisos y bajo términos compatibles con cada archivo original. Este
paquete de reconstrucción no sustituye la entrega de código fuente correspondiente
y avisos que pueda exigir la distribución del producto completo. No representa
una aprobación de distribución en App Store ni una auditoría de licencia de toda
la app. No se ha publicado ningún producto como parte de este trabajo.


## Presentación Xbox160: Automático y xBR

La receta DukeX incluye ahora `dukex-image-filter.patch`, aplicado después del intérpreteTCI. Automático conserva el FSR existente; xBR es una alternativa opcional para suavizar bordes, con reducción bilineal y taps acotados. No aumenta la resolución interna ni la velocidad de emulación. El frontend sólo muestra estas opciones si el framework exporta setter/getter; conserva compatibilidad con el motorJIT anterior. El formato de guardadosTCI no cambia por este parche. Los experimentosTCTI no forman parte de esta receta predeterminada mientras no se seleccione una variante validada.


### Espera y pausa de Xbox160

La serie incluye `dukex-idle-presentation.patch` y `dukex-ios-blocking-poll.patch`. En pausa se omite presentación y se esperan50ms fuera de locks manteniendo eventos. iOS usa g_poll estándar e interrumpible en lugar de ocupar CPU en esperas inferiores a1,25ms; clocks, callbacks y otras plataformas se conservan. El redondeo es inferior a1ms más latencia del sistema. Candidato final sin sonda de bucle validado físicamente en zi; resultados concretos/limitaciones en informe160. No equivale a60fps, consumo cero o temperatura garantizada.
