"""Pinned source-only recipes; no device operation, credentials or game assets."""
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PINS = json.loads((ROOT / 'pins.json').read_text())


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def metadata(engine):
    meta = PINS['engines'][engine]
    for relative, expected in PINS['recipeInputs'].items():
        if digest(ROOT.parent / relative) != expected:
            raise ValueError('Build recipe input changed: ' + relative)
    if digest(ROOT / meta['patch']) != meta['patchSHA256']:
        raise ValueError('Recipe patch hash mismatch: ' + engine)
    return meta


def verify_build_metadata(meta):
    expected = metadata(meta['name'])
    for key in ('repo', 'commit'):
        if meta[key] != expected[key]:
            raise ValueError('Advanced source metadata changed: ' + key)
    for key, value in expected['build'].items():
        if meta[key] != value:
            raise ValueError('Advanced build metadata changed: ' + key)


def git(source, *arguments):
    return subprocess.check_output(['git', '-C', str(source), *arguments], text=True).strip()


def content_state(engine, source):
    """Check every patched/new file, including the otherwise untracked Visibility.h."""
    meta = metadata(engine)
    states = []
    for relative, hashes in meta['files'].items():
        path = source / relative
        if path.is_symlink():
            raise ValueError('Patched source cannot be a symlink: ' + relative)
        actual = digest(path) if path.is_file() else None
        states.append({phase for phase in ('before', 'after') if actual == hashes[phase]})
    common = set.intersection(*states)
    if not common:
        raise ValueError('Source differs from both pristine and complete recipe: ' + engine)
    return 'after' if 'after' in common else 'before'


def verify_checkout(engine, source):
    meta = metadata(engine)
    if git(source, 'rev-parse', 'HEAD') != meta['commit']:
        raise ValueError('Source revision mismatch: ' + engine)
    expected = set(meta['files'])
    changed = set(git(source, 'diff', '--name-only', 'HEAD').splitlines())
    untracked = set(git(source, 'ls-files', '--others', '--exclude-standard').splitlines())
    if (changed | untracked) - expected:
        raise ValueError('Unexpected local source changes: ' + repr(sorted((changed | untracked) - expected)))
    for module in meta['submodules']:
        directory = source / module['path']
        if not (directory / '.git').exists() or git(directory, 'rev-parse', 'HEAD') != module['commit']:
            raise ValueError('Submodule revision mismatch: ' + module['path'])
        if git(directory, 'status', '--porcelain', '--untracked-files=normal'):
            raise ValueError('Modified submodule: ' + module['path'])
    for module in meta['uninitializedGitlinks']:
        directory = source / module['path']
        line = git(source, 'ls-tree', 'HEAD', '--', module['path'])
        if not line.startswith('160000 commit ' + module['commit'] + '\t'):
            raise ValueError('Unexpected unmapped gitlink: ' + module['path'])
        if directory.exists() and (directory.is_symlink() or any(directory.iterdir())):
            raise ValueError('Expected unused empty upstream gitlink: ' + module['path'])
    for relative in meta['requiredNotices']:
        if not (source / relative).is_file():
            raise ValueError('Missing upstream notice: ' + relative)
    return content_state(engine, source)


def prepare(engine, source, dry_run=False):
    state = verify_checkout(engine, source)
    patch = ROOT / metadata(engine)['patch']
    if state == 'before':
        subprocess.run(['git', '-C', str(source), 'apply', '--check', str(patch)], check=True)
        if not dry_run:
            subprocess.run(['git', '-C', str(source), 'apply', str(patch)], check=True)
            if verify_checkout(engine, source) != 'after':
                raise ValueError('Post-apply source verification failed')
    return {'engine': engine, 'commit': metadata(engine)['commit'],
            'patchSHA256': metadata(engine)['patchSHA256'],
            'state': state if dry_run else 'after', 'dryRun': dry_run}


def verify_binary(engine, binary):
    expected = metadata(engine)['abi']
    symbols = sorted(' '.join(line.split()[1:]) for line in
                     subprocess.check_output(['nm', '-gU', str(binary)], text=True).splitlines()
                     if line.strip())
    symbol_hash = hashlib.sha256(('\n'.join(symbols)+'\n').encode()).hexdigest()
    dependencies = [line.strip() for line in
                    subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]]
    arch = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
    platform = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
    if len(symbols) != expected['symbolCount'] or symbol_hash != expected['normalizedSymbolsSHA256']:
        raise ValueError('Exported ABI differs from pinned reference: ' + engine)
    if dependencies != expected['dependencies'] or arch != expected['architecture']:
        raise ValueError('Dependencies or architecture differ: ' + engine)
    fields = dict(line.strip().split(None, 1) for line in platform.splitlines()
                  if line.strip().startswith(('platform ', 'minos ')))
    if fields.get('platform') != expected['platform'] or fields.get('minos') != expected['minimumOS']:
        raise ValueError('Unexpected binary platform/deployment target: ' + engine)
    return {'exportedSymbolCount': len(symbols), 'normalizedSymbolsSHA256': symbol_hash,
            'dependenciesEqual': True, 'architecture': arch, 'platform': fields['platform'],
            'minimumOS': fields['minos']}
