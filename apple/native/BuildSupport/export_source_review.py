#!/usr/bin/env python3
"""Export an explicit, local review snapshot. Not a complete source release."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile

NATIVE = Path(__file__).resolve().parents[1]
ROOT = NATIVE.parents[1]
CORE_SHA = '6eaa6d805cd101c462705972e2d2e622fbbc303e2b76b9f9829e8022fa10966f'
PRIVATE_PATTERNS = [
    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    rb'\b(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}',
    rb'\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b',
    rb'/' + rb'Users/[^/\s]+/',
]


def payloads():
    policy = NATIVE / 'Publication/source-review-files.json'
    entries = json.loads(policy.read_text())['files']
    if len(entries) != len(set(entries)):
        raise ValueError('Duplicate source path')
    result = {}
    for name in entries:
        rel = Path(name)
        if rel.is_absolute() or '..' in rel.parts or not (name.startswith('apple/native/') or name == 'docs/EDICION-PUBLICA-179.md'):
            raise ValueError('Unsafe source path')
        source = ROOT / rel
        if any(p.is_symlink() for p in [source, *source.parents]) or not source.is_file():
            raise ValueError('Missing file or symlink: ' + name)
        if set(rel.parts) & {'.git', '.build', 'local-secrets', 'Secrets', '__pycache__'}:
            raise ValueError('Private/generated path: ' + name)
        data = source.read_bytes()
        if source.suffix != '.png' and any(re.search(pattern, data) for pattern in PRIVATE_PATTERNS):
            raise ValueError('Review private-data pattern in: ' + name)
        result[name] = data
    core = NATIVE / '.build/commercial170/commercial170-core-sources.tar.gz'
    if core.is_symlink():
        raise ValueError('Engine archive must not be a symlink')
    data = core.read_bytes()
    if hashlib.sha256(data).hexdigest() != CORE_SHA:
        raise ValueError('Engine source archive differs from reviewed receipt')
    result['third-party/commercial170-core-sources.tar.gz'] = data
    result['README.md'] = (NATIVE / 'Publication/rights/SOURCE-REVIEW.md').read_bytes()
    manifest = {
        'schema': 1,
        'status': 'local-review-only',
        'ownCodeLicense': 'GPL-3.0-or-later',
        'completeCorrespondingSource': False,
        'published': False,
        'files': {name: {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
                  for name, data in sorted(result.items())},
    }
    result['SOURCE-MANIFEST.json'] = (json.dumps(manifest, ensure_ascii=False, indent=2) + '\n').encode()
    return result


def export(destination):
    files = payloads()  # Validate everything before creating the output.
    with destination.open('xb') as raw:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as archive:
                for name, data in sorted(files.items()):
                    member = tarfile.TarInfo('veta-source-review/' + name)
                    member.size = len(data)
                    member.mode = 0o644
                    archive.addfile(member, io.BytesIO(data))
    return {'status': 'local-review-only', 'files': len(files), 'bytes': destination.stat().st_size,
            'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
            'completeCorrespondingSource': False, 'published': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(export(args.output), ensure_ascii=False, indent=2))
