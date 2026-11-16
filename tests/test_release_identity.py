import copy
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from release_identity import build_identity, release_tag


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'installer').mkdir()
        (self.root / 'scripts').mkdir()
        (self.root / 'installer/Install.ps1').write_bytes(b'installer v1')
        (self.root / 'scripts/build_release.py').write_bytes(b'builder v1')
        self.lock = {'schema_version': 3, 'generated_at': 'yesterday', 'release_tag': 'old',
                     'optiscaler': {'tag': 'nightly-20261116', 'url': 'https://example.org/opti.7z',
                                   'asset_name': 'opti.7z', 'sha256': 'a' * 64,
                                   'asset_id': 1, 'asset_updated_at': 'yesterday'},
                     'optional': None}

    def tag(self, lock=None):
        return release_tag(self.lock if lock is None else lock, self.root)

    def test_same_date_replacement_gets_new_release(self):
        before = self.tag()
        self.lock['optiscaler']['sha256'] = 'b' * 64
        self.assertNotEqual(before, self.tag())

    def test_installer_only_change_gets_new_release(self):
        before = self.tag()
        (self.root / 'installer/Install.ps1').write_bytes(b'installer v2')
        self.assertNotEqual(before, self.tag())

    def test_unchanged_content_reuses_release(self):
        before = self.tag()
        changed = copy.deepcopy(self.lock)
        changed.update(generated_at='today', release_tag=before)
        changed['optiscaler'].update(asset_id=2, asset_updated_at='today')
        self.assertEqual(before, self.tag(changed))
        self.assertIn(self.tag(changed), {before})  # existing-release dedup key

    def test_optional_contracts_are_included(self):
        before = self.tag()
        self.lock['optional'] = {'enabled': False, 'mode': 'select-one', 'layout': 'plugins'}
        added = self.tag()
        self.assertNotEqual(before, added)
        self.lock['optional']['enabled'] = True
        self.assertNotEqual(added, self.tag())

    def test_urls_and_members_are_included(self):
        before = self.tag()
        self.lock['optiscaler']['url'] += '?mirror=1'
        changed = self.tag()
        self.assertNotEqual(before, changed)
        self.lock['optiscaler']['member'] = 'nested/plugin.asi'
        self.assertNotEqual(changed, self.tag())

    def test_missing_hash_refuses_premature_dedup(self):
        del self.lock['optiscaler']['sha256']
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            self.tag()

    def test_builder_change_gets_new_release(self):
        before = self.tag()
        (self.root / 'scripts/build_release.py').write_bytes(b'builder v2')
        self.assertNotEqual(before, self.tag())

    def test_bytecode_does_not_create_release(self):
        before = self.tag()
        (self.root / 'scripts/__pycache__').mkdir()
        (self.root / 'scripts/__pycache__/helper.pyc').write_bytes(b'bytecode')
        self.assertEqual(before, self.tag())

    def test_short_valid_deterministic_tag(self):
        self.assertRegex(self.tag(), r'^bundle-20261116-[a-f0-9]{20}$')
        self.assertEqual(len(build_identity(self.lock, self.root)), 64)
        self.assertLessEqual(len(self.tag()), 101)
        self.assertEqual(self.tag(), self.tag())


if __name__ == '__main__':
    unittest.main()
