"""Stage a small, pinned public catalog without changing development/personal data."""
import hashlib
import json
import shutil
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def policy(base=BASE):
    data = json.loads((base / 'Publication/public-games.json').read_text())
    games = data['games']
    if not 2 <= len(games) <= data['maximumGames'] <= 4:
        raise ValueError('Public catalog must contain 2–4 reviewed games')
    if len({g['id'] for g in games}) != len(games):
        raise ValueError('Duplicate public game')
    for g in games:
        if not g['id'] or Path(g['id']).name != g['id'] or g['id'] in ('.', '..'):
            raise ValueError('Unsafe game identifier')
        for name in g['files']:
            if Path(name).name != name or name in ('.', '..'):
                raise ValueError('Unsafe game resource')
    return data


def stage(base=BASE):
    data = policy(base)
    all_games = json.loads((base / 'Sources/DiscoveryCatalog.json').read_text())
    selected = []
    # Validate every input before replacing only our generated staging directory.
    for game in data['games']:
        entry = next(g for g in all_games if g['id'] == game['id'])
        if entry.get('bundled') != game['id'] or entry.get('download') or entry['license'] != game['license']:
            raise ValueError('Only reviewed, included games are allowed')
        if entry != game['catalogEntry']:
            raise ValueError('Public game metadata changed; review it before packaging')
        for name, expected in game['files'].items():
            path = base / 'Content' / game['id'] / name
            if path.is_symlink() or digest(path) != expected:
                raise ValueError(f'Unreviewed or modified resource: {path}')
        selected.append(entry)
    root = base / '.build/public-games'
    if root.exists():
        shutil.rmtree(root)
    content = root / 'Content'
    content.mkdir(parents=True)
    # Engine resources remain subject to the separate engine/font rights audit.
    for name in data['engineResourceDirectories'] + data['engineNoticeFiles']:
        src = base / 'Content' / name
        if src.is_dir():
            shutil.copytree(src, content / name)
        else:
            shutil.copy2(src, content / name)
    for game in data['games']:
        folder = content / game['id']
        folder.mkdir()
        for name in game['files']:
            shutil.copy2(base / 'Content' / game['id'] / name, folder / name)
    shutil.copytree(base / 'BuildSupport/thirdparty-notices/ppsspp',
                    content / 'PPSSPP/VETA-Font-Notices', dirs_exist_ok=True)
    from public_font_assets import stage as stage_fonts
    stage_fonts(content, base)
    from public_atari import stage_notice
    stage_notice(content, base)
    (root / 'DiscoveryCatalog.json').write_text(json.dumps(selected, ensure_ascii=False, indent=2) + '\n')
    return root


def apply(project, base=BASE):
    from public_atari import apply as apply_atari
    apply_atari(project, base)
    root = stage(base)
    target = project['targets']['VetaNative']
    # Public PS2 is retired until a usable local engine is validated.
    target['dependencies'] = [d for d in target.get('dependencies', []) if 'PS2Core' not in d.get('framework', '')]
    sources = target['sources']
    for source in sources:
        if source.get('path') == 'Sources':
            exclusions = source.setdefault('excludes', [])
            if 'DiscoveryCatalog.json' not in exclusions:
                exclusions.append('DiscoveryCatalog.json')
    sources[:] = [s for s in sources if s.get('path') != 'Content'
                  and '.build/public-games/' not in s.get('path', '')]
    sources.extend([
        {'path': str((root / 'Content').relative_to(base)), 'type': 'folder', 'buildPhase': 'resources'},
        {'path': str((root / 'DiscoveryCatalog.json').relative_to(base)), 'buildPhase': 'resources'},
    ])


def audit(app, base=BASE):
    """Audit staged resources or a built app; do not trust a self-declared manifest."""
    data = policy(base)
    expected_ids = {g['id'] for g in data['games']}
    from public_atari import audit as audit_atari
    errors = audit_atari(app, base)
    catalogs = list(app.rglob('DiscoveryCatalog.json'))
    if len(catalogs) != 1:
        return ['Exactly one public discovery catalog is required']
    entries = json.loads(catalogs[0].read_text())
    if len(entries) != len(expected_ids) or {g['id'] for g in entries} != expected_ids:
        errors.append('Public catalog differs from reviewed selection')
    for entry in entries:
        if entry.get('download') or entry.get('bundled') != entry['id']:
            errors.append('External/unbundled public game: ' + entry['id'])
        reviewed = next((g for g in data['games'] if g['id'] == entry['id']), None)
        if reviewed is None or entry != reviewed['catalogEntry']:
            errors.append('Unreviewed public catalog metadata: ' + entry['id'])
    content = app / 'Content'
    permitted = expected_ids | set(data['engineResourceDirectories']) | set(data['engineNoticeFiles'])
    if not content.is_dir():
        return errors + ['Missing public Content directory']
    own_notice = content / 'VETA-LICENSE.txt'
    if not own_notice.is_file() or own_notice.is_symlink() or digest(own_notice) != digest(base / 'Content/VETA-LICENSE.txt'):
        errors.append('Missing or modified VETA license notice')
    for path in content.iterdir():
        if path.name not in permitted:
            errors.append('Unreviewed Content resource: ' + path.name)
    for game in data['games']:
        folder = content / game['id']
        actual = {p.name for p in folder.iterdir()} if folder.is_dir() else set()
        if actual != set(game['files']):
            errors.append('Unexpected/missing game resources: ' + game['id'])
        for name, expected in game['files'].items():
            path = folder / name
            if not path.is_file() or path.is_symlink() or digest(path) != expected:
                errors.append('Game resource hash mismatch: ' + game['id'] + '/' + name)
    from public_font_assets import audit as audit_fonts
    errors.extend(audit_fonts(content, base))
    return errors


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply-project', action='store_true')
    parser.add_argument('--audit', type=Path)
    args = parser.parse_args()
    if args.audit:
        failures = audit(args.audit)
    elif args.apply_project:
        path = BASE / 'project.json'
        project = json.loads(path.read_text())
        apply(project)
        path.write_text(json.dumps(project, indent=2) + '\n')
        failures = audit(BASE / '.build/public-games')
    else:
        failures = audit(stage())
    print(json.dumps({'status': 'blocked' if failures else 'passed', 'errors': failures}))
    raise SystemExit(bool(failures))
