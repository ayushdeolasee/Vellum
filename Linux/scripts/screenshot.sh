#!/usr/bin/env bash
# Inside dev-shell.sh, build the Debug executable into /build/linux first.
# Write measurements to stderr and the auto/busy Weston screenshot to stdout.
set -euo pipefail
[[ ${1:-probe} == probe && $# -le 1 ]] || { echo "usage: $0 probe" >&2; exit 64; }
if [[ ${VELLUM_PRIVATE_BUS:-0} != 1 ]]; then
  exec dbus-run-session -- env VELLUM_PRIVATE_BUS=1 bash "$0" probe
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XDG_CACHE_HOME="$tmp/cache" XDG_STATE_HOME="$tmp/state"
export XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_PICTURES_DIR="$tmp/pictures"
export WAYLAND_DISPLAY=vellum-probe GDK_BACKEND=wayland GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1
export GTK_A11Y=none
mkdir -m 700 -p "$XDG_PICTURES_DIR"
app=/build/linux/debug/vellum-linux
[[ -x $app ]] || { echo "build vellum-linux with --scratch-path /build/linux -c debug first" >&2; exit 1; }

# First check dispatch order deterministically across stalls without depending on Weston timing.
linux_dir=$(cd "$(dirname "$0")/.." && pwd)
cc -O0 -g -rdynamic -I"$linux_dir/Sources/CShell/include" \
  "$linux_dir/Tests/CShellPump/scheduling.c" "$linux_dir/Sources/CShell/loop.c" \
  $(pkg-config --cflags --libs glib-2.0) -ldl -o "$tmp/check-scheduling"
timeout -k 1 8 "$tmp/check-scheduling" >&2

run_case() (
  set -e
  pump=$1 load=$2
  echo "requested=$pump load=$load" >&2
  export XDG_RUNTIME_DIR="$tmp/$pump-$load"
  mkdir -m 700 "$XDG_RUNTIME_DIR"
  log="$XDG_RUNTIME_DIR/weston.log"
  wpid= apid=
  cleanup() {
    rc=$?
    if (( rc != 0 && rc != 77 )); then cat "$log" >&2; fi
    if [[ -n $apid ]]; then kill "$apid" 2>/dev/null || true; fi
    if [[ -n $wpid ]]; then kill "$wpid" 2>/dev/null || true; fi
    wait 2>/dev/null || true
  }
  trap cleanup EXIT
  weston --no-config --backend=headless --renderer=pixman --shell=kiosk-shell.so \
    --socket="$WAYLAND_DISPLAY" --width=800 --height=480 --idle-time=0 \
    --debug >"$log" 2>&1 &
  wpid=$!
  for ((i=0; i<200; i++)); do
    [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && break
    kill -0 "$wpid" || exit 1
    sleep .05
  done
  [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]]

  if [[ $pump == auto && $load == busy ]]; then
    VELLUM_PROBE_CAPTURE_DIR="$tmp" timeout -k 1 12 "$app" --probe "$pump" "$load" >&2 &
    apid=$!
    until [[ -f $tmp/ready ]]; do
      kill -0 "$apid" 2>/dev/null || { wait "$apid"; exit 1; }
      sleep .05
    done
    (cd "$XDG_PICTURES_DIR" && timeout -k 1 5 weston-screenshooter >&2)
    touch "$tmp/captured"
    wait "$apid"
    apid=
  else
    timeout -k 1 12 "$app" --probe "$pump" "$load" >&2
  fi
)
failed=0 unavailable=0
for pump in auto timer missing eventfd; do
  for load in idle busy; do
    report="$tmp/$pump-$load.log"
    set +e
    run_case "$pump" "$load" 2>"$report"
    rc=$?
    set -e
    cat "$report" >&2
    if [[ $rc == 77 && $pump == eventfd ]]; then
      unavailable=$((unavailable + 1))
    elif (( rc != 0 )); then
      echo "$pump/$load failed (status $rc)" >&2
      failed=1
    fi
  done
done
(( failed == 0 ))
# An unavailable SPI must still demonstrate both working fallback paths.
python3 - "$tmp" "$unavailable" <<'PYTHON'
from pathlib import Path
import sys

root, missing = Path(sys.argv[1]), int(sys.argv[2])
def read(mode, load):
    words = (root / f"{mode}-{load}.log").read_text().split()
    return dict(word.split("=", 1) for word in words if "=" in word)

def require(ok, reason):
    if not ok:
        sys.exit(reason)

require(missing in (0, 2), "inconsistent strict eventfd availability")
for load in ("idle", "busy"):
    timer = read("timer", load)
    for mode in ("timer", "missing", "auto", "eventfd"):
        if missing and mode == "eventfd":
            continue
        row = read(mode, load)
        fd = mode in ("auto", "eventfd") and not missing
        expect = "eventfd" if fd else "timer"
        case = f"{mode}/{load}"
        require(row["selected"] == row["effective"] == expect, f"{case}: unexpected pump")
        if not fd:
            continue
        # One-second quiet baselines. Allow 2 ms of CPU noise and occasional empty turns.
        require(int(row["idle_wakes"]) <= int(timer["idle_wakes"]) / 4, f"{case}: idle wakes")
        require(float(row["idle_cpu_ms"]) <= max(2, .75 * float(timer["idle_cpu_ms"])), f"{case}: idle CPU")
        require(int(row["no_progress"]) <= 64, f"{case}: excessive wakes without probe progress")
        if load == "busy":
            for count, gap, slack in (("input", "input_gap_us", 15000), ("paints", "paint_gap_us", 32000)):
                require(int(row[count]) >= .70 * int(timer[count]), f"{case}: too few {count}")
                ref = int(timer[gap])
                require(int(row[gap]) <= max(2 * ref, ref + slack), f"{case}: excessive {gap}")
PYTHON
if (( unavailable )); then
  echo "strict eventfd unavailable in both loads (77); fallback cases passed" >&2
  exit 77
fi
shopt -s nullglob
png=("$XDG_PICTURES_DIR"/*.png)
[[ ${#png[@]} == 1 && -s ${png[0]} ]]
cat "${png[0]}"
