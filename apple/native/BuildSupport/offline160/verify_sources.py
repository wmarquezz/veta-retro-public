#!/usr/bin/env python3
"""Verify patch application against pinned Git objects, without editing source.

A temporary Git index applies the patch series to each base revision. Every
changed source file is then compared byte-for-byte with the supplied tree.
No network, compilation, device action or shared Git index writes occur.
"""
import argparse
import json
import os
import tempfile
from pathlib import Path

from common import ROOT, PINS, check_inputs, check_revision, check_submodules, git


def verify(engine, source):
    meta = check_inputs(engine)
    source = Path(source).resolve()
    check_revision(source, meta['revision'])
    check_submodules(source, meta)
    groups = {}
    for step in meta['patches']:
        groups.setdefault(step['directory'], []).append(step)
    changed_count = 0
    for directory, steps in groups.items():
        tree = source / directory
        with tempfile.TemporaryDirectory(prefix='veta-offline160-index-') as temporary:
            environment = os.environ.copy()
            environment['GIT_INDEX_FILE'] = str(Path(temporary) / 'index')
            def invoke(*args):
                return git(tree, *args, env=environment)
            invoke('read-tree', 'HEAD')
            for step in steps:
                invoke('apply', '--cached', (ROOT / step['patch']).resolve())
            changed = invoke('diff', '--cached', '--name-only', 'HEAD').decode().splitlines()
            for filename in changed:
                current = tree / filename
                entries = invoke('ls-files', '-s', '--', filename).decode().split()
                if not entries:
                    if current.exists():
                        raise ValueError('Expected deleted file: ' + filename)
                elif not current.is_file() or current.read_bytes() != invoke('show', ':' + filename):
                    raise ValueError('Patched source differs: ' + filename)
            changed_count += len(changed)
    if engine == 'dukex':
        from common import digest
        for name, expected in meta['meson_wraps'].items():
            if digest(source / 'subprojects' / name) != expected:
                raise ValueError('Meson dependency pin changed: ' + name)
    return {'engine': engine, 'base_and_patch_check': 'PASS', 'patched_files_identical': changed_count,
            'initialized_submodule_revisions_checked': sum(module['initialized_in_reference'] for module in meta['submodules']),
            'build_run': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('engine', choices=PINS['engines'])
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.engine, args.source), indent=2))


if __name__ == '__main__':
    main()
