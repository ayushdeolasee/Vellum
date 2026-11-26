#!/usr/bin/env bash
# Run the LinuxServices credential checks with an unmounted, disposable home
# and private D-Bus daemon. Requires gnome-keyring in the test image only.
set -euo pipefail
root=$(mktemp -d)
bus_pid=
keyring_pid=
cleanup() {
    if [[ -n $keyring_pid ]]; then kill "$keyring_pid" 2>/dev/null || true; fi
    if [[ -n $bus_pid ]]; then kill "$bus_pid" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    rm -rf -- "$root"
}
trap cleanup EXIT
export HOME="$root" XDG_DATA_HOME="$root/data" XDG_CONFIG_HOME="$root/config" XDG_RUNTIME_DIR="$root/run"
mkdir -m 700 "$XDG_RUNTIME_DIR"
unset GNOME_KEYRING_CONTROL GNOME_KEYRING_PID
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
dbus-daemon --session --nofork --address="$DBUS_SESSION_BUS_ADDRESS" &
bus_pid=$!
for ((i=0; i<100; i++)); do
    [[ -S $XDG_RUNTIME_DIR/bus ]] && break
    sleep .02
done
printf '%s' 'disposable-fixture' | gnome-keyring-daemon --foreground --unlock --components=secrets \
    --control-directory="$root/control" >&2 &
keyring_pid=$!
gdbus wait --session --timeout=5 org.freedesktop.secrets
export VELLUM_TEST_KEYRING="$root"
"$@"
