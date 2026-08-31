#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
local_uid="${LOCAL_UID:-$(id -u)}"
local_gid="${LOCAL_GID:-$(id -g)}"
dev_image="${DEV_IMAGE:-frp-for-android-dev:ubuntu-26.04}"
proxy_url="${HTTP_PROXY:-http://127.0.0.1:8118}"
no_proxy_value="${NO_PROXY:+$NO_PROXY,}localhost,127.0.0.1,10.0.0.1"
gradle_proxy_host="${GRADLE_PROXY_HOST:-127.0.0.1}"
gradle_proxy_port="${GRADLE_PROXY_PORT:-8118}"
gradle_options="${GRADLE_OPTS:--Dorg.gradle.wrapper.networkTimeout=120000 -Dhttps.proxyHost=$gradle_proxy_host -Dhttps.proxyPort=$gradle_proxy_port -Dhttp.proxyHost=$gradle_proxy_host -Dhttp.proxyPort=$gradle_proxy_port}"

cache_volumes=(
  frpc-android-pub-cache
  frpc-android-gradle-cache
  frpc-android-dev-home
)
for volume in "${cache_volumes[@]}"; do
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    docker volume create "$volume" >/dev/null
  fi
done

if ! docker image inspect "$dev_image" >/dev/null 2>&1; then
  docker build --network host \
    --build-arg HTTP_PROXY="$proxy_url" \
    --build-arg HTTPS_PROXY="$proxy_url" \
    --build-arg NO_PROXY="$no_proxy_value" \
    -t "$dev_image" \
    "$project_dir"
fi

docker run --rm \
  -v frpc-android-pub-cache:/cache/pub \
  -v frpc-android-gradle-cache:/cache/gradle \
  -v frpc-android-dev-home:/cache/home \
  "$dev_image" \
  chown -R "$local_uid:$local_gid" /cache/pub /cache/gradle /cache/home

if (( $# == 0 )); then
  set -- bash
fi

exec docker run --rm --network host --init \
  --user "$local_uid:$local_gid" \
  -e HOME=/cache/home \
  -e ANDROID_USER_HOME=/cache/home/.android \
  -e PUB_CACHE=/cache/pub \
  -e GRADLE_USER_HOME=/cache/gradle \
  -e HTTP_PROXY="$proxy_url" \
  -e HTTPS_PROXY="$proxy_url" \
  -e http_proxy="$proxy_url" \
  -e https_proxy="$proxy_url" \
  -e NO_PROXY="$no_proxy_value" \
  -e no_proxy="$no_proxy_value" \
  -e GRADLE_OPTS="$gradle_options" \
  -v "$project_dir:/workspace" \
  -v frpc-android-pub-cache:/cache/pub \
  -v frpc-android-gradle-cache:/cache/gradle \
  -v frpc-android-dev-home:/cache/home \
  -w /workspace/flutter_app \
  "$dev_image" "$@"
