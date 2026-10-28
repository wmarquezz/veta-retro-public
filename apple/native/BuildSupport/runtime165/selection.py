"""Select both canonical device cores together, rejecting ambiguous old overrides."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

if __package__:
    from . import recipe
else:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from runtime165 import recipe

OVERRIDES = {'DolphinCore': 'VETA_PERF165_DOLPHIN_FRAMEWORK',
             'N64NextCore': 'VETA_PERF165_N64_FRAMEWORK'}
BUILD_COMMAND = ('python3 apple/native/BuildSupport/build_advanced.py --recipe runtime165 '
                 '--sdk iphoneos --only dolphin-retro mupen-next')


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_bytes() == data:
        return
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.'+path.name+'-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def resolve(native, environment):
    native = Path(native).resolve()
    mode = environment.get('VETA_ENGINE_RECIPE', 'legacy')
    if mode not in ('legacy', 'runtime165'):
        raise ValueError('VETA_ENGINE_RECIPE must be legacy or runtime165')
    result = {'recipe': mode, 'cores': {}}
    if mode == 'legacy':
        for name, variable in OVERRIDES.items():
            if supplied := environment.get(variable):
                path = Path(supplied).resolve()
                if path.name != name+'.framework' or not (path/name).is_file():
                    raise ValueError('Invalid explicit diagnostic framework: '+name)
                result['cores'][name] = {'framework': str(path)}
        return result
    conflicts = [variable for variable in OVERRIDES.values() if variable in environment]
    if conflicts:
        raise ValueError('runtime165 forbids diagnostic framework overrides; unset '+', '.join(conflicts))
    directory = native/'.build/runtime165/iphoneos'
    try:
        for engine in ('dolphin-retro', 'mupen-next'):
            meta = recipe.metadata(engine)
            name = meta['build']['framework']
            framework = directory/(name+'.framework')
            binary = framework/name
            receipt_path = directory/(name+'-recipe.json')
            for path in (framework, binary, framework/'Info.plist', receipt_path):
                if not path.exists() or path.resolve() != path or path.is_symlink():
                    raise ValueError('Missing or redirected canonical product: '+str(path))
            if receipt_path.stat().st_size > 128*1024:
                raise ValueError('Oversized recipe receipt')
            receipt = json.loads(receipt_path.read_text())
            expected = {'recipe': 'runtime165', 'engine': engine, 'commit': meta['commit'],
                        'patchSHA256': meta['patchSHA256'], 'sdk': 'iphoneos',
                        'framework': str(framework), 'flags': meta['build']['flags']+meta['extraFlags']}
            for key, value in expected.items():
                if receipt.get(key) != value:
                    raise ValueError('Canonical recipe receipt mismatch: '+name+'/'+key)
            digest = recipe.digest(binary)
            if receipt.get('sha256') != digest:
                raise ValueError('Canonical binary hash mismatch: '+name)
            info = plistlib.loads((framework/'Info.plist').read_bytes())
            if info.get('CFBundleIdentifier') != meta['bundleIdentifier'] or info.get('CFBundleExecutable') != name:
                raise ValueError('Canonical framework identifier mismatch: '+name)
            abi = recipe.verify_binary(engine, binary)
            if receipt.get('abi') != abi:
                raise ValueError('Canonical ABI receipt mismatch: '+name)
            uuid = subprocess.check_output(['dwarfdump', '--uuid', str(binary)], text=True).strip()
            if receipt.get('uuid') != uuid:
                raise ValueError('Canonical UUID receipt mismatch: '+name)
            result['cores'][name] = {'framework': str(framework), 'binarySHA256': digest,
                                     'recipeSHA256': recipe.digest(receipt_path), 'uuid': uuid}
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise ValueError(str(error)+'\nRebuild explicitly, then regenerate the project:\n'+BUILD_COMMAND) from error
    return result


def apply_dependencies(target, selected):
    """Validate all replacements before mutating the generated target."""
    replacements = []
    for name, record in selected['cores'].items():
        matches = [dep for dep in target['dependencies']
                   if Path(dep.get('framework', '')).name == name+'.xcframework']
        if len(matches) != 1:
            raise ValueError('Expected exactly one original dependency for '+name)
        replacements.append((matches[0], record['framework']))
    for dep, framework in replacements:
        dep['framework'] = framework
    return [name+'='+record['framework'] for name, record in selected['cores'].items()]


def stage_notices(native, selected):
    if selected['recipe'] != 'runtime165':
        return
    import write_extra_credits
    native = Path(native).resolve()
    text = write_extra_credits.collect(native, native/'.build/runtime165/engine-sources')
    output = native/'Content/EngineLicenses.txt'
    record = dict(selected, licenseSHA256=hashlib.sha256(text.encode()).hexdigest(), schema=1)
    # Every source and both products were validated before touching resources.
    atomic_write(output, text.encode())
    atomic_write(native/'.build/runtime165/integration-selection.json',
                 (json.dumps(record, indent=2)+'\n').encode())


def verify_prepared(native):
    native = Path(native).resolve()
    saved = json.loads((native/'.build/runtime165/integration-selection.json').read_text())
    current = resolve(native, {'VETA_ENGINE_RECIPE': 'runtime165'})
    if saved.get('schema') != 1 or saved.get('recipe') != current['recipe'] or saved.get('cores') != current['cores']:
        raise ValueError('Canonical selection changed since project preparation; regenerate project')
    if recipe.digest(native/'Content/EngineLicenses.txt') != saved.get('licenseSHA256'):
        raise ValueError('Canonical license resource changed since project preparation')
    return current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-prepared', action='store_true', required=True)
    parser.add_argument('--native-root', type=Path, required=True)
    args = parser.parse_args()
    verify_prepared(args.native_root)
    print('VETA runtime165 selected products and notices verified')


if __name__ == '__main__':
    main()
