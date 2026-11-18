#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_apk="$repo_dir/flutter_app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk"
test -f "$test_apk"
work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT

# The protected signing runner has no checkout. Exercise its actual inline
# policy here with the instrumentation APK and a short-lived, unrelated key.
policy="$work_dir/verify.sh"
awk '
  /# BEGIN signed APK verification/ { starts++; active = 1; next }
  /# END signed APK verification/ { ends++; active = 0; next }
  active { print; lines++ }
  END { if (starts != 1 || ends != 1 || active || !lines) exit 1 }
' "$repo_dir/.github/workflows/release.yml" > "$policy"

export RUNNER_TEMP="$work_dir"
export apksigner="${ANDROID_HOME:?}/build-tools/37.0.0/apksigner"
export output_apk="$work_dir/signed-test.apk"
fixture_key="$work_dir/fixture.p12"
keytool -genkeypair -alias fixture -keyalg RSA -keysize 2048 -validity 1 \
  -dname CN=Temporary -storetype PKCS12 -keystore "$fixture_key" \
  -storepass changeit -keypass changeit >/dev/null
expected_current="$(keytool -exportcert -keystore "$fixture_key" -alias fixture \
  -storepass changeit | sha256sum | cut -d' ' -f1)"
export expected_current

sign_fixture() {
  "$apksigner" sign --ks "$fixture_key" --ks-pass pass:changeit \
    --min-sdk-version 28 --v1-signing-enabled false --v4-signing-enabled false \
    "$@" --out "$output_apk" "$test_apk"
}

sign_fixture --v2-signing-enabled false --v3-signing-enabled true
bash -euo pipefail "$policy" >/dev/null
printf -v wrong_fingerprint '%064d' 0
if expected_current="$wrong_fingerprint" bash -euo pipefail "$policy" >/dev/null; then
  echo 'Unexpectedly accepted a certificate with a different fingerprint' >&2
  exit 1
fi

sign_fixture --v2-signing-enabled true --v3-signing-enabled false
if bash -euo pipefail "$policy" >/dev/null; then
  echo 'Unexpectedly accepted a v2-only signature' >&2
  exit 1
fi
echo 'Release signer guard accepted the v3 test certificate and rejected the wrong fingerprint and scheme.'
