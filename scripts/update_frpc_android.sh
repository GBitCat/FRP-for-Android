#!/usr/bin/env bash
set -Eeuo pipefail

readonly FRP_XUDP_VERSION="0.71.0-v2"
readonly FRP_ARCHIVE="frp_0.71.0_android_arm64.tar.gz"
readonly FRP_ARCHIVE_SHA256="c52b58e745f2ee86617fd8e1a8b54815eff13d394523173b24b2004e6e943c10"
readonly FRPC_SHA256="2255feb0991463816e7f17f5beae61d0ba006d700f991ff8758add70311e78f0"
readonly FRP_URL="https://github.com/GBitCat/frp-xudp/releases/download/v${FRP_XUDP_VERSION}/${FRP_ARCHIVE}"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d /tmp/frp-xudp-android.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT

curl --fail --location --retry 3 --output "$work_dir/$FRP_ARCHIVE" "$FRP_URL"
printf '%s  %s\n' "$FRP_ARCHIVE_SHA256" "$work_dir/$FRP_ARCHIVE" |
  sha256sum --check --strict
tar -xzf "$work_dir/$FRP_ARCHIVE" -C "$work_dir"

frpc_path="$(find "$work_dir" -type f -name frpc -print -quit)"
test -n "$frpc_path"
printf '%s  %s\n' "$FRPC_SHA256" "$frpc_path" | sha256sum --check --strict
readelf -h "$frpc_path" | grep -q 'Class:.*ELF64'
readelf -h "$frpc_path" | grep -q 'Machine:.*AArch64'

destination="$repo_dir/flutter_app/android/app/src/main/jniLibs/arm64-v8a/libfrpc.so"
install -m 0755 "$frpc_path" "$destination"

sha256sum "$destination"
