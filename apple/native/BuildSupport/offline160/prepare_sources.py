#!/usr/bin/env python3
"""Create a NEW pinned source checkout and apply the recorded patch series.

This command can download public source and its pinned submodules. It never
uses a dirty working tree as source content and refuses an existing output.
"""
import argparse
import json
from pathlib import Path

from common import ROOT, PINS, check_inputs, check_revision, check_submodules, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('engine', choices=PINS['engines'])
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--reference', type=Path, help='Optional local Git object source; its edits are not copied')
    args = parser.parse_args()
    meta = check_inputs(args.engine)
    destination = args.destination.resolve()
    if destination.exists():
        parser.error('Destination must not exist; use an isolated directory')
    origin = str(args.reference.resolve()) if args.reference else meta['repository']
    run(['git', 'clone', '--no-checkout', origin, destination])
    run(['git', '-C', destination, 'remote', 'set-url', 'origin', meta['repository']])
    run(['git', '-C', destination, 'checkout', '--detach', meta['revision']])
    check_revision(destination, meta['revision'])
    # Initialize only the source modules used by the recorded build. In
    # particular, DukeX firmware/ROM submodules are neither needed nor fetched.
    initialized = []
    for module in sorted(meta['submodules'], key=lambda value: value['path'].count('/')):
        if not module['initialized_in_reference']:
            continue
        path = Path(module['path'])
        parents = [parent for parent in initialized if parent in path.parents]
        parent = max(parents, key=lambda value: len(value.parts)) if parents else Path('.')
        run(['git', '-C', destination / parent, 'submodule', 'update', '--init', '--', path.relative_to(parent)])
        initialized.append(path)
    check_submodules(destination, meta)
    for step in meta['patches']:
        patch = (ROOT / step['patch']).resolve()
        directory = destination / step['directory']
        run(['git', '-C', directory, 'apply', '--check', patch])
        run(['git', '-C', directory, 'apply', patch])
    marker = {'engine': args.engine, 'revision': meta['revision'], 'patches': meta['patches']}
    (destination / '.veta-offline160.json').write_text(json.dumps(marker, indent=2) + '\n')
    print(json.dumps({'engine': args.engine, 'source_prepared': True, 'build_run': False}))


if __name__ == '__main__':
    main()
