#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
key=$(printf '%s' "$repo" | shasum -a 256 | cut -c1-16)
args=(--rm -i --platform linux/arm64
      --mount "type=bind,src=$repo,dst=/repo,readonly"
      --mount "type=volume,src=vellum-build-$key,dst=/build")
if [[ -t 0 && -t 1 ]]; then args+=(-t); fi
if [[ -n ${VELLUM_FIXTURE_COPY:-} ]]; then
  args+=(--mount "type=bind,src=$VELLUM_FIXTURE_COPY,dst=/library,readonly")
fi
if [[ ${VELLUM_OFFLINE:-0} == 1 ]]; then args+=(--network none); fi
if [[ $# == 0 ]]; then set -- bash; fi

# Use DOCKER_CONTEXT to select another local profile, e.g. colima-vellum.
exec docker --context "${DOCKER_CONTEXT:-colima}" run "${args[@]}" "${VELLUM_DEV_IMAGE:-vellum-linux-dev:6.4.3}" \
  bash -eu -o pipefail -c '
    cd /work
    items=(Linux)
    if [[ -d /repo/Packages/VellumCore ]]; then items+=(Packages/VellumCore); fi
    tar -C /repo --exclude=.build --exclude=.swiftpm -cf - "${items[@]}" |
      tar --no-same-owner -C /work -xf -
    exec "$@"
  ' dev-shell "$@"
