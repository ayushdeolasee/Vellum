#!/bin/zsh
set -euo pipefail
# Compatibility entry point; both channels use one immutable artifact engine.
repo_root="${0:A:h:h}"
if [[ "${1:-}" == "archive" ]]; then
  shift
  exec "${VELLUM_RELEASE_PYTHON:-python3}" "$repo_root/Distribution/store-release.py" archive --platform macos "$@"
fi
exec "${VELLUM_RELEASE_PYTHON:-python3}" "$repo_root/Distribution/store-release.py" "$@"
