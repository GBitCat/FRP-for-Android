#!/usr/bin/env bash
set -Eeuo pipefail

exec "$(dirname -- "${BASH_SOURCE[0]}")/run_android_lifecycle_tests.sh" "$@"
