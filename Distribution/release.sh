#!/bin/zsh
set -euo pipefail
# Explicit Store stages replace the former bump/push/build/publish shortcut.
repo_root="${0:A:h:h}"
exec python3 "$repo_root/Distribution/store-release.py" "$@"
