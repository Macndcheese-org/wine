#!/bin/bash
# Pre-releases of MacNdCheese Wine.
#
#   prerelease.sh tag                       print the tag of the pre-release to make, e.g. 11.20.0
#   prerelease.sh publish <tag> <asset>     make (or replace) the pre-release <tag> with <asset>
#
# A release is called "MacNdCheese Wine <wine version>.<patch>", for example "MacNdCheese Wine 11.20.0",
# and has the tag <wine version>.<patch>.  A build publishes the lowest patch number that has no
# stable release yet, as a pre-release, and the next build replaces it.  Once the pre-release is
# marked as stable (edit the release on GitHub and untick "pre-release"), the builds that follow
# publish the next number, 11.20.1 and so on.
#
# Needs gh, with GH_TOKEN, and GITHUB_REPOSITORY; "publish" also GITHUB_SHA.  The wine version is
# the one in the VERSION file.  PRERELEASE_VERSION_FILE overrides where it is read.
set -euo pipefail

repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}

# none, prerelease or stable, for the release with this tag
release_state() {
  local out
  if ! out=$(gh api "repos/$repo/releases/tags/$1" --jq 'if .draft then "draft" elif .prerelease then "prerelease" else "stable" end' 2>&1); then
    case $out in
      *"HTTP 404"*) echo none; return ;;
      *) echo "cannot look up the release $1: $out" >&2; return 1 ;;
    esac
  fi
  echo "$out"
}

next_tag() {
  local version_file=${PRERELEASE_VERSION_FILE:-VERSION} upstream n=0 state
  upstream=$(grep -o '[0-9][0-9.]*' "$version_file" | head -1)
  [ -n "$upstream" ] || { echo "no wine version in $version_file" >&2; return 1; }
  while state=$(release_state "$upstream.$n") && [ "$state" = stable ]; do n=$((n + 1)); done
  [ -n "$state" ] || return 1       # the lookup failed, which is not the same as "no such release"
  echo "$upstream.$n"
}

publish() {
  local tag=$1 asset=$2 state
  [ -f "$asset" ] || { echo "$asset does not exist" >&2; return 1; }
  state=$(release_state "$tag") || return 1
  case $state in
    stable) echo "$tag is a stable release; it is not replaced" >&2; return 1 ;;
    none) ;;
    *) gh release delete "$tag" --repo "$repo" --cleanup-tag --yes ;;   # the previous build
  esac
  gh release create "$tag" "$asset" --repo "$repo" \
    --target "${GITHUB_SHA:?GITHUB_SHA is not set}" \
    --prerelease \
    --title "MacNdCheese Wine $tag" \
    --notes "Pre-release built from $GITHUB_SHA ($(git log -1 --format=%s)).

The next build of the branch replaces it.  To keep it, edit the release and untick \"pre-release\": the next builds are then published as the following number."
}

case ${1:-} in
  tag) next_tag ;;
  publish) [ $# -eq 3 ] || { sed -n '2,5p' "$0"; exit 2; }; publish "$2" "$3" ;;
  *) sed -n '2,5p' "$0"; exit 2 ;;
esac
