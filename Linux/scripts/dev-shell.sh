#!/usr/bin/env bash
set -euo pipefail
repo=$(CDPATH= cd -P -- "$(dirname "$0")/../.." && pwd -P)
key=$(printf '%s' "$repo" | shasum -a 256 | cut -c1-16)
# Concurrent runs in this checkout can select different named volumes.
volume=${VELLUM_BUILD_VOLUME:-vellum-build-$key}
args=(--rm -i --platform linux/arm64
      --mount "type=bind,src=$repo,dst=/repo,readonly"
      --mount "type=volume,src=$volume,dst=/build")
if [[ -t 0 && -t 1 ]]; then args+=(-t); fi
if [[ -n ${VELLUM_FIXTURE_COPY:-} ]]; then
  if [[ ! -d $VELLUM_FIXTURE_COPY ]] || ! fixture=$(realpath -- "$VELLUM_FIXTURE_COPY"); then
    echo "VELLUM_FIXTURE_COPY must name an accessible directory: $VELLUM_FIXTURE_COPY" >&2
    exit 1
  fi
  args+=(--mount "type=bind,src=$fixture,dst=/library,readonly")
fi
if [[ ${VELLUM_OFFLINE:-0} == 1 ]]; then args+=(--network none); fi
if [[ $# == 0 ]]; then set -- bash; fi

# Use DOCKER_CONTEXT to select another local profile, e.g. colima-vellum.
exec docker --context "${DOCKER_CONTEXT:-colima}" run "${args[@]}" vellum-linux-dev:6.4.3 \
  bash -eu -o pipefail -c '
    cd /work
    items=(Linux)
    if [[ -d /repo/Packages/VellumCore ]]; then items+=(Packages/VellumCore); fi
    tar -C /repo --exclude=.build --exclude=.swiftpm -cf - "${items[@]}" |
      tar --no-same-owner -C /work -xf -
    exec "$@"
  ' dev-shell "$@"
