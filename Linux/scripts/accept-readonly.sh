#!/usr/bin/env bash
# Usage: accept-readonly.sh SYNTHETIC_FIXTURE_DIR OUTPUT.png
# PDFs/ must contain classic-two-column.pdf and rotated-all-angles.pdf from P7
# (#431, 60cafe05). Use the dev image built from Linux/Dockerfile.
set -euo pipefail
[[ $# == 2 ]] || { echo "usage: $0 SYNTHETIC_FIXTURE_DIR OUTPUT.png" >&2; exit 64; }
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
# Colima shares the Vellum worktrees. Keep the disposable copy inside this one.
stage=$(mktemp -d "$repo/.vellum-reader-test.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
copy="$stage/library"
python3 - "$1" "$copy" "$2" <<'PY'
import hashlib, pathlib, shutil, stat, sys
src, dst, output = map(pathlib.Path, sys.argv[1:])
if src.is_symlink() or not src.is_dir() or dst.resolve().is_relative_to(src.resolve()):
    sys.exit("expected a prepared fixture directory separate from staging")
if output.resolve().is_relative_to(src.resolve()) or output.is_symlink():
    sys.exit("output must be a separate screenshot, outside the source fixture")
pdfs = src / "PDFs"
if pdfs.is_symlink() or not pdfs.is_dir():
    sys.exit("expected the synthetic PDFs directory")
for name, digest in {
    "classic-two-column.pdf": "4fb6db749b9230464172fcdcb583c744637dde673aa1aa4da0e78dea8c0f3ef3",
    "rotated-all-angles.pdf": "9f141574be25c4b266bff0cfe8d78b1fec228ad7446a6d46599cfb0a1b1e1dab",
}.items():
    path = pdfs / name
    if (not stat.S_ISREG(path.lstat().st_mode) or path.stat().st_size > 65536
            or hashlib.sha256(path.read_bytes()).hexdigest() != digest):
        sys.exit(f"expected the P7 {name} fixture from #431")

def copy_tree(source, target):
    target.mkdir()
    target.chmod(0o755)
    for path in source.iterdir():
        mode = path.lstat().st_mode
        dest = target / path.name
        if stat.S_ISDIR(mode):
            copy_tree(path, dest)
        elif stat.S_ISREG(mode):
            shutil.copyfile(path, dest)
            dest.chmod(0o644)
        else:
            sys.exit(f"refusing non-regular fixture entry: {path}")
copy_tree(src, dst)
PY

manifest() {
  python3 - "$copy" <<'PY'
import hashlib, json, pathlib, stat, sys
root = pathlib.Path(sys.argv[1])
for path in [root, *sorted(root.rglob("*"))]:
    mode = path.lstat().st_mode
    digest = None
    if stat.S_ISREG(mode):
        h = hashlib.sha256()
        with path.open("rb") as f:
            for block in iter(lambda: f.read(1024 * 1024), b""):
                h.update(block)
        digest = h.hexdigest()
    elif not stat.S_ISDIR(mode):
        sys.exit(f"unexpected entry: {path}")
    print(json.dumps([str(path.relative_to(root)), mode, digest]))
PY
}

export DOCKER_CONTEXT=${DOCKER_CONTEXT:-colima-vellum}
VELLUM_FIXTURE_COPY= bash "$here/dev-shell.sh" swift build -c debug -j 2 \
  --package-path Linux --scratch-path /build/linux --product vellum-linux >&2
manifest > "$stage/before"
status=0
VELLUM_FIXTURE_COPY="$copy" VELLUM_OFFLINE=1 bash "$here/dev-shell.sh" \
  bash /work/Linux/scripts/screenshot.sh reader > "$stage/reader.png" || status=$?
manifest > "$stage/after"
diff -u "$stage/before" "$stage/after"
echo "Identical library manifests ($(wc -l < "$stage/after") entries)" >&2
(( status == 0 )) || exit "$status"
# Replace the output entry atomically so a pre-existing hard link cannot
# cause a write through to a source fixture file.
python3 - "$stage/reader.png" "$2" <<'PYTHON'
import os, pathlib, shutil, sys, tempfile
source, dest = map(pathlib.Path, sys.argv[1:])
with tempfile.NamedTemporaryFile(dir=dest.parent, delete=False) as out:
    try:
        with source.open("rb") as image:
            shutil.copyfileobj(image, out)
        out.flush()
        os.replace(out.name, dest)
    finally:
        pathlib.Path(out.name).unlink(missing_ok=True)
PYTHON
