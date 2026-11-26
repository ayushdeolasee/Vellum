#!/usr/bin/env bash
# Dedicated arm64 Colima test VM. Run after building the Debug reader with dev-shell.sh.
# With chat, emits a tar.gz containing the reader screenshots and requires the
# C8 test image with gnome-keyring. Otherwise emits a Weston screenshot. Only the fixed fixtures and disposable
# runtime files enter the container that permits WebKit's nested bubblewrap sandbox.
set -euo pipefail
mode=${1:-web}
[[ $mode == web || $mode == chat || $mode == chat-write ]] || exit 64
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
key=$(printf '%s' "$repo" | shasum -a 256 | cut -c1-16)
volume=${VELLUM_BUILD_VOLUME:-vellum-build-$key}
image=${VELLUM_DEV_IMAGE:-vellum-linux-dev:6.4.3}
stage=$(mktemp -d "$repo/.vellum-web-test.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/library/PDFs" "$stage/library/Web Pages" "$stage/runtime"
fixtures="$repo/Packages/VellumCore/Tests/VellumCoreTests/Fixtures"
cp "$fixtures"/Pdf/{classic-two-column,rotated-all-angles}.pdf "$stage/library/PDFs/"
cp "$fixtures/harbor.vellumweb" "$stage/library/Web Pages/"
# The original Harbor stays byte-for-byte intact. Two derivative snapshots isolate
# sidecar-only handwriting, record/peer metadata and the absence of handwriting.
python3 - "$stage/library" "$fixtures/Web" <<'PYFIXTURE'
import hashlib, json, pathlib, shutil, sys, zipfile
library, fixtures = map(pathlib.Path, sys.argv[1:])
pages = library / "Web Pages"
records = library / ".vellum/records"
positions = library / ".vellum/positions"
records.mkdir(parents=True)
positions.mkdir()
record = json.loads((fixtures / "web-ink-v3.page.json").read_text())
key = hashlib.sha256(record["url"].encode()).hexdigest()
record.update(title="Sidecar article", title_is_user_defined=True)
(records / f"{key}.json").write_text(json.dumps(record))
shutil.copyfile(fixtures / "web-ink-v3.ink.json", records / f"{key}.ink.json")
device = "12345678-0000-4000-8000-000000000001"
stamp = "2026-11-26T00:00:00.000000Z"
peer = {"schema_version": 1, "device_id": device, "written_at": stamp, "documents": {
    f"web:{key}": {"reading_position": {"at": stamp, "value": {"page": 3, "page_count": 5}}}}}
(positions / f"{device}.v1.json").write_text(json.dumps(peer))
with zipfile.ZipFile(pages / "harbor.vellumweb") as source:
    for name, url in [("sidecar-only", record["url"]), ("plain", "https://fixture.test/plain")]:
        with zipfile.ZipFile(pages / f"{name}.vellumweb", "w") as output:
            manifest = json.loads(source.read("manifest.json"))
            manifest.update(url=url, canonical_url=url, title="Plain article")
            del manifest["hashes"]["ink"]
            output.writestr("manifest.json", json.dumps(manifest))
            for item in source.namelist():
                if item not in ("manifest.json", "ink.json"):
                    output.writestr(item, source.read(item))
PYFIXTURE
mkdir -p "$stage/runtime"/{scripts,Tests/CShellPump,Tests/GTKReader,Sources/CShell}
cp "$here"/{screenshot.sh,reader-acceptance.py} "$stage/runtime/scripts/"
cp "$here/../Tests/CShellPump/scheduling.c" "$stage/runtime/Tests/CShellPump/"
cp "$here/../Tests/GTKReader/pending-exit.c" "$stage/runtime/Tests/GTKReader/"
cp -R "$here"/../Sources/CShell/{loop.c,include} "$stage/runtime/Sources/CShell/"

# Export just the executable with the ordinary OCI profile. No writable checkout
# or build volume is exposed to the alternate profile.
docker --context colima-vellum run --rm --network none \
  --mount "type=volume,src=$volume,dst=/build,readonly" "$image" \
  cat /build/linux/debug/vellum-linux > "$stage/runtime/vellum-linux"
chmod 755 "$stage/runtime/vellum-linux"

# Docker 29.5.2 uses moby/profiles/seccomp v0.2.3. Only setup fetches this pin.
curl -fsSL --retry 2 https://raw.githubusercontent.com/moby/profiles/seccomp/v0.2.3/seccomp/default.json \
  -o "$stage/default.json"
python3 - "$stage" <<'PY'
import hashlib, json, pathlib, sys
stage = pathlib.Path(sys.argv[1])
data = (stage / "default.json").read_bytes()
if hashlib.sha256(data).hexdigest() != "536529b665dd0972c37bfb569f5d4ac8a53592e7b00752bc39ff063ca9864c74":
    sys.exit("Unexpected Moby seccomp baseline")
profile = json.loads(data)
profile["syscalls"].append({"names": ["clone", "unshare", "mount", "umount2", "pivot_root"],
                            "action": "SCMP_ACT_ALLOW"})
(stage / "webkit.json").write_text(json.dumps(profile))
PY
manifest() (
  cd "$stage/library"
  find . -print | LC_ALL=C sort
  find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort
)

# Ubuntu's stock flatpak AppArmor profile permits unprivileged userns. The
# masked parent procfs otherwise prevents bwrap mounting /proc in its PID ns.
# These options only apply to the disposable offline test container in this VM.
args=(--rm --platform linux/arm64 --network none --cap-drop ALL
      --security-opt no-new-privileges --security-opt "seccomp=$stage/webkit.json"
      --security-opt apparmor=flatpak --security-opt systempaths=unconfined
      --read-only --tmpfs /tmp:exec,nosuid,nodev --tmpfs /home/reader:uid=20001,gid=20001
      --mount "type=bind,src=$stage/runtime,dst=/runtime,readonly"
      --mount "type=bind,src=$stage/library,dst=/library,readonly"
      -e VELLUM_READER_BINARY=/runtime/vellum-linux)
if [[ $mode == chat || $mode == chat-write ]]; then
  if [[ $mode == chat-write ]]; then args+=(-e VELLUM_EXPECT_CHAT_SAVE=1); fi
  # Only this container trusts the one-day fixture certificate. All provider
  # names resolve to loopback and the production binary has no endpoint override.
  cp "$here"/{chat-acceptance.py,with-test-keyring.sh} "$here/../Tests/GTKReader/force-chat-quit.c" "$stage/runtime/"
  hosts=(generativelanguage.googleapis.com api.openai.com openrouter.ai opencode.ai)
  for host in "${hosts[@]}"; do args+=(--add-host "$host:127.0.0.1"); done
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=chat-fixture \
    -addext "subjectAltName=DNS:${hosts[0]},DNS:${hosts[1]},DNS:${hosts[2]},DNS:${hosts[3]}" \
    -keyout "$stage/runtime/fixture.key" -out "$stage/runtime/fixture.crt" 2>/dev/null
  chmod 644 "$stage/runtime/fixture.key"
  args+=(--mount "type=bind,src=$stage/runtime/fixture.crt,dst=/etc/ssl/certs/ca-certificates.crt,readonly")
  python3 - "$stage/library" <<'PYCHAT'
import hashlib, json, pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
pages = root / "Web Pages"
with zipfile.ZipFile(pages / "harbor.vellumweb") as z:
    manifest = json.loads(z.read("manifest.json"))
    key = hashlib.sha256(manifest["url"].encode()).hexdigest()
    html = b"<article>Visible Safari fact<span hidden>Hidden fixture text</span></article>"
    capture = dict(manifest, url="https://fixture.test/safari", canonical_url="https://fixture.test/safari")
    capture["hashes"] = dict(manifest["hashes"], snapshot_html="sha256:" + hashlib.sha256(html).hexdigest(),
                             page_text="sha256:" + hashlib.sha256(b"[]").hexdigest())
    with zipfile.ZipFile(pages / "safari.vellumweb", "w") as output:
        for name in z.namelist():
            data = {"manifest.json": json.dumps(capture).encode(), "text/pages.json": b"[]",
                    "snapshot/index.html": html}.get(name, z.read(name))
            output.writestr(name, data)
broken = root / ".vellum/documents" / hashlib.sha256(capture["url"].encode()).hexdigest() / "conversations.json"
broken.parent.mkdir(parents=True)
broken.write_bytes(b'{"cut":')
file = root / ".vellum/documents" / key / "conversations.json"
file.parent.mkdir(parents=True)
file.write_text('[{"id":"1","role":"assistant","content":"Apple history","createdAt":"2026-11-26T00:00:00.000Z","extra":1.000}]')
PYCHAT
  manifest > "$stage/before"
  docker --context colima-vellum run "${args[@]}" "$image" bash -c '
    bash /runtime/with-test-keyring.sh python3 /runtime/chat-acceptance.py >&2 &&
    cd /tmp && tar -czf - reader-before.png reader-chat*.png'
  manifest > "$stage/after"
  diff -u "$stage/before" "$stage/after" >&2
  exit
fi
manifest > "$stage/before"
docker --context colima-vellum run "${args[@]}" "$image" bash /runtime/scripts/screenshot.sh reader > /dev/null
docker --context colima-vellum run "${args[@]}" "$image" bash /runtime/scripts/screenshot.sh web > "$stage/harbor.png"
manifest > "$stage/after"
diff -u "$stage/before" "$stage/after"
echo "Identical library paths and SHA-256 digests before and after PDF and web sessions" >&2
cat "$stage/harbor.png"
