#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$repo_dir/scripts/build_frpc_android.sh" --check
"$repo_dir/scripts/build_frpc_cert_android.sh" --check
cd "$repo_dir/flutter_app"
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug --target-platform android-arm64
printf 'APK: %s\n' "$repo_dir/flutter_app/build/app/outputs/flutter-apk/app-debug.apk"
