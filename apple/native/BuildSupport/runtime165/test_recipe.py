#!/usr/bin/env python3
"""Apply real consolidated patches in disposable file fixtures; never build/install."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import sys
import recipe
sys.path.insert(0, str(recipe.ROOT.parent))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dolphin-git', type=Path, required=True)
    parser.add_argument('--n64-git', type=Path, required=True)
    parser.add_argument('--dolphin-reference', type=Path, required=True)
    parser.add_argument('--n64-reference', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    checks = []
    references = {'dolphin-retro': (args.dolphin_git, args.dolphin_reference),
                  'mupen-next': (args.n64_git, args.n64_reference)}
    for engine, (git_source, reference) in references.items():
        meta = recipe.metadata(engine)
        assert recipe.content_state(engine, reference) == 'after'
        with tempfile.TemporaryDirectory(prefix='veta-runtime165-source-') as temporary:
            source = Path(temporary)
            for relative, hashes in meta['files'].items():
                if hashes['before'] is None:
                    continue
                content = subprocess.check_output(['git', '-C', str(git_source), 'show', meta['commit']+':'+relative])
                target = source/relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)
                assert recipe.digest(target) == hashes['before']
            assert recipe.content_state(engine, source) == 'before'
            before = {str(p.relative_to(source)): recipe.digest(p) for p in source.rglob('*') if p.is_file()}
            patch = recipe.ROOT/meta['patch']
            subprocess.run(['git', '-C', str(source), 'apply', '--check', str(patch)], check=True)
            assert before == {str(p.relative_to(source)): recipe.digest(p) for p in source.rglob('*') if p.is_file()}
            checks.append(engine+': pristine dry-run leaves all files unchanged')
            subprocess.run(['git', '-C', str(source), 'apply', str(patch)], check=True)
            assert recipe.content_state(engine, source) == 'after'
            for relative in meta['files']:
                assert (source/relative).read_bytes() == (reference/relative).read_bytes()
            checks.append(engine+': applied files byte-identical to reference ('+str(len(meta['files']))+')')
            subprocess.run(['git', '-C', str(source), 'apply', '--reverse', '--check', str(patch)], check=True)
            checks.append(engine+': complete patch reversibility')
            victim = source/next(iter(meta['files']))
            saved = victim.read_bytes();victim.write_bytes(saved+b'\n// unexpected mutation\n')
            try:
                recipe.content_state(engine, source)
                raise AssertionError('Mutation accepted')
            except ValueError:
                pass
            victim.write_bytes(saved)
            checks.append(engine+': altered source rejected')
            if engine == 'dolphin-retro':
                added = source/'Source/Core/Common/Visibility.h';added.unlink()
                try:
                    recipe.content_state(engine, source)
                    raise AssertionError('Missing new header accepted')
                except ValueError:
                    pass
                checks.append(engine+': missing Visibility.h rejected')
    # Full real checkout checks include revision, all other tracked/untracked
    # changes, submodule pins/cleanliness and required notices. No source write.
    assert recipe.prepare('dolphin-retro', args.dolphin_reference, dry_run=True)['state'] == 'after'
    checks.append('dolphin-retro: full real checkout/submodules/idempotent dry-run')
    spec = importlib.util.spec_from_file_location('credits', recipe.ROOT.parent/'write_extra_credits.py')
    credits = importlib.util.module_from_spec(spec);spec.loader.exec_module(credits)
    notices = {str(p.relative_to(args.dolphin_reference)) for p in credits.notice_paths(args.dolphin_reference)}
    assert set(recipe.metadata('dolphin-retro')['requiredNotices']) <= notices
    checks.append('all Dolphin upstream LICENSES texts included by collector')
    output = {'passed': True, 'checks': checks,
              'patches': {n: recipe.metadata(n)['patchSHA256'] for n in references},
              'scope': 'Real patch-file application and hashes, real Dolphin checkout dry-run; no compilation, iOS or bit-identical binary claim'}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(output, indent=2)+'\n')
    print(json.dumps(output, indent=2))


if __name__ == '__main__':
    main()
