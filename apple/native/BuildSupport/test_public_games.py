"""Regression checks for accidental redistribution, without operating a device."""
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from public_games import BASE, audit, stage


class PublicGamesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = stage()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Candidate.app'
        shutil.copytree(self.source, self.app)

    def test_selected_two_and_licenses(self):
        self.assertEqual(audit(self.app), [])
        catalog = json.loads((self.app / 'DiscoveryCatalog.json').read_text())
        self.assertEqual({g['id'] for g in catalog}, {'akanoid-gb', 'space-game'})

    def test_extra_game_rejected_even_if_not_in_catalog(self):
        (self.app / 'Content/unreviewed').mkdir()
        self.assertTrue(audit(self.app))

    def test_fifth_offer_rejected(self):
        path = self.app / 'DiscoveryCatalog.json'
        entries = json.loads(path.read_text())
        entries += [dict(entries[0], id='extra' + str(i)) for i in range(3)]
        path.write_text(json.dumps(entries))
        self.assertTrue(audit(self.app))

    def test_external_download_rejected(self):
        path = self.app / 'DiscoveryCatalog.json'
        entries = json.loads(path.read_text())
        entries[0]['download'] = 'https://example.com/not-reviewed.gb'
        path.write_text(json.dumps(entries))
        self.assertTrue(audit(self.app))

    def test_changed_rom_rejected(self):
        (self.app / 'Content/space-game/space-game.gba').write_bytes(b'changed')
        self.assertTrue(audit(self.app))

    def test_missing_license_rejected(self):
        (self.app / 'Content/akanoid-gb/LICENSE.txt').unlink()
        self.assertTrue(audit(self.app))

    def test_duplicate_catalog_rejected(self):
        shutil.copy2(self.app / 'DiscoveryCatalog.json', self.app / 'Content/DiscoveryCatalog.json')
        self.assertTrue(audit(self.app))

    def test_development_content_preserved(self):
        self.assertTrue((BASE / 'Content/thwaite/thwaite.nes').is_file())
        self.assertEqual(len(json.loads((BASE / 'Sources/DiscoveryCatalog.json').read_text())), 40)
        self.assertFalse((self.app / 'Content/thwaite').exists())


if __name__ == '__main__':
    unittest.main()
