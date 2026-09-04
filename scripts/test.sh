#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir/native/frpc_cert"
if [[ -n "$(gofmt -l .)" ]]; then
  printf 'Go files are not formatted:\n' >&2
  gofmt -l . >&2
  exit 1
fi
go test -race ./...
go vet ./...
"$repo_dir/scripts/build_frpc_android.sh" --check
"$repo_dir/scripts/audit_go_vulnerabilities.sh"
"$repo_dir/scripts/build_frpc_cert_tool.sh"
"$repo_dir/scripts/build_frpc_cert_android.sh" --check
"$repo_dir/scripts/test_release_native_hashes.sh"
"$repo_dir/scripts/test_release_tag_guard.sh"
"$repo_dir/scripts/test_mtls_e2e.sh"
cd "$repo_dir/flutter_app"
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
./android/gradlew -p android app:lintDebug --no-daemon
./android/gradlew -p android app:assembleDebugAndroidTest --no-daemon
