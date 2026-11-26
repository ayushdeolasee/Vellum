#!/usr/bin/env bash
# Run on a Mac with the existing vellum Colima profile and cached, pinned SwiftPM deps.
# VELLUM_SYNCTHING_E2E=1 also needs a pre-staged Linux arm64 VELLUM_SYNCTHING_BINARY
# or a local VELLUM_SYNCTHING_IMAGE containing /bin/syncthing. No image is pulled.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
pkg="$repo/Packages/VellumCore"
[[ $(uname -s) == Darwin ]]
dockerctl=(docker --context colima-vellum)
endpoint=$("${dockerctl[@]}" context inspect colima-vellum --format '{{.Endpoints.docker.Host}}')
[[ "$endpoint" == "unix://$HOME/.colima/vellum/docker.sock" ]] || { echo 'Unexpected Colima endpoint' >&2; exit 1; }
export GIT_ALLOW_PROTOCOL=file
stage=$(mktemp -d "${TMPDIR:-/tmp}/vellum-s9.XXXXXXXX")
linux="vellum-s9-$(uuidgen | tr '[:upper:]' '[:lower:]')"
cleanup() {
    "${dockerctl[@]}" rm -fv "$linux" >/dev/null 2>&1 || true
    /usr/bin/find "$stage" -depth -delete
}
trap cleanup EXIT
image=vellum-linux-dev:6.4.3
"${dockerctl[@]}" run --detach --pull never --cpus 2 --network none --mount type=volume,destination=/s9/live --user 0 --name "$linux" "$image" sleep infinity >/dev/null
# Transfer only package source, synthetic fixtures and the two pinned dependency repositories.
# Neither host settings nor a host filesystem mount is visible to the build container.
mkdir -p "$stage/build/repositories" "$stage/exchange/mac"
printf 'synthetic\n' > "$stage/exchange/.synthetic-s9"
for dep in swift-crypto swift-asn1; do
    cached=("$HOME/Library/Caches/org.swift.swiftpm/repositories/$dep"-*)
    [[ ${#cached[@]} == 1 && -d ${cached[0]} ]] || { echo "Missing cached $dep repository" >&2; exit 1; }
    bare="$stage/build/repositories/$(basename "${cached[0]}")"
    git clone -q --bare --no-local "${cached[0]}" "$bare"
    git -C "$bare" remote set-url origin "https://github.com/apple/$dep.git"
done
"${dockerctl[@]}" exec "$linux" mkdir -p /s9/pkg /s9/build /s9/exchange
COPYFILE_DISABLE=1 tar --no-xattrs -C "$pkg" -cf - Package.swift Package.resolved Sources Tests |
    "${dockerctl[@]}" exec -i "$linux" tar --no-same-owner -xf - -C /s9/pkg
COPYFILE_DISABLE=1 tar --no-xattrs -C "$stage/build" -cf - repositories |
    "${dockerctl[@]}" exec -i "$linux" tar --no-same-owner -xf - -C /s9/build
# Compile the Linux reader and its native targets exactly as specified in the
# shipping Linux manifest. Link them into the staged Core test bundle so the
# Linux leg uses PDFium, the read-only store and the reader metadata catalog.
reader_targets=(CGtk CWebKit CShell CPdfium CPdfiumJob LinuxReader)
COPYFILE_DISABLE=1 tar --no-xattrs -C "$repo/Linux/Sources" -cf - "${reader_targets[@]}" |
    "${dockerctl[@]}" exec -i "$linux" tar --no-same-owner -xf - -C /s9/pkg/Sources
"${dockerctl[@]}" exec -i "$linux" sh -c 'cat >> /s9/pkg/Package.swift' <<'MANIFEST'
package.targets += [
    .systemLibrary(name: "CGtk", pkgConfig: "gtk4"),
    .systemLibrary(name: "CWebKit", pkgConfig: "webkitgtk-6.0"),
    .systemLibrary(name: "CPdfium", pkgConfig: "pdfium"),
    .target(name: "CShell", dependencies: ["CGtk", "CWebKit"], linkerSettings: [.linkedLibrary("dl")]),
    .target(name: "CPdfiumJob", dependencies: ["CPdfium"], linkerSettings: [.linkedLibrary("m")]),
    .target(name: "LinuxReader", dependencies: ["CPdfiumJob", "CShell", "VellumCore"],
            swiftSettings: [.swiftLanguageMode(.v5)])
]
package.targets.first { $0.name == "VellumCoreTests" }!.dependencies.append("LinuxReader")
MANIFEST
opts=(--configuration debug --force-resolved-versions -j 2)
mac_test() {
    swift test --package-path "$pkg" --scratch-path "$stage/build" "${opts[@]}" "$@"
}
linux_test() {
    "${dockerctl[@]}" exec -e GIT_ALLOW_PROTOCOL=file "$linux" swift test --package-path /s9/pkg --scratch-path /s9/build "${opts[@]}" "$@"
}
mac_phase() {
    VELLUM_S9_PHASE="$1" VELLUM_S9_PEER="$2" VELLUM_S9_SANDBOX="$stage/exchange" mac_test --skip-build --filter CrossPlatformRoundTripTests/exchange
    [[ $(cat "$stage/exchange/completed-$1") == "$1" ]]
}
linux_phase() {
    "${dockerctl[@]}" exec -e VELLUM_S9_PHASE="$1" -e VELLUM_S9_PEER="$2" -e VELLUM_S9_SANDBOX=/s9/exchange "$linux" \
        swift test --package-path /s9/pkg --scratch-path /s9/build "${opts[@]}" --skip-build --filter CrossPlatformRoundTripTests/exchange
    [[ $("${dockerctl[@]}" exec "$linux" cat "/s9/exchange/completed-$1") == "$1" ]]
}
swift build --build-tests --package-path "$pkg" --scratch-path "$stage/build" "${opts[@]}"
"${dockerctl[@]}" exec -e GIT_ALLOW_PROTOCOL=file "$linux" swift build --build-tests --package-path /s9/pkg --scratch-path /s9/build "${opts[@]}"
mac_phase send mac
"${dockerctl[@]}" cp "$stage/exchange/.synthetic-s9" "$linux:/s9/exchange/"
"${dockerctl[@]}" cp "$stage/exchange/mac" "$linux:/s9/exchange/linux"
linux_phase mutate linux
# A fresh destination forces the Mac verifier to read the Linux export.
mv "$stage/exchange/mac" "$stage/mac-original"
"${dockerctl[@]}" cp "$linux:/s9/exchange/linux" "$stage/exchange/mac"
mac_phase receive mac
echo 'Native Mac → Linux → Mac byte and semantic checks passed.'
mac_test --skip-build --filter TwoPeerOfflineConflictTests
linux_test --skip-build --filter TwoPeerOfflineConflictTests
if [[ ${VELLUM_SYNCTHING_E2E:-0} == 1 ]]; then
    python3 -I "$repo/Linux/scripts/syncthing-peers.py" "$stage" "$linux" "$pkg"
fi
