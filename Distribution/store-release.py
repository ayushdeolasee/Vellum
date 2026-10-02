#!/usr/bin/env python3
"""Build once, inspect, validate, then upload the same App Store package.

Archive is an explicit production-artifact operation. Development tests stay Debug.
No command commits, pushes, modifies portal capabilities, or releases an app.
"""
import argparse
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
import zipfile

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = "com.ayushdeolasee.vellum"
CLOUD = "iCloud.com.ayushdeolasee.vellum"
GROUP = "group.com.ayushdeolasee.vellum"
TEAM = "9DCG97VASG"


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


def inspect_bundle(app, platform, version, build, exported):
    contents = app / "Contents" if platform == "macos" else app
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    identifier = info["CFBundleIdentifier"]
    require(identifier in {BUNDLE, BUNDLE + ".share", BUNDLE + ".widgets"},
            f"Unexpected bundle: {identifier}")
    require(info.get("CFBundleShortVersionString") == version
            and info.get("CFBundleVersion") == build, f"Version/build mismatch: {identifier}")
    require(not any(key.startswith("SU") for key in info), f"Updater metadata in {identifier}")
    require(not any("sparkle" in p.name.lower() for p in app.rglob("*")), "Sparkle in Store app")
    run("codesign", "--verify", "--deep", "--strict", "-R=anchor apple generic", app)
    signature = run("codesign", "-d", "--verbose=4", app, combine_output=True).decode()
    authorities = re.findall(r"^Authority=(.+)$", signature, flags=re.MULTILINE)
    require(authorities, "No signing certificate authority")
    if exported:
        allowed_leaf = ("Apple Distribution:", "3rd Party Mac Developer Application:") if platform == "macos" else ("Apple Distribution:", "iPhone Distribution:")
        require(authorities[0].startswith(allowed_leaf), "Export is not signed with a Store distribution certificate")
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
    else:
        require(entitlements.get("com.apple.security.app-sandbox") is True, "Store app is not sandboxed")
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
    if exported:
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
            "architectures": architectures, "signing_authorities": authorities, "entitlements": entitlements,
            "profile_uuid": profile.get("UUID"), "profile_expires": expiry.isoformat(),
            "privacy_manifests": manifests}


def executable_uuids(path):
    output = run("dwarfdump", "--uuid", path).decode()
    values = sorted(re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", output))
    require(values, f"No Mach-O UUIDs: {path}")
    return values


def inspect_apps(root, platform, version, build, exported):
    apps = list(root.rglob("*.app"))
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
    scheme = "Vellum Mac App Store" if args.platform == "macos" else "Vellum"
    destination = "generic/platform=" + ("macOS" if args.platform == "macos" else "iOS")
    command = ["xcodebuild", "archive", "-project", "Vellum.xcodeproj", "-scheme", scheme,
               "-configuration", "Release", "-destination", destination,
               "-archivePath", str(archive_path), "-derivedDataPath", str(output / "DerivedData"),
               f"MARKETING_VERSION={args.version}", f"CURRENT_PROJECT_VERSION={args.build}"]
    if args.platform == "macos":
        command += ["ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO"]
    run(*command, log=output / "archive.log")
    archive_records = inspect_apps(archive_path / "Products", args.platform, args.version, args.build, False)
    symbols = list((archive_path / "dSYMs").glob("*.dSYM/Contents/Resources/DWARF/*"))
    symbol_uuids = [executable_uuids(path) for path in symbols]
    require(all(record["executable_uuids"] in symbol_uuids for record in archive_records),
            "Missing matching app/extension debug symbols")
    options = {"method": "app-store-connect", "destination": "export", "teamID": TEAM,
               "signingStyle": "automatic", "manageAppVersionAndBuildNumber": False,
               "iCloudContainerEnvironment": "Production", "uploadSymbols": True}
    options_path = output / "ExportOptions.plist"
    options_path.write_bytes(plistlib.dumps(options))
    run("xcodebuild", "-exportArchive", "-archivePath", archive_path,
        "-exportOptionsPlist", options_path, "-exportPath", output / "export",
        log=output / "export.log")
    packages = list((output / "export").glob("*.pkg" if args.platform == "macos" else "*.ipa"))
    require(len(packages) == 1, "Expected exactly one exported package")
    package = packages[0]
    with tempfile.TemporaryDirectory(prefix="vellum-store-inspect-") as temporary:
        unpacked = Path(temporary) / "package"
        if args.platform == "macos":
            run("pkgutil", "--check-signature", package, log=output / "package-signature.log")
            run("pkgutil", "--expand-full", package, unpacked)
        else:
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
    manifest = {"schema": 1, "created": now(), "commit": commit, "platform": args.platform,
                "version": args.version, "build": args.build, "archive_command": command,
                "xcode": run("xcodebuild", "-version").decode().strip(),
                "package": str(package.relative_to(output)), "package_sha256": sha(package),
                "archive_bundles": archive_records, "exported_bundles": exported_records,
                "archive_files": inventory(archive_path), "export_files": inventory(output / "export")}
    write_json(output / "artifact.json", manifest)
    print(f"Prepared {package}. Local signature checks passed; Apple validation and device acceptance are pending.")


def verify(directory):
    directory = directory.resolve()
    manifest = json.loads((directory / "artifact.json").read_text())
    require(manifest.get("schema") == 1, "Unknown artifact manifest version")
    package = directory / manifest["package"]
    require(package.resolve().is_relative_to(directory), "Package escapes artifact directory")
    require(sha(package) == manifest["package_sha256"], "Package changed after export")
    require(inventory(directory / "Vellum.xcarchive") == manifest["archive_files"], "Archive/symbols changed")
    require(inventory(directory / "export") == manifest["export_files"], "Export changed")
    return manifest, package


def apple_action(args):
    manifest, package = verify(args.directory)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("archive", help="Create and inspect a new production Store artifact; no upload")
    prepare.add_argument("--platform", choices=("macos", "ios"), required=True)
    prepare.add_argument("--version", required=True)
    prepare.add_argument("--build", required=True)
    prepare.add_argument("directory", type=Path)
    check = commands.add_parser("verify", help="Recheck recorded archive, symbols and package digests")
    check.add_argument("directory", type=Path)
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
        print("Artifact, export and symbols match their recorded digests.")
    else:
        apple_action(args)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        print(f"Release stopped: {error}", file=sys.stderr)
        sys.exit(1)
