#!/usr/bin/env bash
set -Eeuo pipefail

: "${ANDROID_SERIAL:?Set ANDROID_SERIAL to the approved Android 15/16 device}"

api="$(adb -s "$ANDROID_SERIAL" shell getprop ro.build.version.sdk | tr -d '\r')"
if [[ "$api" != "35" && "$api" != "36" ]]; then
  printf 'Refusing lifecycle certification: %s is API %s, expected 35 or 36.\n' \
    "$ANDROID_SERIAL" "$api" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/../android"
./gradlew :app:connectedDebugAndroidTest --no-daemon
