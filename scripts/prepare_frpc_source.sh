#!/usr/bin/env bash
set -Eeuo pipefail

readonly FRP_SOURCE_COMMIT="e8731afd8a2b12765636368f762b99d121a97a26"
readonly FRP_SOURCE_ARCHIVE_SHA256="ee7b84935e608df805c46a81c33266517ae1596919ad5b194fe6b3378c447603"
readonly FRP_SOURCE_URL="https://github.com/GBitCat/frp-xudp/archive/${FRP_SOURCE_COMMIT}.tar.gz"

if (( $# != 1 )); then
  printf 'Usage: %s OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi

output_dir="$1"
if [[ -e "$output_dir" ]]; then
  printf 'Output path already exists: %s\n' "$output_dir" >&2
  exit 1
fi

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
archive_dir="$(mktemp -d /tmp/frpc-source-archive.XXXXXX)"
trap 'rm -rf -- "$archive_dir"' EXIT
archive="$archive_dir/frp-xudp.tar.gz"

if [[ -n "${FRP_SOURCE_ARCHIVE:-}" ]]; then
  archive="$FRP_SOURCE_ARCHIVE"
else
  curl --fail --silent --show-error --location --retry 3 \
    --output "$archive" "$FRP_SOURCE_URL"
fi
printf '%s  %s\n' "$FRP_SOURCE_ARCHIVE_SHA256" "$archive" |
  sha256sum --check --strict

mkdir -p "$output_dir"
tar --extract --gzip --file "$archive" --directory "$output_dir" \
  --strip-components=1 --no-same-owner --no-same-permissions

patch --batch --fuzz=0 --directory="$output_dir" -p1 < "$repo_dir/scripts/patches/frp-android-local-endpoint.patch"

printf 'frp source prepared: commit=%s path=%s\n' "$FRP_SOURCE_COMMIT" "$output_dir"
