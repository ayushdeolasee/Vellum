#!/usr/bin/env python3
"""Prepare immutable Developer ID/Sparkle or iOS App Store artifacts.

Archive is an explicit production-artifact operation. Development tests stay Debug.
External notarization, Store upload, and GitHub promotion are explicit commands.
No command changes source, provisioning capabilities, or rebuilds during promotion.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = "com.ayushdeolasee.vellum"
CLOUD = "iCloud.com.ayushdeolasee.vellum"
GROUP = "group.com.ayushdeolasee.vellum"
TEAM = "9DCG97VASG"
FEED = "https://vellum.work/updates/appcast.xml"
REPOSITORY = "ayushdeolasee/Vellum"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, log=None, combine_output=False):
    command = [str(a) for a in args]
    if log is not None:
        # Compiler/transport logs may be large; stream them to the artifact.
        with Path(log).open("wb") as output:
            result = subprocess.run(command, cwd=ROOT, stdout=output,
                                    stderr=subprocess.STDOUT, check=False)
        require(result.returncode == 0, f"{args[0]} failed ({result.returncode}). See {log}")
        return b""
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT if combine_output else subprocess.PIPE, check=False)
    require(result.returncode == 0, f"{args[0]} failed ({result.returncode}). "
            + (result.stderr or result.stdout).decode(errors="replace")[-3000:])
    return result.stdout


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(root):
    """Include paths and symlink targets as well as bytes, including dSYMs."""
    result = {}
    for path in sorted(Path(root).rglob("*")):
        key = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[key] = {"link": os.readlink(path)}
        elif path.is_file():
            result[key] = {"sha256": sha(path), "bytes": path.stat().st_size}
    require(result, f"Empty artifact directory: {root}")
    return result


def write_json(path, value):
    # Receipt becomes visible only after the complete result is recorded.
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def inspect_signature(path, direct=False, exported=False, runtime=False, deep=True):
    run("codesign", "--verify", *(["--deep"] if deep else []), "--strict", "-R=anchor apple generic", path)
    signature = run("codesign", "-d", "--verbose=4", path, combine_output=True).decode()
    teams = re.findall(r"^TeamIdentifier=(.+)$", signature, flags=re.MULTILINE)
    require(teams == [TEAM], "Signing certificate belongs to a different or unknown team")
    authorities = re.findall(r"^Authority=(.+)$", signature, flags=re.MULTILINE)
    require(authorities, "No signing certificate authority")
    if direct:
        require(authorities[0].startswith("Developer ID Application:"),
                "Direct Mac code is not signed with a Developer ID Application certificate")
        require("Timestamp=" in signature and "Timestamp=none" not in signature,
                "Developer ID signature lacks a secure timestamp")
        if runtime:
            require(re.search(r"^CodeDirectory .*flags=.*\bruntime\b", signature, re.MULTILINE),
                    "Direct Mac executable lacks Hardened Runtime")
    elif exported:
        require(authorities[0].startswith(("Apple Distribution:", "iPhone Distribution:")),
                "Export is not signed with a Store distribution certificate")
    return authorities


def inspect_nested_code(app):
    # Sparkle contains Updater.app, XPC services and standalone Mach-O helpers.
    # Verify each real code object, not just the outer deep-verification result.
    records = []
    visited = set()
    magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
             b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    for path in sorted(app.rglob("*")):
        if not path.is_file() or path.is_symlink() or path.resolve() in visited:
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in magic:
                continue
        visited.add(path.resolve())
        # MH_EXECUTE binaries need runtime; frameworks/dylibs need valid ID signatures.
        headers = run("otool", "-hv", path).decode()
        authorities = inspect_signature(path, direct=True, runtime="EXECUTE" in headers)
        architectures = run("lipo", "-archs", path).decode().split()
        require(set(architectures) == {"arm64", "x86_64"}, f"Non-universal nested code: {path}")
        entitlements_bytes = run("codesign", "-d", "--entitlements", ":-", path)
        entitlements = plistlib.loads(entitlements_bytes) if entitlements_bytes.strip() else {}
        require(not entitlements.get("get-task-allow", False)
                and not entitlements.get("com.apple.security.get-task-allow", False),
                f"Nested code permits debugging: {path}")
        records.append({"path": str(path.relative_to(app)), "architectures": architectures,
                        "signing_authorities": authorities})
    require(records, "No signed Mach-O code found in direct app")
    return records


def inspect_bundle(app, platform, version, build, exported):
    contents = app / "Contents" if platform == "macos" else app
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    identifier = info["CFBundleIdentifier"]
    require(identifier in {BUNDLE, BUNDLE + ".share", BUNDLE + ".widgets"},
            f"Unexpected bundle: {identifier}")
    require(info.get("CFBundleShortVersionString") == version
            and info.get("CFBundleVersion") == build, f"Version/build mismatch: {identifier}")
    direct = platform == "macos"
    if direct:
        require(info.get("SUFeedURL") == FEED, "Unexpected Sparkle feed URL")
        require(len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) == 32,
                "Missing or invalid Sparkle EdDSA public key")
        require(any(p.name == "Sparkle.framework" for p in app.rglob("*.framework")),
                "Sparkle framework missing from direct Mac app")
    else:
        require(not any(key.startswith("SU") for key in info), f"Updater metadata in {identifier}")
        require(not any("sparkle" in p.name.lower() for p in app.rglob("*")), "Sparkle in Store app")
    # Xcode export re-signs Sparkle helpers; intermediate archive helpers can
    # retain upstream signatures/debug entitlements. Gate all nested code after export.
    authorities = inspect_signature(app, direct=direct, exported=exported, runtime=direct,
                                    deep=not direct or exported)
    entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", app))
    require(entitlements.get("com.apple.developer.team-identifier") == TEAM, "Wrong signed team")
    app_identity = entitlements.get("application-identifier",
                                    entitlements.get("com.apple.application-identifier"))
    require(app_identity == f"{TEAM}.{identifier}", f"Wrong signed identity: {identifier}")
    if exported:
        require(not entitlements.get("get-task-allow", False)
                and not entitlements.get("com.apple.security.get-task-allow", False),
                "Export permits debugging")
    if identifier == BUNDLE:
        for key in ("com.apple.developer.icloud-container-identifiers",
                    "com.apple.developer.ubiquity-container-identifiers"):
            require(entitlements.get(key) == [CLOUD], f"Wrong {key}")
        require(entitlements.get("com.apple.developer.icloud-services") == ["CloudDocuments"],
                "Missing iCloud Documents capability")
        if exported:
            environment = entitlements.get("com.apple.developer.icloud-container-environment")
            require(environment in (None, "Production"), "Export selects a development iCloud environment")
            # CloudDocuments-only profiles can omit the CloudKit environment key.
            # Record the actual entitlement; device/container access is a separate gate.
    if platform == "ios":
        require(entitlements.get("com.apple.security.application-groups") == [GROUP],
                f"Wrong App Group: {identifier}")
    executable = contents / ("MacOS" if platform == "macos" else "") / info["CFBundleExecutable"]
    architectures = run("lipo", "-archs", executable).decode().split()
    require(set(architectures) == ({"arm64", "x86_64"} if platform == "macos" else {"arm64"}),
            f"Unexpected architectures: {architectures}")
    profile_path = contents / ("embedded.provisionprofile" if platform == "macos" else "embedded.mobileprovision")
    profile = plistlib.loads(run("security", "cms", "-D", "-i", profile_path))
    require(TEAM in profile.get("TeamIdentifier", []), "Profile belongs to a different team")
    expiry = profile.get("ExpirationDate")
    require(expiry is not None and expiry > dt.datetime.now(dt.timezone.utc).replace(tzinfo=None),
            "Provisioning profile expired")
    allowed = profile.get("Entitlements", {})
    require(allowed.get("application-identifier", allowed.get("com.apple.application-identifier"))
            == f"{TEAM}.{identifier}", "Profile does not authorize exact bundle identity")
    for key in ("com.apple.developer.icloud-container-identifiers",
                "com.apple.developer.ubiquity-container-identifiers",
                "com.apple.developer.icloud-services", "com.apple.security.application-groups"):
        require(all(value in allowed.get(key, []) for value in entitlements.get(key, [])),
                f"Profile does not authorize {key}")
    if direct:
        require(profile.get("Platform") == ["OSX"], "Developer ID profile is not for macOS")
        require(profile.get("ProvisionsAllDevices") is True and not profile.get("ProvisionedDevices"),
                "Direct Mac app lacks a Developer ID provisioning profile")
        require(not allowed.get("get-task-allow", False)
                and not allowed.get("com.apple.security.get-task-allow", False),
                "Developer ID profile permits debugging")
    elif exported:
        require(not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices"),
                "Export uses a development, ad hoc, or enterprise profile")
    manifests = []
    for path in contents.rglob("PrivacyInfo.xcprivacy"):
        plistlib.loads(path.read_bytes())
        manifests.append({"path": str(path.relative_to(app)), "sha256": sha(path)})
    if identifier == BUNDLE:
        require(manifests, "App privacy manifest missing")
    uuids = executable_uuids(executable)
    return {"bundle": identifier, "version": version, "build": build, "executable_uuids": uuids,
            "architectures": architectures, "signing_team": TEAM,
            "signing_authorities": authorities, "entitlements": entitlements,
            "profile_uuid": profile.get("UUID"), "profile_expires": expiry.isoformat(),
            "privacy_manifests": manifests,
            **({"feed_url": info["SUFeedURL"], "public_ed_key": info["SUPublicEDKey"],
                "minimum_system_version": info.get("LSMinimumSystemVersion"),
                "nested_code": inspect_nested_code(app) if exported else []} if direct else {})}


def executable_uuids(path):
    output = run("dwarfdump", "--uuid", path).decode()
    values = sorted(re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", output))
    require(values, f"No Mach-O UUIDs: {path}")
    return values


def top_level_apps(root):
    return [p for p in root.rglob("*.app")
            if not any(parent.suffix == ".app" for parent in p.relative_to(root).parents)]


def inspect_apps(root, platform, version, build, exported):
    apps = top_level_apps(root)
    require(len(apps) == 1, f"Expected one app under {root}, found {len(apps)}")
    bundles = [apps[0]] + list(apps[0].rglob("*.appex"))
    records = [inspect_bundle(p, platform, version, build, exported) for p in bundles]
    expected = {BUNDLE} if platform == "macos" else {BUNDLE, BUNDLE + ".share", BUNDLE + ".widgets"}
    require({r["bundle"] for r in records} == expected and len(records) == len(expected),
            "Missing or duplicate app/extension")
    return records


def archive(args):
    require(re.fullmatch(r"\d+\.\d+\.\d+", args.version), "Use a three-part version")
    require(re.fullmatch(r"[1-9]\d*", args.build), "Build must be a positive integer")
    require(not run("git", "status", "--porcelain").strip(), "Commit working-tree changes first")
    output = args.directory.resolve()
    require(not output.exists(), "Use a new directory; previous artifacts are never overwritten")
    output.mkdir(parents=True, mode=0o700)
    commit = run("git", "rev-parse", "HEAD").decode().strip()
    archive_path = output / "Vellum.xcarchive"
    scheme = "Vellum Mac" if args.platform == "macos" else "Vellum"
    destination = "generic/platform=" + ("macOS" if args.platform == "macos" else "iOS")
    command = ["xcodebuild", "archive", "-project", "Vellum.xcodeproj", "-scheme", scheme,
               "-configuration", "Release", "-destination", destination,
               "-archivePath", str(archive_path), "-derivedDataPath", str(output / "DerivedData"),
               f"MARKETING_VERSION={args.version}", f"CURRENT_PROJECT_VERSION={args.build}"]
    if args.platform == "macos":
        require(args.signing_identity and args.signing_identity.startswith("Developer ID Application:"),
                "Supply --signing-identity with the exact Developer ID Application certificate name")
        command += ["ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO",
                    f"CODE_SIGN_IDENTITY={args.signing_identity}", f"DEVELOPMENT_TEAM={TEAM}",
                    "ENABLE_HARDENED_RUNTIME=YES"]
    run(*command, log=output / "archive.log")
    archive_records = inspect_apps(archive_path / "Products", args.platform, args.version, args.build, False)
    symbols = list((archive_path / "dSYMs").glob("*.dSYM/Contents/Resources/DWARF/*"))
    symbol_uuids = [executable_uuids(path) for path in symbols]
    require(all(record["executable_uuids"] in symbol_uuids for record in archive_records),
            "Missing matching app/extension debug symbols")
    options = {"method": "developer-id" if args.platform == "macos" else "app-store-connect",
               "destination": "export", "teamID": TEAM,
               "signingStyle": "automatic", "manageAppVersionAndBuildNumber": False,
               "iCloudContainerEnvironment": "Production", "uploadSymbols": True}
    if args.platform == "macos":
        # Xcode's signingCertificate option only applies to manual exports.
        # Reuse the validated Developer ID profile already embedded in the archive.
        options["signingStyle"] = "manual"
        options["signingCertificate"] = args.signing_identity
        require(archive_records[0].get("profile_uuid"), "Archive has no provisioning profile UUID")
        options["provisioningProfiles"] = {BUNDLE: archive_records[0]["profile_uuid"]}
        options.pop("uploadSymbols")  # Symbols are preserved locally for direct distribution.
    options_path = output / "ExportOptions.plist"
    options_path.write_bytes(plistlib.dumps(options))
    run("xcodebuild", "-exportArchive", "-archivePath", archive_path,
        "-exportOptionsPlist", options_path, "-exportPath", output / "export",
        log=output / "export.log")
    if args.platform == "macos":
        exported_records = inspect_apps(output / "export", args.platform, args.version, args.build, True)
        app = top_level_apps(output / "export")[0]
        with tempfile.TemporaryDirectory(prefix="vellum-dmg-root-", dir=output) as temporary:
            staging = Path(temporary)
            run("ditto", app, staging / "Vellum.app")
            require(inventory(staging / "Vellum.app") == inventory(app), "DMG staging changed app bytes")
            (staging / "Applications").symlink_to("/Applications")
            (output / "pre-notary").mkdir(mode=0o700)
            package = output / "pre-notary" / f"Vellum-{args.version}-{args.build}.dmg"
            run("hdiutil", "create", "-volname", "Vellum", "-format", "UDZO", "-srcfolder", staging, package,
                log=output / "dmg.log")
        run("codesign", "--sign", args.signing_identity, "--timestamp",
            "--identifier", BUNDLE + ".dmg", package)
        inspect_signature(package, direct=True)
        run("hdiutil", "verify", package)
    else:
        packages = list((output / "export").glob("*.ipa"))
        require(len(packages) == 1, "Expected exactly one exported package")
        package = packages[0]
        with tempfile.TemporaryDirectory(prefix="vellum-store-inspect-") as temporary:
            unpacked = Path(temporary) / "package"
            with zipfile.ZipFile(package) as zipped:
                for entry in zipped.infolist():
                    require(not Path(entry.filename).is_absolute() and ".." not in Path(entry.filename).parts,
                            "Unsafe exported ZIP path")
            run("ditto", "-x", "-k", package, unpacked)
            exported_records = inspect_apps(unpacked, args.platform, args.version, args.build, True)
    require(all(record["executable_uuids"] in symbol_uuids for record in exported_records),
            "Exported app/extension does not match preserved debug symbols")
    require(run("git", "rev-parse", "HEAD").decode().strip() == commit
            and not run("git", "status", "--porcelain").strip(),
            "Source changed during archive/export; this candidate has no completed manifest")
    manifest = {"schema": 2, "created": now(), "commit": commit, "platform": args.platform,
                "channel": "developer-id-sparkle" if args.platform == "macos" else "app-store-connect",
                "version": args.version, "build": args.build, "archive_command": command,
                "xcode": run("xcodebuild", "-version").decode().strip(),
                "package": str(package.relative_to(output)), "package_sha256": sha(package),
                "archive_bundles": archive_records, "exported_bundles": exported_records,
                "archive_files": inventory(archive_path), "export_files": inventory(output / "export")}
    write_json(output / "artifact.json", manifest)
    print(f"Prepared {package}. Local signature checks passed; external Apple and device acceptance are pending.")


def verify(directory):
    directory = directory.resolve()
    manifest = json.loads((directory / "artifact.json").read_text())
    require(manifest.get("schema") in (1, 2), "Unknown artifact manifest version")
    require(manifest.get("platform") in ("ios", "macos"), "Unknown artifact platform")
    if manifest["platform"] == "macos":
        require(manifest.get("schema") == 2 and manifest.get("channel") == "developer-id-sparkle",
                "Mac App Store artifacts are not a supported release channel")
    package = directory / manifest["package"]
    require(package.resolve().is_relative_to(directory), "Package escapes artifact directory")
    require(sha(package) == manifest["package_sha256"], "Package changed after export")
    require(inventory(directory / "Vellum.xcarchive") == manifest["archive_files"], "Archive/symbols changed")
    require(inventory(directory / "export") == manifest["export_files"], "Export changed")
    return manifest, package


def apple_action(args):
    manifest, package = verify(args.directory)
    require(manifest["platform"] == "ios", "altool is only used for iOS Store artifacts; Mac uses notarization")
    manifest_digest = sha(args.directory / "artifact.json")
    receipt = args.directory / "apple-validation.json"
    if args.command == "upload":
        require(receipt.exists(), "Validate this artifact with Apple first")
        validation = json.loads(receipt.read_text())
        require(validation.get("artifact_manifest_sha256") == manifest_digest
                and validation.get("package_sha256") == manifest["package_sha256"],
                "Validation belongs to another artifact")
        require(not (args.directory / "apple-upload.json").exists(), "Upload already recorded")
    else:
        receipt.unlink(missing_ok=True)  # Failed revalidation must not retain a success receipt.
    require(os.environ.get(args.password_env), f"Set {args.password_env} to an app-specific password")
    operation = "--validate-app" if args.command == "validate" else "--upload-package"
    log = args.directory / f"apple-{args.command}.log"
    with tempfile.TemporaryDirectory(prefix="vellum-store-submit-") as temporary:
        # Submit a private snapshot: editing the original package after verify
        # cannot switch the bytes handed to Apple's process.
        submitted = Path(temporary) / package.name
        shutil.copyfile(package, submitted)
        require(sha(submitted) == manifest["package_sha256"], "Package changed while preparing submission")
        # Xcode26.6+ altool resolves this env reference; the secret is not in argv.
        command = ["xcrun", "altool", operation, str(submitted),
                   "-u", args.username, "-p", "@env:" + args.password_env]
        if args.provider:
            command += ["--provider-public-id", args.provider]
        run(*command, log=log)
        require(sha(submitted) == manifest["package_sha256"], "Submission snapshot changed")
    verify(args.directory)
    require(sha(args.directory / "artifact.json") == manifest_digest, "Manifest changed during Apple operation")
    write_json(args.directory / ("apple-validation.json" if args.command == "validate" else "apple-upload.json"),
               {"time": now(), "artifact_manifest_sha256": manifest_digest,
                "package_sha256": manifest["package_sha256"], "log_sha256": sha(log)})
    print("Apple operation succeeded for the recorded package. App Store processing/review/release is separate.")


def direct_artifact(directory):
    manifest, package = verify(directory)
    require(manifest["platform"] == "macos", "This command requires a direct Mac artifact")
    return manifest, package, sha(directory / "artifact.json")


def bound_receipt(directory, name, manifest_digest, package_digest):
    receipt = json.loads((directory / name).read_text())
    require(receipt.get("artifact_manifest_sha256") == manifest_digest
            and receipt.get("package_sha256") == package_digest, "Receipt belongs to another artifact")
    require(str(uuid.UUID(receipt["submission_id"])) == receipt["submission_id"], "Invalid submission ID")
    return receipt


def notary_action(args):
    directory = args.directory.resolve()
    manifest, package, digest = direct_artifact(directory)
    require(not (directory / "final-artifact.json").exists(), "Final artifact already recorded")
    submission_path = directory / "notary-submission.json"
    if args.command == "notary-resume":
        require(not submission_path.exists(), "Submission already recorded; use notary-wait")
        attempt = json.loads((directory / "notary-attempt.json").read_text())
        require(attempt.get("artifact_manifest_sha256") == digest
                and attempt.get("package_sha256") == manifest["package_sha256"],
                "Notary attempt belongs to another artifact")
        write_json(submission_path, {**attempt, "time": now(),
                                    "submission_id": str(uuid.UUID(args.submission_id)), "recovered": True})
        print("Submission ID recovered locally. notary-wait must verify Apple's accepted log and package hash.")
    elif args.command == "notary-submit":
        require(not submission_path.exists(), "Submission already recorded; resume with notary-wait")
        require(not (directory / "notary-attempt.json").exists(),
                "A submit attempt already started; recover its Apple ID with notary-resume instead of uploading again")
        with tempfile.TemporaryDirectory(prefix="vellum-notary-submit-") as temporary:
            snapshot = Path(temporary) / package.name
            shutil.copyfile(package, snapshot)
            require(sha(snapshot) == manifest["package_sha256"], "Package changed while preparing submission")
            write_json(directory / "notary-attempt.json", {"time": now(),
                "artifact_manifest_sha256": digest, "package_sha256": manifest["package_sha256"]})
            response = run("xcrun", "notarytool", "submit", snapshot,
                           "--keychain-profile", args.keychain_profile, "--output-format", "json")
            (directory / "notary-submit.log").write_bytes(response)
            result = json.loads(response)
            submission_id = str(uuid.UUID(result["id"]))
            require(sha(snapshot) == manifest["package_sha256"], "Notary submission snapshot changed")
            # Record the ID immediately: subsequent status queries must never resubmit.
            write_json(submission_path, {"time": now(), "submission_id": submission_id,
                "artifact_manifest_sha256": digest, "package_sha256": manifest["package_sha256"],
                "log_sha256": sha(directory / "notary-submit.log")})
        print(f"Submission {submission_id} recorded. Resume with notary-wait; no new upload is needed.")
    else:
        submission = bound_receipt(directory, "notary-submission.json", digest, manifest["package_sha256"])
        accepted = directory / "notary-accepted.json"
        accepted.unlink(missing_ok=True)
        response = run("xcrun", "notarytool", "wait", submission["submission_id"],
                       "--keychain-profile", args.keychain_profile, "--timeout", "60s", "--output-format", "json")
        (directory / "notary-wait.log").write_bytes(response)
        result = json.loads(response)
        require(str(uuid.UUID(result["id"])) == submission["submission_id"], "Notary response has another submission ID")
        log = directory / "notary-log.json"
        run("xcrun", "notarytool", "log", submission["submission_id"],
            "--keychain-profile", args.keychain_profile, log)
        details = json.loads(log.read_text())
        require(str(uuid.UUID(details["jobId"])) == submission["submission_id"]
                and details.get("sha256") == manifest["package_sha256"],
                "Apple's notarization log does not match the submitted bytes")
        require(result.get("status") == "Accepted" and details.get("status") == "Accepted",
                "Notarization was not accepted; inspect notary-log.json")
        direct_artifact(directory)
        require(sha(directory / "artifact.json") == digest, "Manifest changed during notarization")
        write_json(accepted, {**submission, "time": now(), "status": "Accepted", "log_sha256": sha(log)})
        print("Apple accepted the recorded pre-stapling DMG. Review notary-log.json, then finalize.")
    direct_artifact(directory)
    require(sha(directory / "artifact.json") == digest, "Manifest changed during notarization")


def accepted_notary(directory, digest, package_digest):
    receipt = bound_receipt(directory, "notary-accepted.json", digest, package_digest)
    require(receipt.get("status") == "Accepted"
            and receipt.get("log_sha256") == sha(directory / "notary-log.json"),
            "Accepted notarization receipt/log changed")
    return receipt


def verify_appcast(appcast, package, manifest):
    # Public verification never accesses the Sparkle private key or Keychain.
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    document = ET.fromstring(appcast.read_bytes())
    items = document.findall("./channel/item")
    require(len(items) == 1, "Expected one final appcast item")
    item = items[0]
    enclosures = item.findall("enclosure")
    require(len(enclosures) == 1, "Expected one full update enclosure")
    enclosure = enclosures[0]
    tag = "v" + manifest["version"]
    expected_url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{package.name}"
    require(enclosure.get("url") == expected_url, "Appcast enclosure is not version-specific")
    require(enclosure.get("length") == str(package.stat().st_size), "Appcast length does not match DMG")
    for key, value in (("version", manifest["build"]), ("shortVersionString", manifest["version"])):
        require(item.findtext(f"{{{SPARKLE}}}{key}", enclosure.get(f"{{{SPARKLE}}}{key}")) == value,
                f"Appcast {key} does not match app")
    public_key = manifest["exported_bundles"][0]["public_ed_key"]
    signature = base64.b64decode(enclosure.get(f"{{{SPARKLE}}}edSignature", ""), validate=True)
    require(len(signature) == 64, "Appcast enclosure lacks a valid EdDSA signature")
    try:
        Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key, validate=True)).verify(signature, package.read_bytes())
    except InvalidSignature as error:
        raise ValueError("Appcast signature does not match the app's public key and final DMG") from error
    return expected_url


def finalize(args):
    directory = args.directory.resolve()
    manifest, package, digest = direct_artifact(directory)
    receipt = accepted_notary(directory, digest, manifest["package_sha256"])
    receipt_digest = sha(directory / "notary-accepted.json")
    require(not (directory / "updates").exists() and not (directory / "final-artifact.json").exists(),
            "Final artifacts already exist; never replace a finalized candidate")
    if args.sparkle_tool:
        tool = args.sparkle_tool.resolve()
    else:
        tools = list((directory / "DerivedData/SourcePackages/artifacts").rglob("generate_appcast"))
        require(len(tools) == 1, "Supply --sparkle-tool with Sparkle's generate_appcast path")
        tool = tools[0]
    require(tool.is_file() and os.access(tool, os.X_OK), "Sparkle generate_appcast is missing or not executable")
    tool_digest = sha(tool)
    with tempfile.TemporaryDirectory(prefix="vellum-finalize-", dir=directory) as temporary:
        updates = Path(temporary) / "updates"
        updates.mkdir(mode=0o700)
        final_package = updates / package.name
        shutil.copyfile(package, final_package)
        require(sha(final_package) == manifest["package_sha256"], "Pre-notary DMG changed while preparing finalization")
        run("xcrun", "stapler", "staple", final_package, log=directory / "staple.log")
        run("xcrun", "stapler", "validate", final_package)
        inspect_signature(final_package, direct=True)
        run("hdiutil", "verify", final_package)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", final_package)
        stapled_digest = sha(final_package)
        run(tool, "--account", args.sparkle_account, "--download-url-prefix",
            f"https://github.com/{REPOSITORY}/releases/download/v{manifest['version']}/",
            "--link", "https://vellum.work/", "--maximum-versions", "1", "--maximum-deltas", "0", updates,
            log=directory / "appcast.log")
        require(sha(tool) == tool_digest, "Sparkle tool changed during finalization")
        require(sha(final_package) == stapled_digest, "Sparkle generation mutated the stapled DMG")
        enclosure_url = verify_appcast(updates / "appcast.xml", final_package, manifest)
        require({p.name for p in updates.iterdir()} == {package.name, "appcast.xml"}, "Unexpected update files")
        # Existing download route uses this alias. Sparkle uses the immutable URL.
        shutil.copyfile(final_package, updates / "Vellum.dmg")
        direct_artifact(directory)
        require(sha(directory / "artifact.json") == digest
                and sha(directory / "notary-accepted.json") == receipt_digest, "Evidence changed during finalization")
        final_manifest = {"schema": 1, "created": now(), "artifact_manifest_sha256": digest,
            "notary_receipt_sha256": receipt_digest, "submission_id": receipt["submission_id"],
            "pre_notary_package_sha256": manifest["package_sha256"],
            "package": "updates/" + package.name, "package_sha256": stapled_digest,
            "feed_url": FEED, "enclosure_url": enclosure_url, "sparkle_tool_sha256": tool_digest,
            "update_files": inventory(updates)}
        updates.rename(directory / "updates")
        write_json(directory / "final-artifact.json", final_manifest)
    verify_final(directory)
    print("Final stapled DMG, download alias and signed appcast recorded. No publication has occurred.")


def verify_final(directory):
    directory = directory.resolve()
    manifest, _, digest = direct_artifact(directory)
    accepted_notary(directory, digest, manifest["package_sha256"])
    final = json.loads((directory / "final-artifact.json").read_text())
    require(final.get("schema") == 1 and final.get("artifact_manifest_sha256") == digest
            and final.get("notary_receipt_sha256") == sha(directory / "notary-accepted.json"),
            "Final manifest belongs to different preparation/notarization evidence")
    package = directory / final["package"]
    require(package.resolve().is_relative_to(directory / "updates"), "Final package escapes updates directory")
    require(final.get("pre_notary_package_sha256") == manifest["package_sha256"]
            and sha(package) == final["package_sha256"], "Final DMG changed")
    require(inventory(directory / "updates") == final["update_files"], "Final update assets changed")
    require(sha(directory / "updates/Vellum.dmg") == final["package_sha256"], "Download alias differs from final DMG")
    require(verify_appcast(directory / "updates/appcast.xml", package, manifest) == final["enclosure_url"]
            and final.get("feed_url") == FEED, "Final update URLs changed")
    return manifest, final, package


def promote(args):
    directory = args.directory.resolve()
    manifest, final, package = verify_final(directory)
    digest = sha(directory / "final-artifact.json")
    require(not (directory / "github-promotion.json").exists(), "Promotion already recorded")
    tag = "v" + manifest["version"]
    # Require a deliberately published tag and resolve annotated tags to commits.
    # --verify-tag prevents gh from creating a different tag as a side effect.
    def verify_tag():
        references = run("git", "ls-remote", f"https://github.com/{REPOSITORY}.git",
                         "refs/tags/" + tag, "refs/tags/" + tag + "^{}").decode().splitlines()
        values = dict(line.split()[::-1] for line in references)
        actual = values.get("refs/tags/" + tag + "^{}", values.get("refs/tags/" + tag))
        require(actual == manifest["commit"], "Publish a release tag pointing to the recorded source commit first")
    verify_tag()
    with tempfile.TemporaryDirectory(prefix="vellum-promote-") as temporary:
        snapshot = Path(temporary)
        assets = []
        for name in (package.name, "Vellum.dmg", "appcast.xml"):
            asset = snapshot / name
            shutil.copyfile(directory / "updates" / name, asset)
            require(sha(asset) == final["update_files"][name]["sha256"], "Asset changed while preparing promotion")
            assets.append(asset)
        # gh can only create an absent release; never upload with --clobber.
        run("gh", "release", "create", tag, *assets,
            "--repo", REPOSITORY, "--verify-tag", "--draft",
            "--title", "Vellum " + manifest["version"], "--notes", args.notes,
            log=directory / "github-stage.log")
        require(all(sha(asset) == final["update_files"][asset.name]["sha256"] for asset in assets),
                "Promotion snapshot changed")
    verify_tag()
    verify_final(directory)
    require(sha(directory / "final-artifact.json") == digest, "Final manifest changed during promotion")
    # Keep the release unpublished until every final provenance/byte check passes.
    run("gh", "release", "edit", tag, "--repo", REPOSITORY, "--draft=false", "--latest",
        log=directory / "github-promote.log")
    write_json(directory / "github-promotion.json", {"time": now(), "final_manifest_sha256": digest,
        "package_sha256": final["package_sha256"], "stage_log_sha256": sha(directory / "github-stage.log"),
        "log_sha256": sha(directory / "github-promote.log")})
    print("GitHub promotion recorded. Check the stable feed and download routes before release sign-off.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("archive", help="Create a new production artifact locally; no upload/notarization")
    prepare.add_argument("--platform", choices=("macos", "ios"), required=True)
    prepare.add_argument("--version", required=True)
    prepare.add_argument("--build", required=True)
    prepare.add_argument("--signing-identity", help="Required for Mac: exact Developer ID Application certificate name")
    prepare.add_argument("directory", type=Path)
    check = commands.add_parser("verify", help="Recheck recorded archive, symbols and package digests")
    check.add_argument("directory", type=Path)
    for name in ("notary-submit", "notary-wait"):
        action = commands.add_parser(name, help="Explicit Apple notarization action; never rebuild")
        action.add_argument("directory", type=Path)
        action.add_argument("--keychain-profile", default="VellumNotary")
    resume = commands.add_parser("notary-resume", help="Recover a lost notary submission ID locally; no upload")
    resume.add_argument("directory", type=Path)
    resume.add_argument("--submission-id", required=True)
    finish = commands.add_parser("finalize", help="Explicit ticket download/stapling and local Sparkle signing")
    finish.add_argument("directory", type=Path)
    finish.add_argument("--sparkle-tool", type=Path)
    finish.add_argument("--sparkle-account", default="Vellum")
    publish = commands.add_parser("promote", help="Publish existing verified Mac assets to GitHub; never rebuild")
    publish.add_argument("directory", type=Path)
    publish.add_argument("--notes", required=True, help="Release notes text")
    for name in ("validate", "upload"):
        action = commands.add_parser(name, help=f"Explicitly {name} the existing package with Apple; never rebuild")
        action.add_argument("directory", type=Path)
        action.add_argument("--username", required=True)
        action.add_argument("--password-env", default="VELLUM_ASC_PASSWORD")
        action.add_argument("--provider")
    args = parser.parse_args()
    if args.command == "archive":
        archive(args)
    elif args.command == "verify":
        verify(args.directory)
        if (args.directory / "final-artifact.json").exists():
            verify_final(args.directory)
        print("Recorded artifact, export, symbols and any final update assets verified.")
    elif args.command in ("notary-submit", "notary-wait", "notary-resume"):
        notary_action(args)
    elif args.command == "finalize":
        finalize(args)
    elif args.command == "promote":
        promote(args)
    else:
        apple_action(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, ImportError, ET.ParseError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        sys.exit(1)
