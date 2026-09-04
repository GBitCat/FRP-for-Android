#!/usr/bin/env bash
set -Eeuo pipefail

readonly REQUIRED_GO_VERSION="go1.26.8"

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$repo_dir/native/frpc_cert"
output_dir="$repo_dir/flutter_app/android/app/src/main/jniLibs/arm64-v8a"
output_file="$output_dir/libfrpc_cert.so"
android_api_level="${FRP_CERT_ANDROID_API_LEVEL:-21}"
ndk_root="${ANDROID_NDK_HOME:-${ANDROID_HOME:?ANDROID_HOME is required}/ndk/28.2.13676358}"
compiler="$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${android_api_level}-clang"
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

if [[ ! -x "$compiler" ]]; then
  printf 'Android NDK compiler not found: %s\n' "$compiler" >&2
  exit 1
fi

work_dir="$(mktemp -d /tmp/frpc-cert-android-build.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT

(
  cd "$source_dir"
  go mod download
  go mod verify
  CGO_ENABLED=1 \
    GOOS=android \
    GOARCH=arm64 \
    CC="$compiler" \
    go build \
      -mod=readonly \
      -trimpath \
      -buildvcs=false \
      -buildmode=c-shared \
      -ldflags='-s -w -buildid=' \
      -o "$work_dir/libfrpc_cert.so" \
      .
)

readelf -h "$work_dir/libfrpc_cert.so" | grep -q 'Type:.*DYN (Shared object file)'
if readelf -lW "$work_dir/libfrpc_cert.so" | grep -q ' INTERP '; then
  printf 'Certificate engine unexpectedly contains a program interpreter\n' >&2
  exit 1
fi
for symbol in FrpCertAbiVersion FrpCertInvoke FrpCertFree; do
  nm -D --defined-only "$work_dir/libfrpc_cert.so" | grep -q " T $symbol$"
done
if ! readelf -lW "$work_dir/libfrpc_cert.so" \
    | awk '$1 == "LOAD" && $NF != "0x4000" { exit 1 }'; then
  printf 'Certificate engine does not use 16 KiB ELF segment alignment\n' >&2
  exit 1
fi

if [[ "$mode" == "--check" ]]; then
  if [[ ! -f "$output_file" ]] || ! cmp -s "$work_dir/libfrpc_cert.so" "$output_file"; then
    printf 'Committed libfrpc_cert.so is missing or stale. Rebuild it with:\n  %s --install\n' "$0" >&2
    if [[ -f "$output_file" ]]; then
      printf 'committed: %s\n' "$(sha256sum "$output_file" | cut -d' ' -f1)" >&2
    fi
    printf 'rebuilt:   %s\n' "$(sha256sum "$work_dir/libfrpc_cert.so" | cut -d' ' -f1)" >&2
    exit 1
  fi
  printf 'libfrpc_cert.so verified: %s\n' "$(sha256sum "$output_file" | cut -d' ' -f1)"
else
  mkdir -p "$output_dir"
  install -m 0755 "$work_dir/libfrpc_cert.so" "$output_file"
  printf 'libfrpc_cert.so: %s\n' "$(sha256sum "$output_file" | cut -d' ' -f1)"
fi
