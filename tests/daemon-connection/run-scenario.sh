#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"

builder_tag() {
  local libc="$1" thread_model="$2"
  case "$thread_model-$libc" in
    nts-musl) echo "make-php-8.4-musl" ;;
    nts-gnu)  echo "make-php-8.4-gnu" ;;
    zts-musl) echo "make-php-8.4-zts-musl" ;;
    zts-gnu)  echo "make-php-8.4-zts-gnu" ;;
    *) echo "unknown libc/thread_model: $libc/$thread_model" >&2; return 1 ;;
  esac
}

# Prints the absolute host path to a built .so matching the given libc and
# thread model, by inspecting the repo's own releases/ output tree (see
# make/release.mk: RELEASE_OS carries "-musl" for musl builds, and the
# ZTS suffix is appended unconditionally to the filename). Prints nothing
# if no matching file exists yet.
find_so() {
  local libc="$1" thread_model="$2"
  local -a filters=(-path '*/agent/*' -type f)
  if [ "$libc" = musl ]; then
    filters+=(-path '*/linux-musl/*')
  else
    filters+=(-not -path '*/linux-musl/*')
  fi
  if [ "$thread_model" = zts ]; then
    filters+=(-name '*-zts.so')
  else
    filters+=(-name 'newrelic-*.so' -not -name '*-zts.so')
  fi
  find "$REPO_ROOT/releases" "${filters[@]}" 2>/dev/null | head -1
}

# Builds one newrelic.so variant and stages it as
# artifacts/newrelic-<thread_model>-<libc>.so.
build_so() {
  local libc="$1" thread_model="$2"
  local tag; tag="$(builder_tag "$libc" "$thread_model")"
  echo "==> building newrelic.so (thread_model=$thread_model libc=$libc) via $tag"
  docker run --rm \
    -e PCRE_STATIC=yes \
    -v "$REPO_ROOT":/usr/local/src/newrelic-php-agent \
    "newrelic/nr-php-agent-builder:$tag" \
    sh -c 'cd /usr/local/src/newrelic-php-agent && make release-agent'

  local so_path; so_path="$(find_so "$libc" "$thread_model")"
  if [ -z "$so_path" ]; then
    echo "build_so: no .so found under releases/ for $thread_model/$libc after build" >&2
    return 1
  fi
  mkdir -p "$ARTIFACTS_DIR"
  cp -v "$so_path" "$ARTIFACTS_DIR/newrelic-$thread_model-$libc.so"
}

build_all_so() {
  build_so musl nts
  build_so gnu  nts
  build_so musl zts
  build_so gnu  zts
}

stage_daemon_musl() {
  echo "==> extracting musl newrelic-daemon binary from newrelic/php-daemon:latest"
  local cid
  cid="$(docker create newrelic/php-daemon:latest)"
  trap "docker rm -f '$cid' >/dev/null 2>&1 || true" EXIT
  docker cp "$cid:/usr/bin/newrelic-daemon" "$ARTIFACTS_DIR/newrelic-daemon-musl"
  chmod +x "$ARTIFACTS_DIR/newrelic-daemon-musl"
}

stage_daemon_gnu() {
  echo "==> building gnu newrelic-daemon binary from source via make-go-gnu"
  docker run --rm \
    --entrypoint /bin/bash \
    -v "$REPO_ROOT":/usr/local/src/newrelic-php-agent \
    newrelic/nr-php-agent-builder:make-go-gnu \
    -c 'cd /usr/local/src/newrelic-php-agent && make daemon'
  cp -v "$REPO_ROOT/bin/daemon" "$ARTIFACTS_DIR/newrelic-daemon-gnu"
  chmod +x "$ARTIFACTS_DIR/newrelic-daemon-gnu"
}

stage_daemon_binaries() {
  mkdir -p "$ARTIFACTS_DIR"
  stage_daemon_musl
  stage_daemon_gnu
}

main() {
  case "${1:-}" in
    build-so) build_all_so ;;
    stage-daemon) stage_daemon_binaries ;;
    *)
      echo "Usage: $0 build-so|stage-daemon" >&2
      exit 1
      ;;
  esac
}

main "$@"
