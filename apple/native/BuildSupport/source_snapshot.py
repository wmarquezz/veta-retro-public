"""Verify a distributed source snapshot without requiring private Git metadata."""
import hashlib
import json
from pathlib import Path


def verify_snapshot(path, commit):
    path = Path(path)
    manifest = path / 'VETA-SOURCE-PIN.json'
    if not manifest.is_file():
        return False
    data = json.loads(manifest.read_text())
    if data['commit'] != commit or not data['files']:
        raise ValueError('Wrong source revision: ' + path.name)
    for name, expected in data['files'].items():
        rel = Path(name)
        if rel.is_absolute() or '..' in rel.parts:
            raise ValueError('Unsafe source entry')
        file = path / rel
        if file.is_symlink() or not file.is_file():
            raise ValueError('Missing source file: ' + name)
        if hashlib.sha256(file.read_bytes()).hexdigest() != expected:
            raise ValueError('Modified source file: ' + name)
    return True
