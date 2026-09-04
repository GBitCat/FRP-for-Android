#!/usr/bin/env bash
set -Eeuo pipefail

readonly FRP_SOURCE_COMMIT="305ab02e14034d4152dd6780d9879718e96ad4f5"
readonly FRP_SOURCE_ARCHIVE_SHA256="e658accc2ab0f239b12b3a7528c49d12efcb0377789ce3e7eb1f50c40225d16a"
readonly FRP_SOURCE_URL="https://github.com/GBitCat/frp-xudp/archive/${FRP_SOURCE_COMMIT}.tar.gz"

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
patch_file="$repo_dir/scripts/patches/frp-xudp-v0.71.0-v2-go-security.patch"

if (( $# != 1 )); then
  printf 'Usage: %s OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi

output_dir="$1"
if [[ -e "$output_dir" ]]; then
  printf 'Output path already exists: %s\n' "$output_dir" >&2
  exit 1
fi

archive_dir="$(mktemp -d /tmp/frpc-source-archive.XXXXXX)"
trap 'rm -rf -- "$archive_dir"' EXIT
archive="$archive_dir/frp-xudp.tar.gz"

curl --fail --silent --show-error --location --retry 3 \
  --output "$archive" "$FRP_SOURCE_URL"
printf '%s  %s\n' "$FRP_SOURCE_ARCHIVE_SHA256" "$archive" |
  sha256sum --check --strict

mkdir -p "$output_dir"
tar --extract --gzip --file "$archive" --directory "$output_dir" \
  --strip-components=1 --no-same-owner --no-same-permissions

git -C "$output_dir" apply --unidiff-zero --check "$patch_file"
git -C "$output_dir" apply --unidiff-zero "$patch_file"

printf 'frp source prepared: commit=%s path=%s\n' "$FRP_SOURCE_COMMIT" "$output_dir"
