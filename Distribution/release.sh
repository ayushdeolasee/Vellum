#!/bin/zsh
set -euo pipefail
# Explicit stages for direct Mac and iOS Store distribution.
repo_root="${0:A:h:h}"
exec "${VELLUM_RELEASE_PYTHON:-python3}" "$repo_root/Distribution/store-release.py" "$@"
