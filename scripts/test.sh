#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir/flutter_app"
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
./android/gradlew -p android app:assembleDebugAndroidTest --no-daemon
