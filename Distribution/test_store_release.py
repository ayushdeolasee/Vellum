"""Offline tests of the boundary between prepared bytes and Apple submission."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("store_release", Path(__file__).with_name("store-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class StoreReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        archive = self.directory / "Vellum.xcarchive"
        (archive / "dSYMs").mkdir(parents=True)
        (archive / "dSYMs" / "symbols").write_bytes(b"fixture symbols")
        (archive / "app").write_bytes(b"fixture app")
        (self.directory / "export").mkdir()
        self.package = self.directory / "export" / "Vellum.ipa"
        self.package.write_bytes(b"fixture package")
        release.write_json(self.directory / "artifact.json", {
            "schema": 1, "platform": "ios", "package": "export/Vellum.ipa",
            "package_sha256": release.sha(self.package),
            "archive_files": release.inventory(archive),
            "export_files": release.inventory(self.directory / "export")})
        self.args = argparse.Namespace(directory=self.directory, command="validate",
            username="fixture@example.invalid", password_env="VELLUM_TEST_ASC_PASSWORD", provider=None)
        self.calls = []

    def apple(self, *command, log=None):
        self.assertEqual(command[:2], ("xcrun", "altool"))
        self.assertIn(command[2], ("--validate-app", "--upload-package"))
        submitted = Path(command[3])
        self.assertNotEqual(submitted, self.package)
        self.assertEqual(submitted.read_bytes(), b"fixture package")
        self.assertEqual(command[-1], "@env:VELLUM_TEST_ASC_PASSWORD")
        self.assertNotIn("synthetic-secret", command)
        self.calls.append(command[2])
        Path(log).write_text("Synthetic successful transport result\n")
        return b""

    def test_verify_rejects_changed_package_symbols_and_added_export(self):
        release.verify(self.directory)
        for path in (self.package, self.directory / "Vellum.xcarchive/dSYMs/symbols"):
            original = path.read_bytes()
            path.write_bytes(b"changed")
            with self.assertRaises(ValueError):
                release.verify(self.directory)
            path.write_bytes(original)
        (self.directory / "export/unrecorded").write_bytes(b"extra")
        with self.assertRaises(ValueError):
            release.verify(self.directory)

    @patch.dict(os.environ, {"VELLUM_TEST_ASC_PASSWORD": "synthetic-secret"})
    def test_upload_requires_validation_of_current_manifest(self):
        self.args.command = "upload"
        with patch.object(release, "run", side_effect=self.apple):
            with self.assertRaises(ValueError):
                release.apple_action(self.args)
            self.assertEqual(self.calls, [])
            self.args.command = "validate"
            release.apple_action(self.args)
            manifest = self.directory / "artifact.json"
            manifest.write_text(manifest.read_text() + "\n")
            self.args.command = "upload"
            with self.assertRaises(ValueError):
                release.apple_action(self.args)
        self.assertEqual(self.calls, ["--validate-app"])

    @patch.dict(os.environ, {"VELLUM_TEST_ASC_PASSWORD": "synthetic-secret"})
    def test_failed_revalidation_removes_old_success_receipt(self):
        with patch.object(release, "run", side_effect=self.apple):
            release.apple_action(self.args)
        with patch.object(release, "run", side_effect=ValueError("Apple rejected fixture")):
            with self.assertRaises(ValueError):
                release.apple_action(self.args)
        self.assertFalse((self.directory / "apple-validation.json").exists())

    @patch.dict(os.environ, {"VELLUM_TEST_ASC_PASSWORD": "synthetic-secret"})
    def test_validate_and_upload_only_submit_the_recorded_package(self):
        with patch.object(release, "run", side_effect=self.apple):
            release.apple_action(self.args)
            self.args.command = "upload"
            release.apple_action(self.args)
            with self.assertRaises(ValueError):
                release.apple_action(self.args)
        self.assertEqual(self.calls, ["--validate-app", "--upload-package"])
        receipt = json.loads((self.directory / "apple-upload.json").read_text())
        self.assertEqual(receipt["package_sha256"], release.sha(self.package))


if __name__ == "__main__":
    unittest.main()
