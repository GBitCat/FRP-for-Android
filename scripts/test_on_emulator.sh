#!/usr/bin/env bash
set -Eeuo pipefail

readonly adb_target="${ADB_TARGET:-10.0.0.1:16512}"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir/flutter_app"
flutter build apk --debug --target-platform android-arm64
./android/gradlew -p android app:assembleDebugAndroidTest --no-daemon
adb connect "$adb_target"
adb -s "$adb_target" install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s "$adb_target" install -r \
  build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
instrumentation_log="$(mktemp)"
trap 'rm -f -- "$instrumentation_log"' EXIT
adb -s "$adb_target" shell am instrument -w -r \
  com.frp.frp_app.debug.test/androidx.test.runner.AndroidJUnitRunner | tee "$instrumentation_log"
awk -f "$repo_dir/scripts/check_instrumentation.awk" "$instrumentation_log"
