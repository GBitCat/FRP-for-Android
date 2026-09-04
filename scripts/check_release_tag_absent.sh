#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 1 || $# > 2 )); then
  printf 'Usage: %s VERSION [REMOTE]\n' "$0" >&2
  exit 2
fi

version="$1"
remote="${2:-origin}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]]; then
  printf 'Invalid release version: %s\n' "$version" >&2
  exit 2
fi

tag="v$version"
set +e
git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1
lookup_status=$?
set -e

case "$lookup_status" in
  0)
    printf 'Release tag already exists: %s\n' "$tag" >&2
    exit 1
    ;;
  2)
    printf 'Release tag is available: %s\n' "$tag"
    ;;
  *)
    printf 'Unable to verify release tag %s against %s (git exit %d)\n' \
      "$tag" "$remote" "$lookup_status" >&2
    exit 1
    ;;
esac
