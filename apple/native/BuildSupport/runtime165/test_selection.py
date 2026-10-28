#!/usr/bin/env python3
"""Read canonical products; test mutations only in temporary independent copies."""
import copy
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import sys
import tempfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from runtime165 import selection
import write_extra_credits


def main():
    native = Path(__file__).resolve().parents[2]
    checks = []
    def rejects(label, action):
        try:
            action()
        except (ValueError, FileNotFoundError):
            checks.append(label)
        else:
            raise AssertionError('Expected rejection: '+label)
    assert selection.resolve(native, {}) == {'recipe': 'legacy', 'cores': {}}
    checks.append('general selector remains legacy without canonical filesystem dependence')
    rejects('unknown recipe rejected', lambda: selection.resolve(native, {'VETA_ENGINE_RECIPE': 'unknown'}))
    for variable in selection.OVERRIDES.values():
        rejects('canonical conflicts with '+variable, lambda variable=variable:
                selection.resolve(native, {'VETA_ENGINE_RECIPE': 'runtime165', variable: ''}))
    canonical = selection.resolve(native, {'VETA_ENGINE_RECIPE': 'runtime165'})
    assert set(canonical['cores']) == {'DolphinCore', 'N64NextCore'}
    checks.append('real canonical pins/hash/ABI/plist/UUID verified for both cores')
    project = json.loads((native/'jit-development.json').read_text())
    original = project['targets']['VetaJITLab']
    target = copy.deepcopy(original)
    selection.apply_dependencies(target, selection.resolve(native, {}))
    assert target == original
    checks.append('legacy generated dependencies unchanged')
    target = copy.deepcopy(original)
    overrides = selection.apply_dependencies(target, canonical)
    assert len(overrides) == 2
    assert sum(Path(dep.get('framework','')).suffix == '.framework' and
               Path(dep.get('framework','')).stem in canonical['cores'] for dep in target['dependencies']) == 2
    checks.append('exactly two canonical replacements')
    broken = copy.deepcopy(original)
    broken['dependencies'].append(next(copy.deepcopy(d) for d in broken['dependencies']
                                       if Path(d.get('framework','')).name == 'N64NextCore.xcframework'))
    before = copy.deepcopy(broken)
    rejects('duplicate target rejected before either mutation', lambda: selection.apply_dependencies(broken, canonical))
    assert before == broken
    notices = write_extra_credits.collect(native, native/'.build/runtime165/engine-sources')
    assert 'https://github.com/Provenance-Emu/iCube/tree/e0fa51223d897beaf0aca1671095242232b3595b' in notices
    for f in (native/'.build/runtime165/engine-sources/dolphin-retro/LICENSES').iterdir():
        if f.is_file():
            assert f.read_text() in notices
    checks.append('real canonical collector includes full LICENSES and pinned iCube attribution')
    with tempfile.TemporaryDirectory(prefix='veta-select165-') as temporary:
        other = Path(temporary).resolve()
        rejects('missing canonical files rejected', lambda: selection.resolve(other, {'VETA_ENGINE_RECIPE': 'runtime165'}))
        products = other/'.build/runtime165/iphoneos'
        products.mkdir(parents=True)
        for name, record in canonical['cores'].items():
            source = Path(record['framework'])
            shutil.copytree(source, products/source.name)
            receipt = json.loads((source.parent/(name+'-recipe.json')).read_text())
            receipt['framework'] = str(products/source.name)
            receipt['uuid'] = receipt['uuid'].replace(str(source), str(products/source.name))
            (products/(name+'-recipe.json')).write_text(json.dumps(receipt))
        test_selected = selection.resolve(other, {'VETA_ENGINE_RECIPE': 'runtime165'})
        checks.append('independent relocated fixture accepted after correct receipt regeneration')
        name = 'DolphinCore'
        receipt_path = products/(name+'-recipe.json')
        saved = receipt_path.read_bytes()
        value = json.loads(saved); value['commit'] = '0'*40; receipt_path.write_text(json.dumps(value))
        rejects('wrong upstream pin rejected', lambda: selection.resolve(other, {'VETA_ENGINE_RECIPE': 'runtime165'}))
        receipt_path.write_bytes(saved)
        binary = products/(name+'.framework')/name
        with binary.open('ab') as stream: stream.write(b'changed')
        rejects('changed binary rejected by receipt hash', lambda: selection.resolve(other, {'VETA_ENGINE_RECIPE': 'runtime165'}))
        shutil.copyfile(Path(canonical['cores'][name]['framework'])/name, binary)
        receipt_path.unlink()
        rejects('missing receipt rejected', lambda: selection.resolve(other, {'VETA_ENGINE_RECIPE': 'runtime165'}))
        receipt_path.write_bytes(saved)
        with patch.object(write_extra_credits, 'collect', return_value=notices):
            selection.stage_notices(other, test_selected)
        assert (other/'Content/EngineLicenses.txt').read_text() == notices
        assert selection.verify_prepared(other) == test_selected
        checks.append('staged selection and complete notices pass pre-embed verification')
        stamp = (other/'Content/EngineLicenses.txt').stat().st_mtime_ns
        with patch.object(write_extra_credits, 'collect', return_value=notices):
            selection.stage_notices(other, test_selected)
        assert (other/'Content/EngineLicenses.txt').stat().st_mtime_ns == stamp
        checks.append('unchanged notice staging preserves mtime')
        (other/'Content/EngineLicenses.txt').write_text('altered')
        rejects('changed app notice rejected before embed', lambda: selection.verify_prepared(other))
        (other/'Content/EngineLicenses.txt').write_text(notices)
        value = json.loads(receipt_path.read_text()); value['compiler'] += 'changed'; receipt_path.write_text(json.dumps(value))
        rejects('receipt changed after project preparation rejected', lambda: selection.verify_prepared(other))
        receipt_path.write_bytes(saved)
        # Execute real prepare script while capturing its sole project write and
        # XcodeGen call. No source project, resource, build or phone mutation.
        captured = {}
        def capture_write(path, text, *args, **kwargs):
            assert path == native/'jit-integrated.json', path
            captured['project'] = json.loads(text)
            return len(text)
        def capture_run(command, **kwargs):
            assert command[:2] == ['xcodegen', 'generate'], command
            captured['command'] = command
        def stage_check(base, selected):
            assert base == native and selected == canonical
            captured['stage'] = True
        with patch.dict(os.environ, {'VETA_ENGINE_RECIPE':'runtime165'}, clear=True), \
             patch.object(selection, 'resolve', return_value=canonical), \
             patch.object(selection, 'stage_notices', side_effect=stage_check), \
             patch.object(Path, 'write_text', capture_write), \
             patch('subprocess.run', side_effect=capture_run):
            runpy.run_path(str(native.parent/'integrated-jit/prepare_veta.py'), run_name='__main__')
        generated = captured['project']['targets']['VetaJITLab']
        scripts = [s for s in generated['postBuildScripts'] if 'verify_embed_runtime.py' in s['script']]
        assert captured['stage'] and len(scripts) == 1 and scripts[0]['basedOnDependencyAnalysis'] is False
        assert 'set -e\n' in scripts[0]['script'] and '--verify-prepared' in scripts[0]['script']
        assert all(record['framework'] in scripts[0]['script'] for record in canonical['cores'].values())
        checks.append('real prepare integration stages notices and always verifies selection before exact embed')
    # The integrated iPhone entry point owns the promoted default. Execute it
    # with the REAL resolver; allow only read-only binary inspection subprocesses.
    real_run = __import__('subprocess').run
    prepare = native.parent/'integrated-jit/prepare_veta.py'
    def inspect_or_generate(command, **kwargs):
        if command[:2] == ['xcodegen', 'generate']:
            captured['command'] = command
            return None
        assert command[0] in ('nm', 'otool', 'lipo', 'dwarfdump') or command[:2] == ['xcrun', 'vtool'], command
        return real_run(command, **kwargs)
    def stage_capture(base, selected):
        assert base == native
        captured['selection'] = selected
    for environment, expected in [({}, canonical), ({'VETA_ENGINE_RECIPE':'legacy'}, {'recipe':'legacy','cores':{}})]:
        captured = {}
        with patch.dict(os.environ, environment, clear=True), \
             patch.object(selection, 'stage_notices', side_effect=stage_capture), \
             patch.object(Path, 'write_text', capture_write), \
             patch('subprocess.run', side_effect=inspect_or_generate):
            runpy.run_path(str(prepare), run_name='__main__')
        assert captured['selection'] == expected
        assert 'command' in captured
        generated = captured['project']['targets']['VetaJITLab']
        replacements = [d for d in generated['dependencies'] if Path(d.get('framework','')).suffix == '.framework'
                        and Path(d.get('framework','')).stem in canonical['cores']]
        assert len(replacements) == (2 if expected['recipe'] == 'runtime165' else 0)
        if expected['recipe'] == 'runtime165':
            scripts = [s for s in generated['postBuildScripts'] if 'verify_embed_runtime.py' in s['script']]
            assert len(scripts) == 1 and '--verify-prepared' in scripts[0]['script']
        checks.append('integrated generator '+('empty environment selects verified canonical pair' if not environment else 'explicit legacy retains prior dependencies'))
    def reject_prepare(environment, label):
        with patch.dict(os.environ, environment, clear=True), \
             patch.object(selection, 'stage_notices', side_effect=AssertionError('unexpected notice write')), \
             patch.object(Path, 'write_text', side_effect=AssertionError('unexpected project write')), \
             patch('subprocess.run', side_effect=AssertionError('unexpected subprocess/build/download')):
            rejects(label, lambda: runpy.run_path(str(prepare), run_name='__main__'))
    for variable in selection.OVERRIDES.values():
        reject_prepare({variable:''}, 'integrated default rejects inherited '+variable+' before writes')
    reject_prepare({'VETA_ENGINE_RECIPE':''}, 'integrated empty recipe fails rather than falling back')
    with tempfile.TemporaryDirectory(prefix='veta-default-missing-') as missing:
        real_resolve = selection.resolve
        def resolve_missing(_native, environment):
            assert environment['VETA_ENGINE_RECIPE'] == 'runtime165'
            try:
                return real_resolve(Path(missing), environment)
            except ValueError as error:
                assert selection.BUILD_COMMAND in str(error)
                raise
        with patch.object(selection, 'resolve', side_effect=resolve_missing):
            reject_prepare({}, 'integrated default missing products fails with explicit command and no mutation/download')
    print(json.dumps({'passed': True, 'checks': checks, 'fullAppBuild':'NOT_RUN', 'phone':'NOT_OPERATED'}, indent=2))


if __name__ == '__main__':
    main()
