#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_file="${FRP_RELEASE_WORKFLOW_FILE:-$repo_dir/.github/workflows/release.yml}"
frpc_file="${FRP_EMBEDDED_FRPC_FILE:-$repo_dir/flutter_app/android/app/src/main/jniLibs/arm64-v8a/libfrpc.so}"
cert_engine_file="${FRP_EMBEDDED_CERT_ENGINE_FILE:-$repo_dir/flutter_app/android/app/src/main/jniLibs/arm64-v8a/libfrpc_cert.so}"

if (( $# != 0 )); then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi

if [[ ! -f "$workflow_file" ]]; then
  printf 'Release workflow not found: %s\n' "$workflow_file" >&2
  exit 1
fi

verify_pin() {
  local key="$1"
  local embedded_file="$2"
  local label="$3"
  local -a definitions
  local pinned
  local actual

  if [[ ! -f "$embedded_file" || -L "$embedded_file" ]]; then
    printf 'Embedded %s is missing or not a regular non-symlink file: %s\n' \
      "$label" "$embedded_file" >&2
    return 1
  fi

  mapfile -t definitions < <(
    grep -E "^[[:space:]]*${key}:[[:space:]]*" "$workflow_file" || true
  )
  if (( ${#definitions[@]} != 1 )); then
    printf 'Expected exactly one %s definition in %s; found %d\n' \
      "$key" "$workflow_file" "${#definitions[@]}" >&2
    return 1
  fi

  if [[ "${definitions[0]}" =~ ^[[:space:]]*${key}:[[:space:]]*([0-9a-f]{64})[[:space:]]*$ ]]; then
    pinned="${BASH_REMATCH[1]}"
  else
    printf '%s must be an unquoted 64-character lowercase SHA-256 value\n' \
      "$key" >&2
    return 1
  fi

  actual="$(sha256sum -- "$embedded_file" | awk '{ print $1 }')"
  if [[ "$actual" != "$pinned" ]]; then
    printf '%s release pin is stale\n  pinned:   %s\n  embedded: %s\n' \
      "$label" "$pinned" "$actual" >&2
    return 1
  fi
  printf '%s release pin verified: %s\n' "$label" "$actual"
}

verify_pin REQUIRED_FRPC_SHA256 "$frpc_file" libfrpc.so
verify_pin REQUIRED_CERT_ENGINE_SHA256 "$cert_engine_file" libfrpc_cert.so
