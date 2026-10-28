#!/usr/bin/env python3
"""Collect original notices alongside pinned source URLs for embedded cores."""
import argparse
import json
from pathlib import Path
from runtime165 import recipe

BASE = Path(__file__).resolve().parents[1]


def notice_paths(source):
    # SPDX collections often name the files GPL-2.0-or-later.txt/MIT.txt rather
    # than LICENSE. Include all files inside a LICENSES directory as well.
    return sorted(p for p in source.rglob('*') if p.is_file() and
                  (any(part.lower() == 'licenses' for part in p.relative_to(source).parts[:-1]) or
                   p.name.lower().startswith(('license', 'copying', 'copyright')) or
                   p.name.lower() in ('gpl-license', 'lgpl-license')))


def collect(base=BASE, runtime165_source_root=None):
    base = Path(base)
    items = [item for item in json.loads((base/'BuildSupport/extra-cores.json').read_text()) if item['name'] != 'genesis']
    psp = json.loads((base/'BuildSupport/ppsspp.json').read_text())
    items.append({'name': 'ppsspp', 'repo': 'hrydgard/ppsspp', 'commit': psp['commit']})
    advanced = json.loads((base/'BuildSupport/advanced-cores.json').read_text())
    items += advanced
    sections = []
    for item in items:
        source = base/'.build'/('engine-sources' if item in advanced else '')/item['name']
        provenance = []
        if runtime165_source_root and item['name'] in recipe.PINS['engines']:
            source = runtime165_source_root.resolve()/item['name']
            if recipe.verify_checkout(item['name'], source) != 'after':
                raise ValueError('Notices require fully prepared runtime165 source')
            meta = recipe.metadata(item['name'])
            if item['commit'] != meta['commit'] or item['repo'] != meta['repo']:
                raise ValueError('Notice source metadata differs from recipe')
            provenance = meta['attribution']
        sections.append(f"\n{'=' * 70}\n{item['name']}\nhttps://github.com/{item['repo']}/tree/{item['commit']}\n")
        for extra in provenance:
            sections.append(f"Derived source: https://github.com/{extra['repo']}/tree/{extra['commit']}\n{extra['scope']}\n")
        for path in notice_paths(source):
            sections.append(f'\n--- {path.relative_to(source)} ---\n'+path.read_text(errors='replace'))
    for name in ('BSNES','JGenesis'):
        path=base/'Content'/(name+'-LICENSE.txt')
        if not path.is_file():raise ValueError('Stage commercial170 notices before collecting: '+name)
        sections.append(path.read_text())
    return '\n'.join(sections)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime165-source-root', type=Path,
                        help='Prepared root containing dolphin-retro and mupen-next; verify pins before collecting')
    parser.add_argument('--output', type=Path, default=BASE/'Content/EngineLicenses.txt')
    args = parser.parse_args()
    from runtime165.selection import atomic_write
    atomic_write(args.output, collect(BASE, args.runtime165_source_root).encode())


if __name__ == '__main__':
    main()
