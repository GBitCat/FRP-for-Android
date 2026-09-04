#!/usr/bin/env bash
set -Eeuo pipefail

readonly REQUIRED_GO_VERSION="go1.26.8"
readonly GOVULNCHECK_VERSION="v1.7.0"

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
actual_go_version="$(go env GOVERSION)"
if [[ "$actual_go_version" != "$REQUIRED_GO_VERSION" ]]; then
  printf 'Go %s is required; found %s\n' "$REQUIRED_GO_VERSION" "$actual_go_version" >&2
  exit 1
fi

work_dir="$(mktemp -d /tmp/frpc-go-vulnerability-audit.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT
tool_dir="$work_dir/bin"
source_dir="$work_dir/frp-source"
mkdir -p "$tool_dir"

GOBIN="$tool_dir" go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"
govulncheck="$tool_dir/govulncheck"

(
  cd "$repo_dir/native/frpc_cert"
  go mod download
  go mod verify
  "$govulncheck" -show verbose ./...
)

"$repo_dir/scripts/prepare_frpc_source.sh" "$source_dir"
(
  cd "$source_dir"
  go mod download
  go mod verify
  CGO_ENABLED=0 GOOS=android GOARCH=arm64 \
    "$govulncheck" -show verbose -tags 'frpc,noweb' ./cmd/frpc
)

binary_report="$work_dir/frpc-binary-vulnerabilities.txt"
set +e
"$govulncheck" -mode binary \
  "$repo_dir/flutter_app/android/app/src/main/jniLibs/arm64-v8a/libfrpc.so" \
  >"$binary_report" 2>&1
binary_status=$?
set -e
sed -n '1,240p' "$binary_report"

if (( binary_status != 0 )); then
  vulnerability_ids="$(
    grep -Eo 'GO-[0-9]{4}-[0-9]+' "$binary_report" | sort -u | paste -sd, -
  )"
  if [[ "$binary_status" == "3" && "$vulnerability_ids" == "GO-2026-5932" ]] &&
    ! (
      cd "$source_dir"
      CGO_ENABLED=0 GOOS=android GOARCH=arm64 \
        go list -deps -tags 'frpc,noweb' ./cmd/frpc |
        grep -Fxq 'golang.org/x/crypto/openpgp'
    ); then
    printf '%s\n' \
      'Binary-only GO-2026-5932 match accepted: the exact Android source dependency graph does not include openpgp.'
  else
    exit "$binary_status"
  fi
fi
