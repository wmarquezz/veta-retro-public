#!/usr/bin/env python3
"""Host-only checks: pins, text-only package, syntax and refusal to overwrite.

No source downloads, builds, existing repository mutations or device actions.
Actual source/patch replay is performed separately by verify_sources.py.
"""
import ast
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from common import ROOT, PINS, check_inputs


class RecipeChecks(unittest.TestCase):
    def test_pins_and_notices(self):
        for engine in PINS['engines']:
            check_inputs(engine)
        self.assertEqual(set(PINS['engines']), {'flycast', 'play', 'dukex'})

    def test_python_syntax_without_bytecode(self):
        for path in ROOT.glob('*.py'):
            ast.parse(path.read_text(), filename=path.name)

    def test_combined_app_notice_is_current(self):
        from write_notices import render
        self.assertEqual((ROOT / 'OfflineEngineLicenses.txt').read_text(), render())

    def test_portable_text_only_package(self):
        for path in ROOT.rglob('*'):
            if not path.is_file() or '__pycache__' in path.parts:
                continue
            data = path.read_bytes()
            self.assertNotIn(b'\x00', data, path.name)
            for user_directory in (b'Users', b'home'):
                self.assertNotIn(b'/' + user_directory + b'/', data, path.name)
            data.decode('utf-8')
            self.assertNotIn(path.suffix, ('.dylib', '.wasm', '.ipa', '.bin', '.rom', '.qcow2'))

    def test_existing_destination_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix='veta-recipe-check-') as name:
            destination = Path(name) / 'source'
            destination.mkdir()
            sentinel = destination / 'existing.txt'
            sentinel.write_text('Preserve existing user work\n')
            result = subprocess.run([sys.executable, str(ROOT / 'prepare_sources.py'), 'flycast',
                                     '--destination', str(destination)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Destination must not exist', result.stderr)
            self.assertEqual(sentinel.read_text(), 'Preserve existing user work\n')
            self.assertEqual(list(destination.iterdir()), [sentinel])

    def test_cli_help_has_no_outputs(self):
        with tempfile.TemporaryDirectory(prefix='veta-recipe-help-') as name:
            environment = os.environ.copy()
            environment['PYTHONDONTWRITEBYTECODE'] = '1'
            for script in ('build.py', 'prepare_sources.py', 'verify_sources.py'):
                result = subprocess.run([sys.executable, str(ROOT / script), '--help'], cwd=name,
                                        env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list(Path(name).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
