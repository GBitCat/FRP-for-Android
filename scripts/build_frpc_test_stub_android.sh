#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="$repo_dir/native/frpc_test_stub/main.c"
output_dir="$repo_dir/flutter_app/build/frpc-test-stub/x86_64"
output_file="$output_dir/libfrpc.so"
android_api_level="${FRP_TEST_STUB_ANDROID_API_LEVEL:-21}"
ndk_root="${FRP_ANDROID_NDK_HOME:-${ANDROID_HOME:?ANDROID_HOME is required}/ndk/28.2.13676358}"
compiler="$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android${android_api_level}-clang"

if [[ ! -x "$compiler" ]]; then
  printf 'Android NDK compiler not found: %s\n' "$compiler" >&2
  exit 1
fi

mkdir -p "$output_dir"
"$compiler" \
  -fPIE \
  -pie \
  -Oz \
  -Wl,--build-id=none \
  -Wl,--gc-sections \
  -o "$output_file" \
  "$source_file"
chmod 0755 "$output_file"

readelf -h "$output_file" | grep -q 'Machine:.*Advanced Micro Devices X86-64'
readelf -h "$output_file" | grep -q 'Type:.*DYN (Position-Independent Executable file)'
readelf -lW "$output_file" | grep -q ' INTERP '
printf 'instrumentation frpc fixture: %s\n' "$(sha256sum "$output_file" | cut -d' ' -f1)"
