#!/usr/bin/env bash
set -Eeuo pipefail

readonly REQUIRED_GO_VERSION="go1.26.8"

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$repo_dir/native/frpc_cert"
output_dir="$repo_dir/build/tools/linux-amd64"
work_dir="$(mktemp -d /tmp/frpc-cert-tool-build.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT

actual_go_version="$(go env GOVERSION)"
if [[ "$actual_go_version" != "$REQUIRED_GO_VERSION" ]]; then
  printf 'Go %s is required; found %s\n' "$REQUIRED_GO_VERSION" "$actual_go_version" >&2
  exit 1
fi

(
  cd "$source_dir"
  go mod download
  go mod verify
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
      -mod=readonly \
      -trimpath \
      -buildvcs=false \
      -ldflags='-s -w -buildid=' \
      -o "$work_dir/frpc-cert-tool" \
      ./cmd/frpc-cert-tool
)

mkdir -p "$output_dir"
install -m 0755 "$work_dir/frpc-cert-tool" "$output_dir/frpc-cert-tool"
printf 'frpc-cert-tool: %s\n' "$(sha256sum "$output_dir/frpc-cert-tool" | cut -d' ' -f1)"
