"""Validate the single-entry public archive without downloading or running binaries."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import build_release


class ManagerReleaseTests(unittest.TestCase):
    def test_only_one_visible_launcher_and_private_runtime_folder(self):
        tag = "bundle-20261116-01234567890123456789"
        label = dict(tag="v1", source_url="https://example.invalid/fixture", sha256="0" * 64)
        lock = {key: dict(label) for key in ("optiscaler", "mochizuki", "mfgunlocker", "optipatcher", "openrr", "anr")}
        lock.update(schema_version=3, installer_edition=1, release_tag=tag)
        with tempfile.TemporaryDirectory() as work, redirect_stdout(io.StringIO()):
            out = Path(work)
            build_release.package(lock, out)
            bundle = next(out.glob("OptiScaler-Manager-*.zip"))
            with zipfile.ZipFile(bundle) as archive:
                files = set(archive.namelist())
                self.assertEqual({name for name in files if "/" not in name}, {"OptiScaler Manager.cmd"})
                self.assertFalse(any(name.lower().endswith(".cmd") and "/" in name for name in files))
                for name in ("app/Manager.ps1", "app/ManagerStore.ps1", "app/ManagerEngine.ps1", "app/installer/GameUpdate.ps1"):
                    self.assertIn(name, files)
                self.assertEqual(archive.read("app/versions.lock.json"), (out / "versions.lock.json").read_bytes())
                self.assertEqual(json.loads(archive.read("app/versions.lock.json"))["release_tag"], tag)
                self.assertFalse(any(name.lower().endswith((".dll", ".bin", ".exe")) for name in files))
            self.assertIn(hashlib.sha256(bundle.read_bytes()).hexdigest(), (out / "SHA256SUMS.txt").read_text())
