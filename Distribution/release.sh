#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h}"
repository="ayushdeolasee/Vellum"
version="${1:-}"

usage() {
  print -u2 "Usage: Distribution/release.sh <version>"
  print -u2 "Example: Distribution/release.sh 0.1.2"
}

read_mac_setting() {
  local key="$1"

  awk -v key="$key" '
    /^  VellumMac:$/ {
      in_mac_target = 1
      next
    }
    in_mac_target && /^  [A-Za-z][A-Za-z0-9_-]*:$/ {
      exit
    }
    in_mac_target && $1 == key ":" {
      gsub(/"/, "", $2)
      print $2
      exit
    }
  ' project.yml
}

version_is_greater() {
  local candidate="$1"
  local current="$2"
  local -a candidate_parts current_parts
  local index candidate_part current_part

  candidate_parts=("${(@s:.:)candidate}")
  current_parts=("${(@s:.:)current}")

  for index in 1 2 3; do
    candidate_part="${candidate_parts[$index]}"
    current_part="${current_parts[$index]}"

    if (( 10#$candidate_part > 10#$current_part )); then
      return 0
    fi
    if (( 10#$candidate_part < 10#$current_part )); then
      return 1
    fi
  done

  return 1
}

update_mac_version() {
  local new_version="$1"
  local new_build="$2"
  local temporary_project

  temporary_project=$(mktemp "${TMPDIR:-/tmp}/vellum-project.XXXXXX")

  if ! awk -v new_version="$new_version" -v new_build="$new_build" '
    /^  VellumMac:$/ {
      in_mac_target = 1
    }
    in_mac_target && /^  [A-Za-z][A-Za-z0-9_-]*:$/ && $0 !~ /^  VellumMac:$/ {
      in_mac_target = 0
    }
    in_mac_target && $1 == "MARKETING_VERSION:" {
      sub(/"[^"]*"/, "\"" new_version "\"")
      version_updates++
    }
    in_mac_target && $1 == "CURRENT_PROJECT_VERSION:" {
      sub(/"[^"]*"/, "\"" new_build "\"")
      build_updates++
    }
    {
      print
    }
    END {
      if (version_updates != 1 || build_updates != 1) {
        exit 42
      }
    }
  ' project.yml > "$temporary_project"; then
    rm -f "$temporary_project"
    print -u2 "Release stopped: could not update the Mac version in project.yml."
    exit 1
  fi

  mv "$temporary_project" project.yml
}

if [[ "$#" -ne 1 ]]; then
  usage
  exit 2
fi

version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "$version" =~ $version_pattern ]]; then
  print -u2 "Release stopped: version must look like 0.1.2."
  exit 2
fi

cd "$repo_root"

for command_name in git gh xcodegen xcodebuild; do
  if ! command -v "$command_name" >/dev/null; then
    print -u2 "Missing required command: $command_name"
    exit 1
  fi
done

branch=$(git symbolic-ref --quiet --short HEAD || true)
if [[ "$branch" != "main" ]]; then
  print -u2 "Release stopped: run this command from the main branch."
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "Release stopped: commit or remove every working-tree change first."
  exit 1
fi

print "Syncing main with origin..."
git fetch --quiet origin main

if ! git merge-base --is-ancestor HEAD origin/main; then
  print -u2 "Release stopped: local main has commits that are not on origin/main."
  print -u2 "Resolve or push them before releasing."
  exit 1
fi

if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  git merge --ff-only origin/main
fi

tag="v$version"
if gh release view "$tag" --repo "$repository" >/dev/null 2>&1; then
  print -u2 "Release stopped: GitHub release $tag already exists."
  exit 1
fi

if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  print -u2 "Release stopped: Git tag $tag already exists."
  exit 1
fi

current_version=$(read_mac_setting MARKETING_VERSION)
current_build=$(read_mac_setting CURRENT_PROJECT_VERSION)

if [[ ! "$current_version" =~ $version_pattern || ! "$current_build" =~ '^[0-9]+$' ]]; then
  print -u2 "Release stopped: project.yml has an invalid Mac version or build number."
  exit 1
fi

if [[ "$version" != "$current_version" ]]; then
  if ! version_is_greater "$version" "$current_version"; then
    print -u2 "Release stopped: $version must be newer than $current_version."
    exit 1
  fi

  next_build=$(( current_build + 1 ))
  print "Preparing Vellum $version ($next_build)..."
  update_mac_version "$version" "$next_build"
  xcodegen generate

  settings=$(xcodebuild \
    -project Vellum.xcodeproj \
    -scheme "Vellum Mac" \
    -configuration Release \
    -showBuildSettings 2>/dev/null)
  generated_version=$(print -r -- "$settings" \
    | awk -F' = ' '/^[[:space:]]*MARKETING_VERSION =/ { print $2; exit }')
  generated_build=$(print -r -- "$settings" \
    | awk -F' = ' '/^[[:space:]]*CURRENT_PROJECT_VERSION =/ { print $2; exit }')

  if [[ "$generated_version" != "$version" || "$generated_build" != "$next_build" ]]; then
    print -u2 "Release stopped: Xcode did not adopt version $version ($next_build)."
    exit 1
  fi

  unexpected_changes=$(git diff --name-only \
    | awk '$0 != "project.yml" && $0 !~ /^Vellum\.xcodeproj\// { print }')
  if [[ -n "$unexpected_changes" ]]; then
    print -u2 "Release stopped: xcodegen changed unexpected files:"
    print -u2 -- "$unexpected_changes"
    exit 1
  fi

  git diff --check
  git add project.yml Vellum.xcodeproj
  git commit -m "Release Vellum $version"
  git push origin main
else
  print "Vellum $version ($current_build) is already prepared on main."
fi

print "Building, signing, notarizing, and publishing Vellum $version..."
Distribution/release-macos.sh --publish
