"""Network-free integration tests for the builder's real main() ordering."""
import copy
from contextlib import ExitStack
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import build_release as builder


def digest(data):
    return hashlib.sha256(data).hexdigest()


class BuilderMainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'installer').mkdir()
        (self.root / 'installer/Install.ps1').write_bytes(b'synthetic installer')
        self.payloads = {key: (key + '-v1').encode() for key in builder.ASSET_FAMILIES}
        self.lock = {'schema_version': 3, 'generated_at': 'synthetic-time'}
        for key in builder.ASSET_FAMILIES:
            self.lock[key] = {'asset_name': key + '.zip', 'url': 'https://example.test/' + key,
                              'tag': 'nightly-20261116' if key == 'optiscaler' else 'v1',
                              'member': None}
            if key not in ('mochizuki', 'cjk'):
                self.lock[key]['sha256'] = digest(self.payloads[key])
        self.events = []
        self.downloaded = []

    def resolved(self):
        lock = copy.deepcopy(self.lock)
        for key, data in self.payloads.items():
            lock[key]['sha256'] = digest(data)
        return lock

    def run_main(self, existing, *, validation_error=None):
        def download(url, path):
            key = url.rsplit('/', 1)[-1]
            self.downloaded.append(key)
            self.events.append('download:' + key)
            path.write_bytes(self.payloads[key])
            return digest(self.payloads[key])

        def exists(repo, tag):
            self.events.append('dedup')
            # The real release_tag() rejects missing SHA values, so reaching this
            # point establishes that both GitLab hashes are already in the lock.
            self.assertEqual(repo, 'owner/repo')
            self.assertRegex(tag, r'^bundle-20261116-[a-f0-9]{20}$')
            return existing(tag)

        def validate_optional(paths, lock):
            self.events.append('validate:optional')
            for key, path in paths.items():
                if path is not None:
                    self.assertEqual(path.read_bytes(), self.payloads[key])
                    self.assertEqual(lock[key]['sha256'], digest(self.payloads[key]))
            if validation_error:
                raise ValueError(validation_error)

        with ExitStack() as stack:
            stack.enter_context(patch.object(builder, 'ROOT', self.root))
            stack.enter_context(patch.object(sys, 'argv', ['build_release.py', '--repository', 'owner/repo',
                                                         '--out', str(self.root / 'out')]))
            stack.enter_context(patch.object(builder, 'find_releases', side_effect=lambda: copy.deepcopy(self.lock)))
            # URL allowlisting is outside this test; no network function is allowed.
            stack.enter_context(patch.object(builder, 'valid_url', side_effect=lambda url, family: url))
            stack.enter_context(patch.object(builder, 'download', side_effect=download))
            stack.enter_context(patch.object(builder, 'request', side_effect=AssertionError('Unexpected network')))
            stack.enter_context(patch.object(builder, 'release_exists', side_effect=exists))
            self.layout = stack.enter_context(patch.object(builder, 'check_layout',
                side_effect=lambda *args: self.events.append('validate:layout')))
            self.addons = stack.enter_context(patch.object(builder, 'check_addons',
                side_effect=lambda *args: self.events.append('validate:addons')))
            self.optional = stack.enter_context(patch.object(builder, 'check_optional_addons', side_effect=validate_optional))
            self.package = stack.enter_context(patch.object(builder, 'package',
                side_effect=lambda *args: self.events.append('package')))
            self.emit = stack.enter_context(patch.object(builder, 'emit'))
            builder.main()

    def test_existing_identity_hashes_gitlab_then_skips_large_assets_and_packaging(self):
        expected = builder.release_tag(self.resolved(), self.root)
        self.run_main(lambda tag: tag == expected)
        self.assertEqual(self.downloaded, ['mochizuki', 'cjk'])
        self.assertEqual(self.events, ['download:mochizuki', 'download:cjk', 'dedup'])
        self.layout.assert_not_called()
        self.addons.assert_not_called()
        self.optional.assert_not_called()
        self.package.assert_not_called()
        self.emit.assert_any_call('tag', expected)
        self.emit.assert_any_call('built', 'false')
        self.assertFalse((self.root / 'out').exists())

    def test_changed_optional_sha_builds_and_validates_new_identity(self):
        old_tag = builder.release_tag(self.resolved(), self.root)
        self.payloads['openrr'] = b'openrr-v2-same-upstream-tag'
        self.lock['openrr']['sha256'] = digest(self.payloads['openrr'])
        new_tag = builder.release_tag(self.resolved(), self.root)
        self.assertNotEqual(old_tag, new_tag)
        self.run_main(lambda tag: tag == old_tag)
        self.assertEqual(self.downloaded[:2], ['mochizuki', 'cjk'])
        self.assertEqual(set(self.downloaded), set(builder.ASSET_FAMILIES))
        self.assertEqual(len(self.downloaded), len(builder.ASSET_FAMILIES))
        self.assertLess(self.events.index('dedup'), self.events.index('download:openrr'))
        self.assertEqual(self.events[-4:], ['validate:layout', 'validate:addons', 'validate:optional', 'package'])
        self.layout.assert_called_once()
        self.addons.assert_called_once()
        self.optional.assert_called_once()
        self.package.assert_called_once()
        packaged_lock = self.package.call_args.args[0]
        self.assertEqual(packaged_lock['release_tag'], new_tag)

    def test_same_tag_gitlab_replacement_changes_identity_before_skip(self):
        old_tag = builder.release_tag(self.resolved(), self.root)
        self.payloads['mochizuki'] = b'mochizuki-v2-same-tag'
        new_tag = builder.release_tag(self.resolved(), self.root)
        self.assertNotEqual(old_tag, new_tag)
        self.run_main(lambda tag: tag == old_tag)
        self.package.assert_called_once()
        self.assertEqual(self.package.call_args.args[0]['release_tag'], new_tag)

    def test_github_hash_mismatch_refuses_packaging(self):
        self.payloads['openrr'] = b'wrong-bytes'
        with self.assertRaisesRegex(ValueError, 'SHA256 mismatch for openrr'):
            self.run_main(lambda tag: False)
        self.package.assert_not_called()
        self.optional.assert_not_called()

    def test_failed_optional_validation_refuses_packaging(self):
        with self.assertRaisesRegex(ValueError, 'synthetic invalid layout'):
            self.run_main(lambda tag: False, validation_error='synthetic invalid layout')
        self.package.assert_not_called()
        self.optional.assert_called_once()


if __name__ == '__main__':
    unittest.main()
