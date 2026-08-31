#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:---tracked}"
case "$mode" in
  --staged|--tracked|--worktree|--history) ;;
  *)
    echo "Usage: $0 [--staged|--tracked|--worktree|--history]" >&2
    exit 2
    ;;
esac

declare -a blocked_paths=()

is_blocked_path() {
  local path="$1"
  local lower="${path,,}"
  local base="${lower##*/}"

  case "/$lower/" in
    */.release-signing-backup/*) return 0 ;;
  esac
  case "$base" in
    *.keystore|*.jks|*.ks|*.p12|*.pfx|*.pem|*.key|*.pk8|*.frpbackup|local.properties|google-services.json)
      return 0
      ;;
    .env|.env.*)
      [[ "$base" == ".env.example" ]] || return 0
      ;;
    *backup*.zip|*password*.txt|screenshot*.png)
      return 0
      ;;
  esac
  return 1
}

check_path() {
  local path="$1"
  [[ -n "$path" ]] || return 0
  if is_blocked_path "$path"; then
    blocked_paths+=("$path")
  fi
}

if [[ "$mode" == "--staged" ]]; then
  while IFS= read -r -d '' path; do
    check_path "$path"
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)
elif [[ "$mode" == "--tracked" ]]; then
  while IFS= read -r -d '' path; do
    check_path "$path"
  done < <(git ls-files -z)
elif [[ "$mode" == "--worktree" ]]; then
  while IFS= read -r -d '' path; do
    path="${path#./}"
    # Android/Flutter generates this SDK-location file locally. It is ignored,
    # never part of a build context, and contains no release credentials.
    [[ "$path" == "flutter_app/android/local.properties" ]] && continue
    check_path "$path"
  done < <(find . -path './.git' -prune -o -type f -print0)
else
  while IFS= read -r line; do
    check_path "$line"
  done < <(git log --all --format= --name-only --diff-filter=ACMR | sed '/^$/d' | sort -u)

  if git log --all --format='%ae%n%ce' | grep -Eiq '@GBitCat\.local$'; then
    echo 'Blocked local-only commit email found in repository history.' >&2
    exit 1
  fi
  if [[ -n "$(git log --all --format='%H' \
    -G '(storePassword|keyPassword|keyAlias)[[:space:]]*=[[:space:]]*"' \
    -- flutter_app/android/app/build.gradle.kts)" ]]; then
    echo 'Blocked literal Android signing assignment found in repository history.' >&2
    exit 1
  fi
fi

if (( ${#blocked_paths[@]} > 0 )); then
  echo "Blocked sensitive filename(s):" >&2
  printf '  %s\n' "${blocked_paths[@]}" >&2
  echo 'Keep signing material, local credentials, backups, and screenshots outside the repository.' >&2
  exit 1
fi

echo "Sensitive filename check passed ($mode)."
