"""Mutation tests: altered inputs must not pass a source/font release check."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(BASE / 'BuildSupport'))
from source_snapshot import verify_snapshot
from public_games import stage
from public_font_assets import audit


class SnapshotTests(unittest.TestCase):
    def test_rejects_changed_missing_and_escaping_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'source.c').write_bytes(b'original')
            manifest = {'commit':'pin', 'files':{'source.c':hashlib.sha256(b'original').hexdigest()}}
            path = root / 'VETA-SOURCE-PIN.json'
            path.write_text(json.dumps(manifest))
            self.assertTrue(verify_snapshot(root, 'pin'))
            with self.assertRaises(ValueError): verify_snapshot(root, 'other-pin')
            (root / 'source.c').write_bytes(b'changed')
            with self.assertRaises(ValueError): verify_snapshot(root, 'pin')
            (root / 'source.c').unlink()
            with self.assertRaises(ValueError): verify_snapshot(root, 'pin')
            manifest['files'] = {'../outside':'irrelevant'}
            path.write_text(json.dumps(manifest))
            with self.assertRaises(ValueError): verify_snapshot(root, 'pin')

    def test_font_tampering_and_new_font_are_rejected(self):
        staged = stage()
        with tempfile.TemporaryDirectory() as temp:
            content = Path(temp) / 'Content'
            shutil.copytree(staged / 'Content', content)
            self.assertEqual(audit(content, BASE), [])
            atlas = content / 'PPSSPP/font_atlas.zim'
            original = atlas.read_bytes()
            atlas.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
            self.assertTrue(audit(content, BASE))
            atlas.write_bytes(original)
            (content / 'PPSSPP/unreviewed.pgf').write_bytes(b'not a reviewed font')
            self.assertTrue(audit(content, BASE))


if __name__ == '__main__': unittest.main()
