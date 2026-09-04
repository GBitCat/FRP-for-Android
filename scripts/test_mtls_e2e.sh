#!/usr/bin/env bash
set -Eeuo pipefail

readonly REQUIRED_GO_VERSION="go1.26.8"

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d /tmp/frpc-mtls-e2e.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT

actual_go_version="$(go env GOVERSION)"
if [[ "$actual_go_version" != "$REQUIRED_GO_VERSION" ]]; then
  printf 'Go %s is required; found %s\n' "$REQUIRED_GO_VERSION" "$actual_go_version" >&2
  exit 1
fi

source_dir="$work_dir/frp-source"
bin_dir="$work_dir/bin"
mkdir -p "$bin_dir"
"$repo_dir/scripts/prepare_frpc_source.sh" "$source_dir"

(
  cd "$source_dir"
  go mod download
  go mod verify
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -mod=readonly -trimpath -buildvcs=false -tags=frps,noweb \
      -ldflags='-s -w -buildid=' -o "$bin_dir/frps" ./cmd/frps
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -mod=readonly -trimpath -buildvcs=false -tags=frpc,noweb \
      -ldflags='-s -w -buildid=' -o "$bin_dir/frpc" ./cmd/frpc
)

printf 'mTLS test frps: %s\n' "$(sha256sum "$bin_dir/frps" | cut -d' ' -f1)"
printf 'mTLS test frpc: %s\n' "$(sha256sum "$bin_dir/frpc" | cut -d' ' -f1)"

(
  cd "$repo_dir/native/frpc_cert"
  FRP_E2E_FRPS="$bin_dir/frps" \
    FRP_E2E_FRPC="$bin_dir/frpc" \
    go test -run '^TestRealFrpMutualTLS$' -count=1 -timeout=90s .
)
