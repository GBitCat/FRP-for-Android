#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_dir/scripts/check_release_native_hashes.sh"
frpc_file="$repo_dir/flutter_app/android/app/src/main/jniLibs/arm64-v8a/libfrpc.so"
cert_engine_file="$repo_dir/flutter_app/android/app/src/main/jniLibs/arm64-v8a/libfrpc_cert.so"
work_dir="$(mktemp -d /tmp/frp-release-native-hash-test.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT

# First enforce the real repository wiring. The fixture checks below prove
# both the acceptance and rejection paths independently of the pinned values.
"$checker"

frpc_hash="$(sha256sum -- "$frpc_file" | awk '{ print $1 }')"
cert_engine_hash="$(sha256sum -- "$cert_engine_file" | awk '{ print $1 }')"
fixture="$work_dir/release.yml"

printf 'env:\n  REQUIRED_FRPC_SHA256: %s\n  REQUIRED_CERT_ENGINE_SHA256: %s\n' \
  "$frpc_hash" "$cert_engine_hash" > "$fixture"

FRP_RELEASE_WORKFLOW_FILE="$fixture" \
FRP_EMBEDDED_FRPC_FILE="$frpc_file" \
FRP_EMBEDDED_CERT_ENGINE_FILE="$cert_engine_file" \
  "$checker" > "$work_dir/positive.log"

stale_hash="$(printf '0%.0s' {1..64})"
sed -i \
  "s/REQUIRED_CERT_ENGINE_SHA256: [0-9a-f]\{64\}/REQUIRED_CERT_ENGINE_SHA256: $stale_hash/" \
  "$fixture"
set +e
FRP_RELEASE_WORKFLOW_FILE="$fixture" \
FRP_EMBEDDED_FRPC_FILE="$frpc_file" \
FRP_EMBEDDED_CERT_ENGINE_FILE="$cert_engine_file" \
  "$checker" > "$work_dir/negative.log" 2>&1
negative_status=$?
set -e
if (( negative_status == 0 )); then
  printf 'Stale release pin was unexpectedly accepted\n' >&2
  exit 1
fi
grep -Fq 'libfrpc_cert.so release pin is stale' "$work_dir/negative.log"

printf 'Release native hash guard positive and negative tests passed.\n'
