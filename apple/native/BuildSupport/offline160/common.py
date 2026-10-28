"""Shared helpers for explicit, isolated source recipes (Python 3.9+)."""
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PINS = json.loads((ROOT / 'pins.json').read_text())


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def git(source, *args, **kwargs):
    return subprocess.check_output(['git', '-C', str(source), *map(str, args)], **kwargs)


def check_inputs(engine):
    meta = PINS['engines'][engine]
    for step in meta['patches']:
        if digest(ROOT / step['patch']) != step['sha256']:
            raise ValueError('Patch changed: ' + step['patch'])
    for notice in PINS['license_notices']:
        if digest(ROOT / notice['copy']) != notice['sha256']:
            raise ValueError('License notice changed: ' + notice['copy'])
    if engine == 'dukex':
        dependencies = meta['dependencies']['vcpkg']
        for name in ('patch', 'triplet'):
            if digest(ROOT / dependencies[name]) != dependencies[name + '_sha256']:
                raise ValueError('DukeX dependency recipe changed: ' + name)
    return meta


def check_revision(source, expected):
    actual = git(source, 'rev-parse', 'HEAD').decode().strip()
    if actual != expected:
        raise ValueError('Unexpected source revision: ' + actual)


def check_submodules(source, meta):
    for module in meta['submodules']:
        directory = source / module['path']
        if module['initialized_in_reference'] or (directory / '.git').exists():
            check_revision(directory, module['revision'])
