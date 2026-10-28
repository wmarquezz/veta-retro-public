#!/usr/bin/env python3
"""Generate the app's offline-engine notice resource from preserved originals."""
import argparse
from common import ROOT, PINS, check_inputs


def render():
    for engine in PINS['engines']:
        check_inputs(engine)
    parts = [
        'VETA Retro 160 · Motores locales · Fuentes y licencias\n',
        'Este documento conserva los avisos originales de los motores y de las '
        'dependencias incluidas en su inventario de fuentes. Las licencias de '
        'cada componente se mantienen por separado. No incluye juegos ni firmware.\n',
        'Fuentes exactas y modificaciones\n',
    ]
    for engine, meta in PINS['engines'].items():
        parts.append(f'{engine}: {meta["repository"]}\nRevisión: {meta["revision"]}\n')
    dependencies = PINS['engines']['dukex']['dependencies']
    for key in ('vcpkg', 'vulkan_headers'):
        meta = dependencies[key]
        parts.append(f'DukeX / {key}: {meta["repository"]}\nRevisión: {meta["revision"]}\n')
    sdk = PINS['engines']['play']['toolchain']
    parts.append(f'Play! / Emscripten {sdk["version"]}: {sdk["repository"]}\n'
                 f'Revisión SDK: {sdk["revision"]}\nRelease: {sdk["release"]}\n')
    parts.append('Los parches VETA y las recetas se conservan en '
                 'apple/native/BuildSupport/offline160 y BuildSupport/nextgen. '
                 'Los submódulos y las dependencias Meson corresponden a los pins '
                 'de esas revisiones. El inventario conserva también avisos '
                 'de componentes auxiliares de las fuentes; su presencia aquí '
                 'no afirma que todas sus funciones estén activas.\n')
    for notice in sorted(PINS['license_notices'], key=lambda value: value['copy']):
        parts.append('\n' + '=' * 72 + '\n' + notice['engine'] + ' / ' + notice['source'] + '\n'
                     + 'SHA-256 del aviso original: ' + notice['sha256'] + '\n' + '=' * 72 + '\n')
        # The standalone originals remain byte-identical; normalize line endings
        # only in the combined UTF-8 display resource.
        parts.append((ROOT / notice['copy']).read_text() + '\n')
    return '\n'.join(parts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    target = ROOT / 'OfflineEngineLicenses.txt'
    content = render()
    if args.check:
        if not target.exists() or target.read_text() != content:
            raise SystemExit('OfflineEngineLicenses.txt is absent or stale')
    else:
        target.write_text(content)
    print(f'Offline engine notice resource: {len(PINS["license_notices"])} original notices verified')


if __name__ == '__main__':
    main()
