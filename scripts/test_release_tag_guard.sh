#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
checker="$repo_dir/scripts/check_release_tag_absent.sh"
work_dir="$(mktemp -d /tmp/frp-release-tag-guard-test.XXXXXX)"
trap 'rm -rf -- "$work_dir"' EXIT
remote="$work_dir/remote.git"

git init --bare --quiet "$remote"
"$checker" 9.8.7 "$remote" > "$work_dir/absent.log"
grep -Fq 'Release tag is available: v9.8.7' "$work_dir/absent.log"

object_id="$(printf 'release-tag-fixture' | git --git-dir="$remote" hash-object -t blob -w --stdin)"
git --git-dir="$remote" update-ref refs/tags/v9.8.7 "$object_id"
set +e
"$checker" 9.8.7 "$remote" > "$work_dir/present.log" 2>&1
present_status=$?
set -e
if (( present_status == 0 )); then
  printf 'Existing release tag was unexpectedly accepted\n' >&2
  exit 1
fi
grep -Fq 'Release tag already exists: v9.8.7' "$work_dir/present.log"

# A create-only ref update is the local equivalent of GitHub's create-ref API:
# a contender cannot move an already reserved tag. Verify both the failed
# second reservation and the exact target left behind by the first one.
other_object_id="$(printf 'competing-tag-fixture' | \
  git --git-dir="$remote" hash-object -t blob -w --stdin)"
zero_object_id="$(printf '0%.0s' {1..40})"
set +e
git --git-dir="$remote" update-ref \
  refs/tags/v9.8.7 "$other_object_id" "$zero_object_id" \
  > "$work_dir/atomic.log" 2>&1
atomic_status=$?
set -e
if (( atomic_status == 0 )); then
  printf 'A competing create-only tag update unexpectedly replaced the reserved ref\n' >&2
  exit 1
fi
actual_target="$(git ls-remote --exit-code --tags "$remote" refs/tags/v9.8.7 | \
  awk 'NF == 2 { print $1 }')"
if [[ "$actual_target" != "$object_id" || "$actual_target" == "$other_object_id" ]]; then
  printf 'Reserved release tag no longer points to its exact original object\n' >&2
  exit 1
fi

set +e
"$checker" 9.8.8 "$work_dir/missing.git" > "$work_dir/error.log" 2>&1
error_status=$?
set -e
if (( error_status == 0 )); then
  printf 'Unreachable release remote was unexpectedly accepted\n' >&2
  exit 1
fi
grep -Fq 'Unable to verify release tag v9.8.8' "$work_dir/error.log"

printf 'Release tag guard absence, atomic reservation, exact target, and error tests passed.\n'
