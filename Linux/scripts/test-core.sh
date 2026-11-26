#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
exec bash "$here/dev-shell.sh" swift test -c debug \
  --package-path /work/Packages/VellumCore --scratch-path /build/core \
  -Xswiftc -strict-concurrency=minimal "$@"
