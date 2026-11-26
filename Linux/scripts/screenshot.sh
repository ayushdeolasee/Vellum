#!/usr/bin/env bash
# Inside dev-shell.sh, build the Debug executable into /build/linux first.
# Write the probe measurements to stderr and the auto/busy Weston screenshot to stdout.
set -euo pipefail
[[ ${1:-probe} == probe && $# -le 1 ]] || { echo "usage: $0 probe" >&2; exit 64; }
if [[ ${VELLUM_PRIVATE_BUS:-0} != 1 ]]; then
  exec dbus-run-session -- env VELLUM_PRIVATE_BUS=1 bash "$0" probe
fi
tmp=$(mktemp -d)
export XDG_RUNTIME_DIR="$tmp/run" XDG_CACHE_HOME="$tmp/cache" XDG_STATE_HOME="$tmp/state"
export XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" XDG_PICTURES_DIR="$tmp/pictures"
export WAYLAND_DISPLAY=vellum-probe GDK_BACKEND=wayland GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1
export GTK_A11Y=none
mkdir -m 700 -p "$XDG_RUNTIME_DIR" "$XDG_PICTURES_DIR"
app=/build/linux/debug/vellum-linux
[[ -x $app ]] || { echo "build vellum-linux with --scratch-path /build/linux -c debug first" >&2; exit 1; }
wpid= apid=
cleanup() {
  if [[ -n $apid ]]; then kill "$apid" 2>/dev/null || true; fi
  if [[ -n $wpid ]]; then kill "$wpid" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
weston --no-config --backend=headless --renderer=pixman --shell=kiosk-shell.so \
  --socket="$WAYLAND_DISPLAY" --width=800 --height=480 --idle-time=0 \
  --debug >"$tmp/weston.log" 2>&1 &
wpid=$!
for ((i=0; i<200; i++)); do
  [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && break
  kill -0 "$wpid" || { cat "$tmp/weston.log" >&2; exit 1; }
  sleep .05
done
[[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]]

for pump in auto timer missing eventfd; do
  for load in idle busy; do
    echo "requested=$pump load=$load" >&2
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
  done
done
shopt -s nullglob
png=("$XDG_PICTURES_DIR"/*.png)
[[ ${#png[@]} == 1 && -s ${png[0]} ]]
cat "${png[0]}"
