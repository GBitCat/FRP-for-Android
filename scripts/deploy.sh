#!/usr/bin/env bash
set -Eeuo pipefail

readonly adb_target="${ADB_TARGET:-10.0.0.1:16512}"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$repo_dir/scripts/build.sh"
adb connect "$adb_target"
adb -s "$adb_target" install -r \
  "$repo_dir/flutter_app/build/app/outputs/flutter-apk/app-debug.apk"
adb -s "$adb_target" shell am start -n \
  com.frp.frp_app.debug/com.frp.frp_app.MainActivity
