"""Offline tests of the boundary between prepared bytes and Apple submission."""
import argparse
import base64
import datetime as dt
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile
from unittest.mock import patch
import xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

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

    def test_bundle_rejects_another_certificate_team_before_trusting_entitlements(self):
        app = self.directory / "OtherTeam.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": release.BUNDLE,
            "CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "5"}))
        for team in ("TeamIdentifier=OTHERTEAM\n", ""):
            with self.subTest(team=team):
                signature = ("Authority=Apple Distribution: Fixture\n" + team).encode()
                with patch.object(release, "run", side_effect=[b"", signature]) as tool:
                    with self.assertRaisesRegex(ValueError, "Signing certificate"):
                        release.inspect_bundle(app, "ios", "0.1.2", "5", True)
                    self.assertEqual(tool.call_count, 2)

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

    def test_source_changes_during_packaging_cannot_finish_a_manifest(self):
        for mutation in ("commit", "dirty"):
            with self.subTest(mutation=mutation):
                directory = self.directory / mutation
                exported = False
                args = argparse.Namespace(directory=directory, platform="ios", version="0.1.2", build="5")

                def tool(*command, log=None):
                    nonlocal exported
                    if command[:3] == ("git", "rev-parse", "HEAD"):
                        return b"new-commit" if exported and mutation == "commit" else b"original-commit"
                    if command[:3] == ("git", "status", "--porcelain"):
                        return b" M source.swift" if exported and mutation == "dirty" else b""
                    if command[:2] == ("xcodebuild", "archive"):
                        symbol = directory / "Vellum.xcarchive/dSYMs/Vellum.app.dSYM/Contents/Resources/DWARF/Vellum"
                        symbol.parent.mkdir(parents=True)
                        symbol.write_bytes(b"symbols")
                    elif command[:2] == ("xcodebuild", "-exportArchive"):
                        (directory / "export").mkdir()
                        with zipfile.ZipFile(directory / "export/Vellum.ipa", "w") as package:
                            package.writestr("Payload/Vellum.app/fixture", "fixture")
                        exported = True
                    return b""

                records = [{"executable_uuids": [("FIXTURE", "arm64")]}]
                with patch.object(release, "run", side_effect=tool), \
                     patch.object(release, "inspect_apps", return_value=records), \
                     patch.object(release, "executable_uuids", return_value=records[0]["executable_uuids"]):
                    with self.assertRaisesRegex(ValueError, "Source changed"):
                        release.archive(args)
                self.assertFalse((directory / "artifact.json").exists())

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


class DirectReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.key = Ed25519PrivateKey.from_private_bytes(bytes(range(32)))
        self.public_key = base64.b64encode(self.key.public_key().public_bytes_raw()).decode()
        archive = self.directory / "Vellum.xcarchive"
        archive.mkdir()
        (archive / "symbols").write_bytes(b"synthetic symbols")
        exported = self.directory / "export"
        exported.mkdir()
        (exported / "app").write_bytes(b"synthetic app")
        (self.directory / "pre-notary").mkdir()
        self.package = self.directory / "pre-notary/Vellum-0.1.2-5.dmg"
        self.package.write_bytes(b"synthetic DMG")
        self.manifest = {"schema": 2, "channel": "developer-id-sparkle", "platform": "macos",
            "commit": "a" * 40, "version": "0.1.2", "build": "5",
            "package": "pre-notary/" + self.package.name, "package_sha256": release.sha(self.package),
            "archive_files": release.inventory(archive), "export_files": release.inventory(exported),
            "exported_bundles": [{"public_ed_key": self.public_key}]}
        release.write_json(self.directory / "artifact.json", self.manifest)
        self.submission_id = "12345678-1234-1234-1234-123456789abc"
        self.tool = self.directory / "generate_appcast"
        self.tool.write_bytes(b"synthetic tool")
        self.tool.chmod(0o700)
        self.args = argparse.Namespace(directory=self.directory, command="notary-submit",
            keychain_profile="SyntheticProfile", sparkle_tool=self.tool, sparkle_account="SyntheticAccount",
            notes="Synthetic release")
        self.calls = []

    def appcast(self, updates):
        package = updates / self.package.name
        namespace = "{" + release.SPARKLE + "}"
        root = ET.Element("rss", version="2.0")
        item = ET.SubElement(ET.SubElement(root, "channel"), "item")
        ET.SubElement(item, namespace + "version").text = "5"
        ET.SubElement(item, namespace + "shortVersionString").text = "0.1.2"
        ET.SubElement(item, "enclosure", {
            "url": f"https://github.com/{release.REPOSITORY}/releases/download/v0.1.2/{package.name}",
            "length": str(package.stat().st_size), namespace + "edSignature":
                base64.b64encode(self.key.sign(package.read_bytes())).decode()})
        ET.ElementTree(root).write(updates / "appcast.xml", encoding="utf-8", xml_declaration=True)

    def external_tool(self, *command, log=None, combine_output=False):
        self.calls.append(command)
        if log:
            Path(log).write_text("Synthetic tool log\n")
        if command[:3] == ("xcrun", "notarytool", "submit"):
            submitted = Path(command[3])
            self.assertNotEqual(submitted, self.package)
            self.assertEqual(submitted.read_bytes(), b"synthetic DMG")
            return json.dumps({"id": self.submission_id}).encode()
        if command[:3] == ("xcrun", "notarytool", "wait"):
            return json.dumps({"id": self.submission_id, "status": "Accepted"}).encode()
        if command[:3] == ("xcrun", "notarytool", "log"):
            release.write_json(Path(command[-1]), {"jobId": self.submission_id, "status": "Accepted",
                "sha256": self.manifest["package_sha256"], "issues": []})
        if command[:3] == ("xcrun", "stapler", "staple"):
            path = Path(command[3])
            self.assertNotEqual(path, self.package)
            path.write_bytes(path.read_bytes() + b" synthetic ticket")
        if Path(command[0]).name == "generate_appcast":
            self.appcast(Path(command[-1]))
        if command[:2] == ("codesign", "-d"):
            return (f"TeamIdentifier={release.TEAM}\nAuthority=Developer ID Application: Fixture\n"
                    "Timestamp=synthetic\nCodeDirectory v=20500 flags=0x10000(runtime)\n").encode()
        if command[:2] == ("git", "ls-remote"):
            return f"{self.manifest['commit']}\trefs/tags/v0.1.2\n".encode()
        if command[:3] == ("gh", "release", "create"):
            for name in (self.package.name, "Vellum.dmg", "appcast.xml"):
                submitted = next(Path(arg) for arg in command if str(arg).endswith("/" + name))
                self.assertNotEqual(submitted.parent, self.directory / "updates")
                self.assertEqual(submitted.read_bytes(), (self.directory / "updates" / name).read_bytes())
        return b""

    def prepare_final(self):
        with patch.object(release, "run", side_effect=self.external_tool):
            release.notary_action(self.args)
            self.args.command = "notary-wait"
            release.notary_action(self.args)
            release.finalize(self.args)

    def test_signature_requires_channel_team_timestamp_and_runtime(self):
        valid = (f"TeamIdentifier={release.TEAM}\nAuthority=Developer ID Application: Fixture\n"
                 "Timestamp=synthetic\nCodeDirectory v=20500 flags=0x10000(runtime)\n")
        for signature in (valid.replace("Developer ID Application", "Apple Distribution"),
                          valid.replace("Timestamp=synthetic\n", ""),
                          valid.replace("(runtime)", ""), valid.replace(release.TEAM, "OTHERTEAM")):
            with self.subTest(signature=signature), patch.object(release, "run", side_effect=[b"", signature.encode()]):
                with self.assertRaises(ValueError):
                    release.inspect_signature(self.package, direct=True, runtime=True)
        with patch.object(release, "run", side_effect=[b"", valid.encode()]):
            release.inspect_signature(self.package, direct=True, runtime=True)

    def test_archive_uses_direct_scheme_and_explicit_manual_developer_id_export(self):
        directory = self.directory / "new-candidate"
        args = argparse.Namespace(directory=directory, platform="macos", version="0.1.2", build="5",
                                  signing_identity="Developer ID Application: Fixture")
        uuids = [("FIXTURE", "arm64"), ("OTHER-FIXTURE", "x86_64")]
        records = [{"bundle": release.BUNDLE, "executable_uuids": uuids, "profile_uuid": self.submission_id}]
        commands = []
        def tool(*command, log=None):
            commands.append(command)
            if command[:3] == ("git", "rev-parse", "HEAD"):
                return self.manifest["commit"].encode()
            if command[:2] == ("xcodebuild", "archive"):
                app = directory / "Vellum.xcarchive/Products/Applications/Vellum.app"
                app.mkdir(parents=True)
                (app / "fixture").write_bytes(b"synthetic app")
                symbols = directory / "Vellum.xcarchive/dSYMs/Vellum.app.dSYM/Contents/Resources/DWARF/Vellum"
                symbols.parent.mkdir(parents=True)
                symbols.write_bytes(b"synthetic symbols")
            if command[:2] == ("xcodebuild", "-exportArchive"):
                shutil.copytree(directory / "Vellum.xcarchive/Products/Applications", directory / "export")
            if command[0] == "ditto":
                shutil.copytree(command[1], command[2])
            if command[:2] == ("hdiutil", "create"):
                Path(command[-1]).write_bytes(b"synthetic DMG")
            return b""
        with patch.object(release, "run", side_effect=tool), \
             patch.object(release, "inspect_apps", return_value=records), \
             patch.object(release, "executable_uuids", return_value=uuids), \
             patch.object(release, "inspect_signature"):
            release.archive(args)
        options = plistlib.loads((directory / "ExportOptions.plist").read_bytes())
        self.assertEqual(options["method"], "developer-id")
        self.assertEqual(options["signingStyle"], "manual")
        self.assertEqual(options["provisioningProfiles"], {release.BUNDLE: self.submission_id})
        self.assertEqual(options["signingCertificate"], args.signing_identity)
        archive_command = next(c for c in commands if c[:2] == ("xcodebuild", "archive"))
        self.assertIn("Vellum Mac", archive_command)
        self.assertIn("ARCHS=arm64 x86_64", archive_command)
        self.assertFalse(any("-allowProvisioningUpdates" in c or "notarytool" in c or "altool" in c for c in commands))
        release.verify(directory)

    def test_outer_app_selection_preserves_sparkle_updater(self):
        app = self.directory / "Payload/Vellum.app"
        (app / "Contents/Frameworks/Sparkle.framework/Updater.app").mkdir(parents=True)
        with patch.object(release, "inspect_bundle", return_value={"bundle": release.BUNDLE}) as inspect:
            release.inspect_apps(self.directory / "Payload", "macos", "0.1.2", "5", True)
            self.assertEqual(inspect.call_args.args[0], app)
            self.assertEqual(inspect.call_count, 1)
        (self.directory / "Payload/Other.app").mkdir()
        with self.assertRaises(ValueError):
            release.inspect_apps(self.directory / "Payload", "macos", "0.1.2", "5", True)

    def test_nested_code_rejects_other_team(self):
        app = self.directory / "Vellum.app"
        binary = app / "Contents/Frameworks/Sparkle.framework/Updater.app/Contents/MacOS/Updater"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"\xcf\xfa\xed\xfe" + b"synthetic code")
        with patch.object(release, "run", side_effect=[b"EXECUTE", b"", b"TeamIdentifier=OTHERTEAM\n"]):
            with self.assertRaisesRegex(ValueError, "Signing certificate"):
                release.inspect_nested_code(app)

    def test_direct_profile_must_authorize_cloud_and_developer_id_distribution(self):
        app = self.directory / "Vellum.app"
        contents = app / "Contents"
        (contents / "Frameworks/Sparkle.framework").mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": release.BUNDLE,
            "CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "5", "CFBundleExecutable": "Vellum",
            "SUFeedURL": release.FEED, "SUPublicEDKey": self.public_key}))
        (contents / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({}))
        entitlements = {"com.apple.developer.team-identifier": release.TEAM,
            "com.apple.application-identifier": release.TEAM + "." + release.BUNDLE,
            "com.apple.developer.icloud-container-identifiers": [release.CLOUD],
            "com.apple.developer.ubiquity-container-identifiers": [release.CLOUD],
            "com.apple.developer.icloud-services": ["CloudDocuments"]}
        profile = {"TeamIdentifier": [release.TEAM], "Platform": ["OSX"], "ProvisionsAllDevices": True,
            "ExpirationDate": dt.datetime.now() + dt.timedelta(days=10), "Entitlements": entitlements}
        def inspect_tool(*command):
            if command[0] == "security":
                return plistlib.dumps(profile)
            if command[0] == "lipo":
                return b"arm64 x86_64"
            return plistlib.dumps(entitlements)
        with patch.object(release, "run", side_effect=inspect_tool), \
             patch.object(release, "inspect_signature", return_value=["Developer ID Application: Fixture"]), \
             patch.object(release, "inspect_nested_code", return_value=[]), \
             patch.object(release, "executable_uuids", return_value=[("FIXTURE", "arm64")]):
            release.inspect_bundle(app, "macos", "0.1.2", "5", True)
            profile["ProvisionsAllDevices"] = False
            with self.assertRaisesRegex(ValueError, "Developer ID provisioning"):
                release.inspect_bundle(app, "macos", "0.1.2", "5", True)
            profile["ProvisionsAllDevices"] = True
            profile["Entitlements"] = {**entitlements, "com.apple.developer.icloud-container-identifiers": []}
            with self.assertRaisesRegex(ValueError, "authorize"):
                release.inspect_bundle(app, "macos", "0.1.2", "5", True)

    def test_notarization_resumes_id_without_resubmitting_and_binds_apple_hash(self):
        with patch.object(release, "run", side_effect=self.external_tool):
            release.notary_action(self.args)
        self.args.command = "notary-wait"
        with patch.object(release, "run", side_effect=ValueError("synthetic timeout")):
            with self.assertRaises(ValueError):
                release.notary_action(self.args)
        self.assertTrue((self.directory / "notary-submission.json").exists())
        self.assertFalse((self.directory / "notary-accepted.json").exists())
        with patch.object(release, "run", side_effect=self.external_tool):
            release.notary_action(self.args)
        self.assertEqual(sum(c[:3] == ("xcrun", "notarytool", "submit") for c in self.calls), 1)
        self.manifest["package_sha256"] = "wrong Apple hash"
        with patch.object(release, "run", side_effect=self.external_tool):
            with self.assertRaisesRegex(ValueError, "submitted bytes"):
                release.notary_action(self.args)
        self.assertFalse((self.directory / "notary-accepted.json").exists())

    def test_stapled_bytes_have_separate_manifest_and_detect_mutation(self):
        self.prepare_final()
        manifest, final, package = release.verify_final(self.directory)
        self.assertNotEqual(final["package_sha256"], manifest["package_sha256"])
        self.assertEqual(self.package.read_bytes(), b"synthetic DMG")
        for path in (package, self.directory / "updates/appcast.xml", self.directory / "updates/Vellum.dmg",
                     self.directory / "notary-log.json"):
            original = path.read_bytes()
            path.write_bytes(b"mutated")
            with self.assertRaises((ValueError, json.JSONDecodeError, ET.ParseError)):
                release.verify_final(self.directory)
            path.write_bytes(original)

    def test_interrupted_submit_requires_id_recovery_before_retry(self):
        with patch.object(release, "run", side_effect=ValueError("synthetic network interruption")):
            with self.assertRaises(ValueError):
                release.notary_action(self.args)
        with patch.object(release, "run") as tool:
            with self.assertRaisesRegex(ValueError, "recover"):
                release.notary_action(self.args)
            tool.assert_not_called()
            self.args.command = "notary-resume"
            self.args.submission_id = self.submission_id
            release.notary_action(self.args)
        self.args.command = "notary-wait"
        with patch.object(release, "run", side_effect=self.external_tool):
            release.notary_action(self.args)
        self.assertFalse(any(c[:3] == ("xcrun", "notarytool", "submit") for c in self.calls))

    def test_public_signature_and_version_url_checked_without_credentials(self):
        self.prepare_final()
        updates = self.directory / "updates"
        appcast = updates / "appcast.xml"
        document = ET.parse(appcast)
        enclosure = document.find("./channel/item/enclosure")
        signature = enclosure.get("{" + release.SPARKLE + "}edSignature")
        enclosure.set("{" + release.SPARKLE + "}edSignature", base64.b64encode(bytes(64)).decode())
        document.write(appcast)
        with self.assertRaisesRegex(ValueError, "public key"):
            release.verify_appcast(appcast, updates / self.package.name, self.manifest)
        enclosure.set("{" + release.SPARKLE + "}edSignature", signature)
        enclosure.set("url", f"https://github.com/{release.REPOSITORY}/releases/latest/download/Vellum.dmg")
        document.write(appcast)
        with self.assertRaisesRegex(ValueError, "version-specific"):
            release.verify_appcast(appcast, updates / self.package.name, self.manifest)

    def test_promotion_only_sends_private_verified_assets_and_never_rebuilds(self):
        self.prepare_final()
        self.calls.clear()
        with patch.object(release, "run", side_effect=self.external_tool):
            release.promote(self.args)
            with self.assertRaisesRegex(ValueError, "already recorded"):
                release.promote(self.args)
        self.assertEqual([str(c[0]) for c in self.calls], ["git", "gh", "git"])
        self.assertTrue((self.directory / "github-promotion.json").exists())

    def test_original_mutation_during_promotion_cannot_swap_snapshot_or_record_success(self):
        self.prepare_final()
        def tool(*command, **kwargs):
            result = self.external_tool(*command, **kwargs)
            if command[:3] == ("gh", "release", "create"):
                (self.directory / "updates/Vellum.dmg").write_bytes(b"changed original")
            return result
        with patch.object(release, "run", side_effect=tool):
            with self.assertRaisesRegex(ValueError, "assets changed"):
                release.promote(self.args)
        self.assertFalse((self.directory / "github-promotion.json").exists())

    def test_altool_rejects_mac_channel_before_credentials_or_transport(self):
        self.args.command = "validate"
        with patch.object(release, "run") as tool:
            with self.assertRaisesRegex(ValueError, "only used for iOS"):
                release.apple_action(self.args)
            tool.assert_not_called()


if __name__ == "__main__":
    unittest.main()
