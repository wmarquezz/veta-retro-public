"""Pinned Atari replacement for the public target; never edits the development core."""
import hashlib
import json
import tarfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]

def prepare(base=BASE):
    pin = json.loads((base / 'BuildSupport/tia.json').read_text())
    archive = base.parents[1] / 'vendor/native' / pin['archive']
    if hashlib.sha256(archive.read_bytes()).hexdigest() != pin['sha256']:
        raise ValueError('Atari source archive checksum mismatch')
    root = base / '.build/tia-public'
    with tarfile.open(archive) as tar:
        for member in tar:
            parts = Path(member.name).parts
            if not parts or parts[0] != 'tia-6ae5bf99' or '..' in parts:
                raise ValueError('Unsafe Atari source path')
            if member.isdir(): continue
            if not member.isfile(): raise ValueError('Non-regular Atari input')
            path = root.joinpath(*parts[1:])
            data = tar.extractfile(member).read()
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists() or path.read_bytes() != data:
                path.write_bytes(data)
    # VETA modification, 2026-10-28: canonical DPC images can carry a full
    # 256-byte table after 8 KiB program + 2 KiB display ROM. Retain all bytes.
    cart = root/'src/cart.c'
    text = cart.read_text()
    original = 'if (size == 10240 || size == 10495) {'
    if text.count(original) != 1: raise ValueError('Unexpected DPC source')
    cart.write_text(text.replace(original,
        '/* VETA 2026-10-28: also accept a full 256-byte DPC table. */\n'
        '        if (size == 10240 || size == 10495 || size == 10496) {'))
    # The fixed TV window can retain rows that a game does not redraw.
    # Preserve them across cold restores instead of treating the image as transient.
    bridge = root/'src/libretro.c'
    text = bridge.read_text()
    text = text.replace('+ SYS_SER_BYTES;', '+ SYS_SER_BYTES + sizeof(sys.tia.fb);')
    begin = text.index('bool retro_serialize(')
    end = text.index('bool retro_unserialize(', begin)
    save = text[begin:end].replace('    return true;',
        '    /* VETA 2026-10-28: retain partially refreshed TV rows. */\n'
        '    memcpy(p, sys.tia.fb, sizeof(sys.tia.fb));\n    return true;')
    text = text[:begin] + save + text[end:]
    begin = text.index('bool retro_unserialize(')
    end = text.index('void *retro_get_memory_data(', begin)
    restore = text[begin:end].replace('    return true;',
        '    /* VETA 2026-10-28: restore TV image and presentation timing. */\n'
        '    memcpy(sys.tia.fb, p, sizeof(sys.tia.fb));\n'
        '    sys.active_region = sys.tia.region;\n'
        '    push_av_info();\n    return true;')
    text = text[:begin] + restore + text[end:]
    bridge.write_text(text)
    return root, pin

def stage_notice(content, base=BASE):
    root, pin = prepare(base)
    # Replace only the Stella section in the public copy, preserving all other notices.
    path = content / 'EngineLicenses.txt'
    text = path.read_text()
    marker = '\n' + '=' * 70 + '\n'
    sections = text.split(marker)
    sections = [s for s in sections if not s.startswith('stella\n') and not s.startswith('tia\n')]
    notice = ('tia · GPL-2.0-or-later\nhttps://github.com/' + pin['repo'] + '/tree/' + pin['commit']
              + '\nSources carry explicit GPL-2.0-or-later grants.\n\n' + (root/'COPYING').read_text()
              + '\n\nLibretro API header (MIT):\n' + (root/'src/libretro.h').read_text().split('*/', 1)[0] + '*/\n')
    path.write_text(marker.join(sections) + marker + notice)

def apply(project, base=BASE, target_name='VetaNative'):
    root, pin = prepare(base)
    target = project['targets'][target_name]
    for dependency in target.get('dependencies', []):
        if dependency.get('target') == 'StellaCore' or Path(dependency.get('framework','')).name == 'StellaCore.framework':
            dependency.pop('framework', None)
            dependency['target'] = 'TIACore'
    settings = target.setdefault('settings', {}).setdefault('base', {})
    for key, flag in [('GCC_PREPROCESSOR_DEFINITIONS','VETA_ATARI_TIA=1'),
                      ('SWIFT_ACTIVE_COMPILATION_CONDITIONS','VETA_ATARI_TIA')]:
        values = settings.setdefault(key, ['$(inherited)'])
        if flag not in values: values.append(flag)
    project['targets'].pop('StellaCore', None)
    project['targets']['TIACore'] = {
        'type': 'framework', 'platform': 'iOS',
        'sources': [{'path': str((root/'src'/name).relative_to(base))} for name in pin['sources']],
        'settings': {'base': {
            'PRODUCT_BUNDLE_IDENTIFIER': 'com.krafify.vetaretro.core.tia',
            'GENERATE_INFOPLIST_FILE': 'YES', 'DEFINES_MODULE': 'NO', 'SKIP_INSTALL': 'YES',
            'GCC_SYMBOLS_PRIVATE_EXTERN': 'NO', 'GCC_C_LANGUAGE_STANDARD': 'gnu11',
            'GCC_OPTIMIZATION_LEVEL': '2',
            'GCC_PREPROCESSOR_DEFINITIONS': ['NDEBUG', 'CORE_VERSION=\\"6ae5bf99-veta176\\"'],
            'HEADER_SEARCH_PATHS': ['$(SRCROOT)/.build/tia-public/src'],
        }},
    }

def audit(app, base=BASE):
    errors = []
    pin = json.loads((base/'BuildSupport/tia.json').read_text())
    notice = app/'Content/EngineLicenses.txt'
    text = notice.read_text() if notice.is_file() else ''
    if 'tia · GPL-2.0-or-later' not in text or pin['commit'] not in text:
        errors.append('Missing pinned Atari license notice')
    if 'stella2014-libretro' in text:
        errors.append('Obsolete Stella notice in public resources')
    frameworks = app/'Frameworks'
    if frameworks.exists():
        if (frameworks/'StellaCore.framework').exists():
            errors.append('Obsolete Stella framework in public app')
        if not (frameworks/'TIACore.framework/TIACore').is_file():
            errors.append('Missing public Atari core')
    return errors
