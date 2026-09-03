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
    filters+=(-path '*/linux/*')
  fi
  if [ "$thread_model" = zts ]; then
    filters+=(-name '*-zts.so')
  else
    filters+=(-name 'newrelic-*.so' -not -name '*-zts.so')
  fi
  local -a matches=()
  while IFS= read -r line; do
    [ -n "$line" ] && matches+=("$line")
  done < <(find "$REPO_ROOT/releases" "${filters[@]}" 2>/dev/null)
  if [ "${#matches[@]}" -gt 1 ]; then
    echo "find_so: ambiguous - multiple candidates for $thread_model/$libc:" >&2
    printf '  %s\n' "${matches[@]}" >&2
    return 1
  fi
  [ "${#matches[@]}" -eq 1 ] && echo "${matches[0]}"
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
  echo "WARNING: rebuilding the agent runs 'make clean' against this checkout's" >&2
  echo "agent/ directory and overwrites bin/daemon. Commit or stash any in-progress" >&2
  echo "local build state first if you need to keep it." >&2
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

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

# Clears anything a previous scenario run against this container might have
# left behind, so results never leak between runs. Killing a stale
# self-spawned daemon matters specifically for R7: the daemon's own
# collision guard (an exclusive pidfile lock — see
# daemon/internal/newrelic/pidfile.go) means a second spawn against an
# already-running daemon exits silently without updating the pidfile,
# which would otherwise look identical to "no spawn happened". Uses the
# daemon's own pidfile to find and kill it directly, rather than pkill -f
# (unavailable on gnu/Debian runtime images in this project — no procps).
reset_container_state() {
  local service="$1"
  compose exec -T "$service" sh -c '
    if [ -f /var/run/newrelic-daemon.pid ]; then
      kill "$(cat /var/run/newrelic-daemon.pid)" 2>/dev/null || true
    fi
    rm -f /tmp/newrelic-agent.log /tmp/newrelic-daemon.log /var/run/newrelic-daemon.pid
    rm -f /etc/newrelic/newrelic.cfg
    rm -f /usr/local/etc/php/conf.d/zz-daemon-port.ini
  ' || true
}

# R1/R2 need the agent to reach the external newrelic-daemon service
# instead of trying (or being allowed to try) a local one; this writes
# that one differing setting as its own conf.d file rather than baking it
# into newrelic.ini, so R7/R8's containers stay on the shared default.
set_external_daemon() {
  local service="$1"
  compose exec -T "$service" sh -c \
    'echo "newrelic.daemon.port = \"newrelic-daemon:31339\"" > /usr/local/etc/php/conf.d/zz-daemon-port.ini'
}

set_init_mode() {
  local service="$1"
  compose exec -T "$service" sh -c 'mkdir -p /etc/newrelic && touch /etc/newrelic/newrelic.cfg'
}

trigger_cli() {
  local service="$1"
  compose exec -T "$service" php /app/index.php
}

# Starts a detached server command, curls /app/sapi.php through it, then
# kills the server process. Captures the process's own PID (via a wrapper
# that backgrounds it and echoes $!) and kills that PID directly, rather
# than pattern-matching with pkill -f (unavailable on gnu/Debian runtime
# images in this project). $match is kept in the signature for call-site
# compatibility with later tasks but is no longer used for matching.
trigger_server() {
  local service="$1" match="$2"; shift 2
  compose exec -T "$service" sh -c 'rm -f /tmp/server.pid'
  compose exec -d "$service" sh -c '"$@" & echo $! > /tmp/server.pid' _ "$@"
  sleep 1
  compose exec -T "$service" \
    php -r '$c=@file_get_contents("http://localhost:8080/sapi.php"); echo $c;'
  compose exec -T "$service" sh -c 'test -f /tmp/server.pid && kill "$(cat /tmp/server.pid)" 2>/dev/null; rm -f /tmp/server.pid; true'
}

# R7: no external daemon service, agent spawns its own from the bundled
# binary. Verified via agent/php_minit.c:617-680 — the spawn happens only
# when NR_DAEMON_STARTUP_AGENT is in effect, i.e. no /etc/newrelic/newrelic.cfg
# and no blocking no_daemon_launch setting (both true by default here).
scenario_r7() {
  local libc="$1"
  local service="php-cli-$libc"

  reset_container_state "$service"

  # Precondition: no pidfile before triggering.
  if compose exec -T "$service" test -f /var/run/newrelic-daemon.pid; then
    echo "R7/$libc: FAIL - stale pidfile present before trigger" >&2
    return 1
  fi

  local out
  out="$(trigger_cli "$service")"
  if [ "$out" != "ok" ]; then
    echo "R7/$libc: FAIL - fixture script did not complete cleanly (got: $out)" >&2
    return 1
  fi

  if ! compose exec -T "$service" test -f /var/run/newrelic-daemon.pid; then
    echo "R7/$libc: FAIL - no pidfile after trigger; agent did not spawn a daemon" >&2
    return 1
  fi

  if compose exec -T "$service" grep -q 'failed to connect to the newrelic-daemon' /tmp/newrelic-agent.log 2>/dev/null; then
    echo "R7/$libc: FAIL - agent logged the INIT-mode failure warning; startup mode was not AGENT" >&2
    return 1
  fi

  echo "R7/$libc: PASS"
}

# R8: same container as R7, but /etc/newrelic/newrelic.cfg present forces
# NR_DAEMON_STARTUP_INIT (agent/php_minit.c:166-168) — the agent must not
# spawn, and must log the exact warning at agent/php_minit.c:682-688.
scenario_r8() {
  local libc="$1"
  local service="php-cli-$libc"

  reset_container_state "$service"
  set_init_mode "$service"

  trigger_cli "$service" >/dev/null || true  # a failed daemon connect is expected; script output isn't the point here

  if compose exec -T "$service" test -f /var/run/newrelic-daemon.pid; then
    echo "R8/$libc: FAIL - pidfile present; agent spawned a daemon despite INIT mode" >&2
    return 1
  fi

  if ! compose exec -T "$service" grep -q 'failed to connect to the newrelic-daemon' /tmp/newrelic-agent.log 2>/dev/null; then
    echo "R8/$libc: FAIL - expected INIT-mode failure warning not found in agent log" >&2
    return 1
  fi

  echo "R8/$libc: PASS"
}

# Shared by R1 and R2: after triggering a request against a container that
# should have connected to the external newrelic-daemon service, neither a
# local spawn nor a connect failure should have happened.
assert_connected_externally() {
  local label="$1" service="$2"
  if compose exec -T "$service" test -f /var/run/newrelic-daemon.pid; then
    echo "$label: FAIL - local pidfile present; agent spawned its own daemon instead of using the external one" >&2
    return 1
  fi
  if compose exec -T "$service" grep -q 'failed to connect to the newrelic-daemon' /tmp/newrelic-agent.log 2>/dev/null; then
    echo "$label: FAIL - INIT-mode failure warning present; connect to the external daemon did not succeed" >&2
    return 1
  fi
  if compose exec -T "$service" grep -q 'could not resolve daemon address' /tmp/newrelic-agent.log 2>/dev/null; then
    echo "$label: FAIL - DNS resolution of the external daemon address failed; agent disabled itself" >&2
    return 1
  fi
  if ! compose exec -T "$service" grep -q "attempt daemon connection via 'newrelic-daemon:31339'" /tmp/newrelic-agent.log 2>/dev/null; then
    echo "$label: FAIL - no evidence MINIT ran with the external-daemon override applied (agent log missing, or extension never loaded)" >&2
    return 1
  fi
}

# R1: php -S reports SAPI cli-server, so nr_php_process_will_fork() == true
# (agent/php_minit.c:441-474) while still hitting the Connected outcome.
# Known gap: does not assert the will_fork()-specific pre-fork daemon-connection-close behavior — see README's "Known gaps".
scenario_r1() {
  local libc="$1"
  local service="php-server-$libc"

  reset_container_state "$service"
  set_external_daemon "$service"

  local out
  out="$(trigger_server "$service" 'php -S' php -S 0.0.0.0:8080 -t /app)"
  if [ "$out" != "cli-server" ]; then
    echo "R1/$libc: FAIL - expected SAPI name cli-server, got: $out" >&2
    return 1
  fi

  assert_connected_externally "R1/$libc" "$service" || return 1
  echo "R1/$libc: PASS"
}

# R2: both php-cli (will_fork=false because sapi_module.name=="cli") and
# frankenphp (will_fork=false via the ZTS/is_frankenphp check) exercise the
# same Connected/will_fork=false cell of the matrix.
scenario_r2_cli() {
  local libc="$1"
  local service="php-cli-$libc"

  reset_container_state "$service"
  set_external_daemon "$service"

  local out
  out="$(trigger_cli "$service")"
  if [ "$out" != "ok" ]; then
    echo "R2-cli/$libc: FAIL - fixture script did not complete cleanly (got: $out)" >&2
    return 1
  fi

  assert_connected_externally "R2-cli/$libc" "$service" || return 1
  echo "R2-cli/$libc: PASS"
}

scenario_r2_frankenphp() {
  local libc="$1"
  local service="frankenphp-$libc"

  reset_container_state "$service"
  set_external_daemon "$service"

  local out
  out="$(trigger_server "$service" 'frankenphp php-server' frankenphp php-server --listen=:8080 --root=/app)"
  if [ "$out" != "frankenphp" ]; then
    echo "R2-frankenphp/$libc: FAIL - expected SAPI name frankenphp, got: $out" >&2
    return 1
  fi

  assert_connected_externally "R2-frankenphp/$libc" "$service" || return 1
  echo "R2-frankenphp/$libc: PASS"
}

scenario_r2() {
  local libc="$1"
  scenario_r2_cli "$libc"
  scenario_r2_frankenphp "$libc"
}

ensure_built() {
  if [ ! -f "$ARTIFACTS_DIR/newrelic-nts-musl.so" ] || \
     [ ! -f "$ARTIFACTS_DIR/newrelic-nts-gnu.so" ] || \
     [ ! -f "$ARTIFACTS_DIR/newrelic-zts-musl.so" ] || \
     [ ! -f "$ARTIFACTS_DIR/newrelic-zts-gnu.so" ]; then
    build_all_so
  fi
  if [ ! -f "$ARTIFACTS_DIR/newrelic-daemon-musl" ] || \
     [ ! -f "$ARTIFACTS_DIR/newrelic-daemon-gnu" ]; then
    stage_daemon_binaries
  fi
}

run_row() {
  local row="$1" libc="$2"
  case "$row" in
    r1) scenario_r1 "$libc" ;;
    r2) scenario_r2 "$libc" ;;
    r7) scenario_r7 "$libc" ;;
    r8) scenario_r8 "$libc" ;;
    *) echo "unknown row: $row (expected r1|r2|r7|r8)" >&2; return 1 ;;
  esac
}

main() {
  case "${1:-}" in
    build-so) build_all_so; return $? ;;
    stage-daemon) stage_daemon_binaries; return $? ;;
  esac

  local row="${1:-}" libc="${2:-}"
  if [ -z "$row" ] || [ -z "$libc" ]; then
    echo "Usage: $0 {r1|r2|r7|r8|all} {musl|gnu}" >&2
    echo "       $0 build-so" >&2
    echo "       $0 stage-daemon" >&2
    exit 1
  fi

  ensure_built
  compose up -d

  local failures=0
  if [ "$row" = all ]; then
    for r in r1 r2 r7 r8; do
      run_row "$r" "$libc" || failures=$((failures + 1))
    done
  else
    run_row "$row" "$libc" || failures=$((failures + 1))
  fi

  if [ "$failures" -eq 0 ]; then
    echo "=== all requested scenarios passed ==="
  else
    echo "=== $failures scenario(s) failed ===" >&2
  fi
  exit "$failures"
}

main "$@"
