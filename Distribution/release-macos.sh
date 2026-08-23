#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
publish=false

if [[ "${1:-}" == "--publish" ]]; then
  publish=true
elif [[ -n "${1:-}" ]]; then
  print -u2 "Usage: Distribution/release-macos.sh [--publish]"
  exit 2
fi

cd "$repo_root"

for command_name in xcodebuild xcbeautify diskutil codesign xcrun security gh git ditto lipo; do
  if ! command -v "$command_name" >/dev/null; then
    print -u2 "Missing required command: $command_name"
    exit 1
  fi
done

if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "Release stopped: commit or remove every working-tree change first."
  exit 1
fi

identity=$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ { print $2; exit }')
if [[ -z "$identity" ]]; then
  print -u2 "Release stopped: no Developer ID Application certificate is installed."
  exit 1
fi

settings=$(xcodebuild \
  -project Vellum.xcodeproj \
  -scheme "Vellum Mac" \
  -configuration Release \
  -showBuildSettings 2>/dev/null)
version=$(print -r -- "$settings" | awk -F' = ' '/^[[:space:]]*MARKETING_VERSION =/ { print $2; exit }')
build=$(print -r -- "$settings" | awk -F' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION =/ { print $2; exit }')

if [[ -z "$version" || -z "$build" ]]; then
  print -u2 "Release stopped: could not read the Mac version and build number."
  exit 1
fi

tag="v$version"
release_dir="$repo_root/build/releases/Vellum-$version-$build"
archive_path="$release_dir/Vellum.xcarchive"
export_dir="$release_dir/export"
derived_data="$release_dir/DerivedData"
dmg_root="$release_dir/dmg-root"
updates_dir="$release_dir/updates"
dmg_path="$updates_dir/Vellum.dmg"
appcast_path="$updates_dir/appcast.xml"

if [[ -e "$release_dir" ]]; then
  print -u2 "Release stopped: output already exists at $release_dir"
  exit 1
fi

mkdir -p "$release_dir" "$updates_dir"

print "Archiving Vellum $version ($build)..."
set -o pipefail
xcodebuild archive \
  -project Vellum.xcodeproj \
  -scheme "Vellum Mac" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data" \
  | xcbeautify

print "Exporting with Developer ID..."
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportOptionsPlist Distribution/ExportOptions.plist \
  -exportPath "$export_dir" \
  -allowProvisioningUpdates \
  | xcbeautify

app_path="$export_dir/Vellum.app"
if [[ ! -d "$app_path" ]]; then
  print -u2 "Release stopped: Xcode did not export $app_path"
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
signature=$(codesign -dv --verbose=4 "$app_path" 2>&1)
if [[ "$signature" != *"Authority=Developer ID Application:"* \
   || "$signature" != *"flags=0x10000(runtime)"* \
   || "$signature" != *"Timestamp="* ]]; then
  print -u2 "Release stopped: the exported app lacks a timestamped Developer ID Hardened Runtime signature."
  exit 1
fi

executable="$app_path/Contents/MacOS/Vellum"
architectures=$(lipo -archs "$executable")
if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
  print -u2 "Release stopped: expected arm64 and x86_64, found: $architectures"
  exit 1
fi

mkdir "$dmg_root"
ditto "$app_path" "$dmg_root/Vellum.app"
ln -s /Applications "$dmg_root/Applications"

print "Creating and signing Vellum.dmg..."
diskutil image create from \
  --volumeName Vellum \
  --format UDZO \
  "$dmg_root" \
  "$dmg_path"
codesign --force \
  --sign "$identity" \
  --timestamp \
  --identifier com.vellum.app.dmg \
  "$dmg_path"
codesign --verify --strict --verbose=2 "$dmg_path"

print "Submitting Vellum.dmg to Apple's notary service..."
xcrun notarytool submit "$dmg_path" \
  --keychain-profile VellumNotary \
  --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl -a -vvv -t open \
  --context context:primary-signature \
  "$dmg_path"

generate_appcast=$(find "$derived_data/SourcePackages/artifacts" \
  -type f -name generate_appcast -perm -111 -print -quit)
if [[ -z "$generate_appcast" ]]; then
  print -u2 "Release stopped: Sparkle's generate_appcast tool was not found."
  exit 1
fi

print "Signing the Sparkle update feed..."
"$generate_appcast" \
  --account Vellum \
  --download-url-prefix \
    "https://github.com/ayushdeolasee/Vellum/releases/latest/download/" \
  --link "https://vellum.work/" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  "$updates_dir"

if [[ ! -s "$appcast_path" ]] \
  || ! grep -q 'sparkle:edSignature=' "$appcast_path"; then
  print -u2 "Release stopped: Sparkle did not produce a signed appcast.xml."
  exit 1
fi

print "Verified release artifacts:"
print "  $dmg_path"
print "  $appcast_path"

if [[ "$publish" != true ]]; then
  print "Not published. Re-run with --publish after testing these artifacts."
  exit 0
fi

if gh release view "$tag" >/dev/null 2>&1; then
  print -u2 "Release stopped: GitHub release $tag already exists."
  exit 1
fi

print "Publishing GitHub release $tag..."
gh release create "$tag" \
  "$dmg_path#Vellum.dmg" \
  "$appcast_path#appcast.xml" \
  --repo ayushdeolasee/Vellum \
  --target "$(git rev-parse HEAD)" \
  --title "Vellum $version" \
  --generate-notes \
  --latest

print "Published Vellum $version: https://github.com/ayushdeolasee/Vellum/releases/tag/$tag"
