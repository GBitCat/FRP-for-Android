#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
git -C "$repo_root" config core.hooksPath .githooks
echo 'Installed repository hooks from .githooks.'
