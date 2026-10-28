"""Pinned, freely licensed PPSSPP fonts for the public candidate only."""
import hashlib
import json
import shutil
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit(content, base):
    policy = json.loads((base / 'BuildSupport/source_release/font-assets.json').read_text())
    errors = []
    expected_fonts = {name for name in policy['packagedFiles']
                      if Path(name).suffix.lower() in {'.ttf', '.otf', '.pgf', '.bwfon'}}
    actual_fonts = {path.relative_to(content).as_posix()
                    for path in (content / 'PPSSPP').rglob('*')
                    if path.is_file() and path.suffix.lower() in {'.ttf', '.otf', '.pgf', '.bwfon'}}
    if expected_fonts != actual_fonts:
        errors.append('Unreviewed or missing PSP font inventory')
    for name, expected in policy['packagedFiles'].items():
        rel = Path(name)
        if rel.is_absolute() or '..' in rel.parts:
            raise ValueError('Unsafe font path')
        path = content / rel
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            errors.append('Missing or changed reviewed font resource: ' + name)
    return errors


def stage(content, base):
    policy = json.loads((base / 'BuildSupport/source_release/font-assets.json').read_text())
    for name, expected in policy['generatedAtlases'].items():
        if Path(name).name != name:
            raise ValueError('Unsafe atlas path')
        source = base / 'BuildSupport/source_release/assets' / name
        if source.is_symlink() or digest(source) != expected:
            raise ValueError('Unreviewed atlas: ' + name)
        shutil.copy2(source, content / 'PPSSPP' / name)
    errors = audit(content, base)
    if errors:
        raise ValueError('; '.join(errors))
