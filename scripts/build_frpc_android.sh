#!/usr/bin/env bash
set -Eeuo pipefail

readonly REQUIRED_GO_VERSION="go1.26.11"
# Keep frpc on its pinned patched toolchain without changing certificate builds.
export GOTOOLCHAIN="$REQUIRED_GO_VERSION"
readonly EXPECTED_FRPC_SHA256="b753f3e4e41b0a7a319666eb216808cf912dc969d8dd18c7b42ec7c090e0e292"

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
destination="$repo_dir/flutter_app/android/app/src/main/jniLibs/arm64-v8a/libfrpc.so"
mode="${1:---install}"

case "$mode" in
  --install|--check) ;;
  *)
    printf 'Usage: %s [--install|--check]\n' "$0" >&2
    exit 2
    ;;
esac

actual_go_version="$(go env GOVERSION)"
if [[ "$actual_go_version" != "$REQUIRED_GO_VERSION" ]]; then
  printf 'Go %s is required; found %s\n' "$REQUIRED_GO_VERSION" "$actual_go_version" >&2
  exit 1
fi

work_dir="$(mktemp -d /tmp/frpc-android-build.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT
source_dir="$work_dir/source"
"$repo_dir/scripts/prepare_frpc_source.sh" "$source_dir"

(
  cd "$source_dir"
  go mod download
  go mod verify
  CGO_ENABLED=0 GOOS=android GOARCH=arm64 \
    go build \
      -mod=readonly \
      -trimpath \
      -buildvcs=false \
      -tags 'frpc,noweb' \
      -ldflags='-s -w -buildid=' \
      -o "$work_dir/libfrpc.so" \
      ./cmd/frpc
)

printf '%s  %s\n' "$EXPECTED_FRPC_SHA256" "$work_dir/libfrpc.so" |
  sha256sum --check --strict
readelf -h "$work_dir/libfrpc.so" | grep -q 'Type:.*DYN (Position-Independent Executable file)'
readelf -h "$work_dir/libfrpc.so" | grep -q 'Machine:.*AArch64'
readelf -lW "$work_dir/libfrpc.so" | grep -q '/system/bin/linker64'
if readelf -lW "$work_dir/libfrpc.so" | grep -q 'GNU_STACK.*RWE'; then
  printf 'frpc has an executable stack\n' >&2
  exit 1
fi
go version -m "$work_dir/libfrpc.so" | grep -q '^.*go1\.26\.11$'

if [[ "$mode" == "--check" ]]; then
  if [[ ! -f "$destination" ]] || ! cmp -s "$work_dir/libfrpc.so" "$destination"; then
    printf 'Embedded libfrpc.so is missing or stale. Rebuild it with:\n  %s --install\n' "$0" >&2
    if [[ -f "$destination" ]]; then
      printf 'embedded: %s\n' "$(sha256sum "$destination" | cut -d' ' -f1)" >&2
    fi
    printf 'rebuilt:  %s\n' "$(sha256sum "$work_dir/libfrpc.so" | cut -d' ' -f1)" >&2
    exit 1
  fi
  printf 'libfrpc.so verified: %s\n' "$EXPECTED_FRPC_SHA256"
else
  mkdir -p "$(dirname -- "$destination")"
  install -m 0755 "$work_dir/libfrpc.so" "$destination"
  printf 'libfrpc.so installed: %s\n' "$EXPECTED_FRPC_SHA256"
fi
