# Daemon Connection Docker Compose Project Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained docker-compose project under `tests/daemon-connection/` that exercises rows R1/R2/R7/R8 of the agent/daemon connection-lifecycle matrix, across both musl and glibc builds, for `php-cli`, `php-server` (PHP's built-in server), and `frankenphp`.

**Architecture:** Seven long-lived, idle (`tail -f /dev/null`) Compose services — one external `newrelic-daemon` plus a musl/glibc pair each for `php-cli`, `php-server`, `frankenphp` — each with the correct pre-built `newrelic.so` and (for self-spawn scenarios) daemon binary bind-mounted in. A single script, `run-scenario.sh`, builds the artifacts once, then drives each scenario by `docker compose exec`-ing the actual PHP invocation into the right idle container and asserting on log content, pidfile state, and process exit codes — never on a fabricated log string. This is infrastructure/integration work, not unit-testable business logic, so "write the test first" here means: write the exact verification command for a task's deliverable, confirm it fails or errors against the not-yet-built state, then build until it passes.

**Tech Stack:** Docker Compose v2, bash, existing `newrelic/nr-php-agent-builder`/`newrelic/php-daemon`/official `php`/`dunglas/frankenphp` images, this repo's own `make release-agent`/`make daemon` targets.

**Spec:** `docs/superpowers/specs/2026-09-01-daemon-connection-docker-compose-design.md`

## Global Constraints

- Target PHP version: **8.4** for every image/tag in this project.
- In-scope rows: **R1, R2, R7, R8 only**. Do not implement R3–R6 or O1–O3 (see spec's "Explicitly out of scope").
- Every SAPI lane (`php-cli`, `php-server`, `frankenphp`) runs under **both** musl and glibc. The `newrelic-daemon` service is **singular and musl-only** — never duplicated per libc.
- **No custom Dockerfiles anywhere in this project.** Every image is an existing published tag; artifacts are built via `docker run`/`docker compose run` against those tags and bind-mounted into runtime containers.
- Project root: `tests/daemon-connection/`. Do not modify the root `docker-compose.yaml` or `files/Dockerfile`.
- Tooling is a single shell script, `run-scenario.sh` — no new language or test framework dependency.
- All image tags below are already confirmed to exist and behave as described (pulled/inspected during design — see spec). Do not re-litigate them; if one is unreachable at implementation time, that's an environment/auth problem to fix, not a design question to reopen.

---

## File Structure

```
tests/daemon-connection/
  compose.yaml              # 7 services, no build: stanzas
  newrelic.ini               # static ini snippet, mounted into every SAPI container
  fixtures/
    index.php                # trivial script all lanes execute
  artifacts/                  # build output, gitignored
    .gitkeep
  .gitignore                  # ignores everything in artifacts/ except .gitkeep
  run-scenario.sh             # build + compose + scenario dispatch + assertions
```

---

### Task 1: Scaffold the project and the `newrelic-daemon` service

**Files:**
- Create: `tests/daemon-connection/compose.yaml`
- Create: `tests/daemon-connection/.gitignore`
- Create: `tests/daemon-connection/artifacts/.gitkeep`

**Interfaces:**
- Produces: a `compose.yaml` with one service, `newrelic-daemon`, reachable at `newrelic-daemon:31339` from any other service on the same Compose network. All later tasks append services to this same file.

- [ ] **Step 1: Create the directory and a compose file with just the daemon service**

```bash
mkdir -p tests/daemon-connection/artifacts tests/daemon-connection/fixtures
touch tests/daemon-connection/artifacts/.gitkeep
```

Write `tests/daemon-connection/compose.yaml`:

```yaml
services:
  newrelic-daemon:
    image: newrelic/php-daemon:latest
    hostname: newrelic-daemon
```

Write `tests/daemon-connection/.gitignore`:

```
artifacts/*
!artifacts/.gitkeep
```

- [ ] **Step 2: Verify the compose file is syntactically valid**

Run: `docker compose -f tests/daemon-connection/compose.yaml config --quiet`
Expected: exits 0, no output.

- [ ] **Step 3: Verify the daemon service actually starts and listens**

Run:
```bash
docker compose -f tests/daemon-connection/compose.yaml up -d newrelic-daemon
sleep 2
docker compose -f tests/daemon-connection/compose.yaml exec -T newrelic-daemon \
  sh -c 'php_pid=$(pgrep newrelic-daemon) && echo "daemon running as pid $php_pid"'
docker compose -f tests/daemon-connection/compose.yaml logs newrelic-daemon
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected: `daemon running as pid <N>` is printed, and the logs show the daemon's own startup banner (no fatal errors). `down` exits 0.

- [ ] **Step 4: Commit**

```bash
git add tests/daemon-connection/compose.yaml tests/daemon-connection/.gitignore tests/daemon-connection/artifacts/.gitkeep
git commit -m "Scaffold tests/daemon-connection with the newrelic-daemon service"
```

---

### Task 2: Build the four `newrelic.so` ABI variants

**Files:**
- Create: `tests/daemon-connection/run-scenario.sh`

**Interfaces:**
- Produces: a `find_so()` bash function — `find_so <musl|gnu> <nts|zts>` → prints the absolute host path to the matching built `.so`, or nothing if not yet built. A `build_so()` function — `build_so <musl|gnu> <nts|zts>` → runs the matching builder image against the bind-mounted repo, leaves the artifact under the repo's own `releases/` tree, then copies it into `tests/daemon-connection/artifacts/newrelic-<nts|zts>-<musl|gnu>.so`. A `build_all_so()` function that calls `build_so` for all four combinations.
- Consumes: nothing from other tasks (this is the first script content).

- [ ] **Step 1: Write `run-scenario.sh` with the build functions and a `build-so` CLI subcommand for testing this task in isolation**

```bash
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

main() {
  case "${1:-}" in
    build-so) build_all_so ;;
    *)
      echo "Usage: $0 build-so" >&2
      exit 1
      ;;
  esac
}

main "$@"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tests/daemon-connection/run-scenario.sh
```

- [ ] **Step 3: Verify it fails cleanly before any build has run**

Run: `tests/daemon-connection/run-scenario.sh build-so 2>&1 | tail -5` after temporarily renaming `releases/` out of the way is unnecessary — on a clean checkout `releases/` won't exist yet, so `find_so` correctly prints nothing and each `build_so` call proceeds to actually build. This step is really about confirming the *build* runs, since there's no meaningful "should fail first" state for a build script — proceed directly to Step 4.

- [ ] **Step 4: Run the real build and verify all four artifacts land correctly**

Run: `tests/daemon-connection/run-scenario.sh build-so`
Expected: four `docker run` invocations complete without error, and:

```bash
ls -la tests/daemon-connection/artifacts/
file tests/daemon-connection/artifacts/*.so
```

Expected: `newrelic-nts-musl.so`, `newrelic-nts-gnu.so`, `newrelic-zts-musl.so`, `newrelic-zts-gnu.so` all present, each a non-empty `ELF 64-bit ... shared object`.

- [ ] **Step 5: Commit**

```bash
git add tests/daemon-connection/run-scenario.sh
git commit -m "Add the four-variant newrelic.so build step to run-scenario.sh"
```

---

### Task 3: Stage the daemon binaries for R7/R8 self-spawn

**Files:**
- Modify: `tests/daemon-connection/run-scenario.sh`

**Interfaces:**
- Produces: `stage_daemon_binaries()` — extracts `newrelic-daemon` (musl) from `newrelic/php-daemon:latest` and builds `newrelic-daemon` (gnu) from source, leaving both at `artifacts/newrelic-daemon-musl` and `artifacts/newrelic-daemon-gnu`, both `chmod +x`.
- Consumes: `$ARTIFACTS_DIR`, `$REPO_ROOT` (Task 2).

- [ ] **Step 1: Add the staging function and a `stage-daemon` CLI subcommand**

Insert after `build_all_so()` in `tests/daemon-connection/run-scenario.sh`:

```bash
stage_daemon_musl() {
  echo "==> extracting musl newrelic-daemon binary from newrelic/php-daemon:latest"
  local cid
  cid="$(docker create newrelic/php-daemon:latest)"
  docker cp "$cid:/usr/bin/newrelic-daemon" "$ARTIFACTS_DIR/newrelic-daemon-musl"
  docker rm "$cid" >/dev/null
  chmod +x "$ARTIFACTS_DIR/newrelic-daemon-musl"
}

stage_daemon_gnu() {
  echo "==> building gnu newrelic-daemon binary from source via make-go-gnu"
  docker run --rm \
    -v "$REPO_ROOT":/usr/local/src/newrelic-php-agent \
    newrelic/nr-php-agent-builder:make-go-gnu \
    sh -c 'cd /usr/local/src/newrelic-php-agent && make daemon'
  cp -v "$REPO_ROOT/bin/daemon" "$ARTIFACTS_DIR/newrelic-daemon-gnu"
  chmod +x "$ARTIFACTS_DIR/newrelic-daemon-gnu"
}

stage_daemon_binaries() {
  mkdir -p "$ARTIFACTS_DIR"
  stage_daemon_musl
  stage_daemon_gnu
}
```

Add the dispatch case to `main()`:

```bash
    stage-daemon) stage_daemon_binaries ;;
```

- [ ] **Step 2: Run it and verify both binaries are correctly linked for their target libc**

Run: `tests/daemon-connection/run-scenario.sh stage-daemon`

Then:
```bash
file tests/daemon-connection/artifacts/newrelic-daemon-musl
file tests/daemon-connection/artifacts/newrelic-daemon-gnu
```
Expected: the `musl` binary reports `interpreter /lib/ld-musl-*.so.1`; the `gnu` binary reports `interpreter /lib64/ld-linux-x86-64.so.2` (or the equivalent glibc interpreter for the host architecture) — i.e., the two must show **different** interpreters. If they show the same interpreter, the build targeted the wrong libc and must be fixed before continuing.

- [ ] **Step 3: Commit**

```bash
git add tests/daemon-connection/run-scenario.sh
git commit -m "Stage musl (prebuilt) and gnu (from-source) daemon binaries"
```

---

### Task 4: `php-cli-musl` / `php-cli-gnu` services

**Files:**
- Modify: `tests/daemon-connection/compose.yaml`
- Create: `tests/daemon-connection/newrelic.ini`
- Create: `tests/daemon-connection/fixtures/index.php`

**Interfaces:**
- Produces: two compose services, `php-cli-musl` and `php-cli-gnu`, both idle (`tail -f /dev/null`), each with the NTS `.so` for its libc, both daemon binaries' matching-libc copy, `newrelic.ini`, and `fixtures/` mounted in.

- [ ] **Step 1: Write the static ini snippet**

`tests/daemon-connection/newrelic.ini`:

```ini
extension = "/opt/newrelic/newrelic.so"

newrelic.license = "0000000000000000000000000000000000000000"
newrelic.appname = "daemon-connection-scenarios"

newrelic.logfile = "/tmp/newrelic-agent.log"
newrelic.loglevel = "verbosedebug"

newrelic.daemon.location = "/usr/bin/newrelic-daemon"
newrelic.daemon.pidfile = "/var/run/newrelic-daemon.pid"
newrelic.daemon.logfile = "/tmp/newrelic-daemon.log"
newrelic.daemon.loglevel = "verbosedebug"
```

`newrelic.daemon.port` and `newrelic.daemon.dont_launch` are deliberately absent — they vary per scenario (see Tasks 8–10) and are set at scenario-trigger time, not baked into this shared file.

- [ ] **Step 2: Write the fixture script**

`tests/daemon-connection/fixtures/index.php`:

```php
<?php
echo "ok\n";
```

- [ ] **Step 3: Add the two services to `compose.yaml`**

Append to `tests/daemon-connection/compose.yaml`:

```yaml
  php-cli-musl:
    image: php:8.4-cli-alpine
    entrypoint: ["tail"]
    command: ["-f", "/dev/null"]
    volumes:
      - ./artifacts/newrelic-nts-musl.so:/opt/newrelic/newrelic.so:ro
      - ./artifacts/newrelic-daemon-musl:/usr/bin/newrelic-daemon:ro
      - ./newrelic.ini:/usr/local/etc/php/conf.d/zz-newrelic.ini:ro
      - ./fixtures:/app:ro

  php-cli-gnu:
    image: php:8.4-cli-bookworm
    entrypoint: ["tail"]
    command: ["-f", "/dev/null"]
    volumes:
      - ./artifacts/newrelic-nts-gnu.so:/opt/newrelic/newrelic.so:ro
      - ./artifacts/newrelic-daemon-gnu:/usr/bin/newrelic-daemon:ro
      - ./newrelic.ini:/usr/local/etc/php/conf.d/zz-newrelic.ini:ro
      - ./fixtures:/app:ro
```

- [ ] **Step 4: Verify the compose file is still valid**

Run: `docker compose -f tests/daemon-connection/compose.yaml config --quiet`
Expected: exits 0.

- [ ] **Step 5: Verify the extension actually loads in both — this is the ABI-compatibility smoke test flagged in the spec**

Run:
```bash
docker compose -f tests/daemon-connection/compose.yaml up -d php-cli-musl php-cli-gnu
docker compose -f tests/daemon-connection/compose.yaml exec -T php-cli-musl php -m | grep -i newrelic
docker compose -f tests/daemon-connection/compose.yaml exec -T php-cli-gnu  php -m | grep -i newrelic
docker compose -f tests/daemon-connection/compose.yaml exec -T php-cli-musl php -r 'echo PHP_SAPI, PHP_EOL;'
docker compose -f tests/daemon-connection/compose.yaml exec -T php-cli-musl php /app/index.php
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected: `newrelic` printed by both `php -m` calls (confirms the `.so` built via `nr-php-agent-builder` loads in the official runtime image); `cli` printed for `PHP_SAPI`; `ok` printed by the fixture script. If `php -m` shows no `newrelic` line, check `docker compose logs` and `php -i | grep newrelic` for the load error before proceeding — do not continue to later tasks with a `.so` that doesn't load.

- [ ] **Step 6: Commit**

```bash
git add tests/daemon-connection/compose.yaml tests/daemon-connection/newrelic.ini tests/daemon-connection/fixtures/index.php
git commit -m "Add php-cli-musl/php-cli-gnu services with the extension mounted in"
```

---

### Task 5: `php-server-musl` / `php-server-gnu` services

**Files:**
- Modify: `tests/daemon-connection/compose.yaml`

**Interfaces:**
- Produces: two more compose services, `php-server-musl`/`php-server-gnu`, identical image/mounts to the `php-cli-*` pair from Task 4 (same NTS `.so`, since `php -S`'s SAPI name `cli-server` is still NTS PHP — R1 only needs a different `sapi_module.name` string, not a different binary).

- [ ] **Step 1: Append the two services**

```yaml
  php-server-musl:
    image: php:8.4-cli-alpine
    entrypoint: ["tail"]
    command: ["-f", "/dev/null"]
    volumes:
      - ./artifacts/newrelic-nts-musl.so:/opt/newrelic/newrelic.so:ro
      - ./artifacts/newrelic-daemon-musl:/usr/bin/newrelic-daemon:ro
      - ./newrelic.ini:/usr/local/etc/php/conf.d/zz-newrelic.ini:ro
      - ./fixtures:/app:ro

  php-server-gnu:
    image: php:8.4-cli-bookworm
    entrypoint: ["tail"]
    command: ["-f", "/dev/null"]
    volumes:
      - ./artifacts/newrelic-nts-gnu.so:/opt/newrelic/newrelic.so:ro
      - ./artifacts/newrelic-daemon-gnu:/usr/bin/newrelic-daemon:ro
      - ./newrelic.ini:/usr/local/etc/php/conf.d/zz-newrelic.ini:ro
      - ./fixtures:/app:ro
```

- [ ] **Step 2: Verify `php -S` actually reports SAPI name `cli-server` — this is the fact R1's whole design rests on**

Run:
```bash
docker compose -f tests/daemon-connection/compose.yaml up -d php-server-musl
docker compose -f tests/daemon-connection/compose.yaml exec -d php-server-musl \
  php -S 0.0.0.0:8080 /app/index.php
sleep 1
docker compose -f tests/daemon-connection/compose.yaml exec -T php-server-musl \
  sh -c "curl -s http://localhost:8080/sapi.php || true"
```
This will 404 since `sapi.php` doesn't exist yet — that's fine, this step only confirms `php -S` starts and accepts connections. Then:
```bash
docker compose -f tests/daemon-connection/compose.yaml exec -T php-server-musl \
  sh -c 'kill $(pgrep -f "php -S") '
docker compose -f tests/daemon-connection/compose.yaml down
```

- [ ] **Step 3: Add a fixture that actually reports the SAPI name, for real verification**

Create `tests/daemon-connection/fixtures/sapi.php`:

```php
<?php
echo php_sapi_name(), PHP_EOL;
```

Re-run the server, this time hitting `/sapi.php`:
```bash
docker compose -f tests/daemon-connection/compose.yaml up -d php-server-musl
docker compose -f tests/daemon-connection/compose.yaml exec -d php-server-musl \
  php -S 0.0.0.0:8080 -t /app
sleep 1
docker compose -f tests/daemon-connection/compose.yaml exec -T php-server-musl \
  curl -s http://localhost:8080/sapi.php
docker compose -f tests/daemon-connection/compose.yaml exec -T php-server-musl \
  sh -c 'kill $(pgrep -f "php -S")'
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected output: `cli-server`. If `curl` isn't available in `php:8.4-cli-alpine`, use `php -r` with a socket client instead — check with `docker compose exec php-server-musl which curl` first; if absent, replace the curl call with:
```bash
docker compose -f tests/daemon-connection/compose.yaml exec -T php-server-musl \
  php -r '$c=@file_get_contents("http://localhost:8080/sapi.php"); echo $c;'
```

- [ ] **Step 4: Commit**

```bash
git add tests/daemon-connection/compose.yaml tests/daemon-connection/fixtures/sapi.php
git commit -m "Add php-server-musl/php-server-gnu services; confirm SAPI name is cli-server"
```

---

### Task 6: `frankenphp-musl` / `frankenphp-gnu` services

**Files:**
- Modify: `tests/daemon-connection/compose.yaml`

**Interfaces:**
- Produces: `frankenphp-musl`/`frankenphp-gnu` services, mounting the **ZTS** `.so` (not NTS), plus the matching daemon binary, ini, and fixtures.

- [ ] **Step 1: Append the two services**

```yaml
  frankenphp-musl:
    image: dunglas/frankenphp:1-php8.4-alpine
    entrypoint: ["tail"]
    command: ["-f", "/dev/null"]
    volumes:
      - ./artifacts/newrelic-zts-musl.so:/opt/newrelic/newrelic.so:ro
      - ./artifacts/newrelic-daemon-musl:/usr/bin/newrelic-daemon:ro
      - ./newrelic.ini:/usr/local/etc/php/conf.d/zz-newrelic.ini:ro
      - ./fixtures:/app:ro

  frankenphp-gnu:
    image: dunglas/frankenphp:1-php8.4-bookworm
    entrypoint: ["tail"]
    command: ["-f", "/dev/null"]
    volumes:
      - ./artifacts/newrelic-zts-gnu.so:/opt/newrelic/newrelic.so:ro
      - ./artifacts/newrelic-daemon-gnu:/usr/bin/newrelic-daemon:ro
      - ./newrelic.ini:/usr/local/etc/php/conf.d/zz-newrelic.ini:ro
      - ./fixtures:/app:ro
```

- [ ] **Step 2: Verify the ZTS `.so` loads via the bundled `php` CLI (fast smoke test)**

Run:
```bash
docker compose -f tests/daemon-connection/compose.yaml up -d frankenphp-musl
docker compose -f tests/daemon-connection/compose.yaml exec -T frankenphp-musl php -m | grep -i newrelic
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected: `newrelic` printed.

- [ ] **Step 3: Verify the actual FrankenPHP server reports SAPI name `frankenphp`**

FrankenPHP's CLI (confirmed via `frankenphp php-server --help` on this exact image) serves a directory with `frankenphp php-server --listen=<addr> --root=<path>`:

```bash
docker compose -f tests/daemon-connection/compose.yaml up -d frankenphp-musl
docker compose -f tests/daemon-connection/compose.yaml exec -d frankenphp-musl \
  frankenphp php-server --listen=:8080 --root=/app
sleep 1
docker compose -f tests/daemon-connection/compose.yaml exec -T frankenphp-musl \
  php -r '$c=@file_get_contents("http://localhost:8080/sapi.php"); echo $c;'
docker compose -f tests/daemon-connection/compose.yaml exec -T frankenphp-musl \
  sh -c 'pkill -f "frankenphp php-server" || true'
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected output: `frankenphp`.

- [ ] **Step 4: Commit**

```bash
git add tests/daemon-connection/compose.yaml
git commit -m "Add frankenphp-musl/frankenphp-gnu services with the ZTS extension mounted in"
```

---

### Task 7: Shared scenario helpers — reset, up, trigger

**Files:**
- Modify: `tests/daemon-connection/run-scenario.sh`

**Interfaces:**
- Produces:
  - `compose()` — thin wrapper: `compose <args...>` → `docker compose -f "$COMPOSE_FILE" <args...>`.
  - `reset_container_state(service)` — kills any locally-spawned daemon, removes its pidfile, removes stale logs, removes `/etc/newrelic/newrelic.cfg` and any daemon-port override ini, inside the given service's container.
  - `trigger_cli(service, [extra_ini...])` — runs `php /app/index.php` in `service`, returns its stdout.
  - `trigger_server(service, run_cmd, [extra_ini...])` — starts the given server command (`php -S ...` or `frankenphp php-server ...`) detached, curls `/sapi.php`, then kills the server process; returns the curl output.
- Consumes: `$COMPOSE_FILE` (Task 1).

- [ ] **Step 1: Add the helpers**

Insert before `main()` in `tests/daemon-connection/run-scenario.sh`:

```bash
compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

# Clears anything a previous scenario run against this container might have
# left behind, so results never leak between runs. Killing a stale
# self-spawned daemon matters specifically for R7: the daemon's own
# collision guard (an exclusive pidfile lock — see
# daemon/internal/newrelic/pidfile.go) means a second spawn against an
# already-running daemon exits silently without updating the pidfile,
# which would otherwise look identical to "no spawn happened".
reset_container_state() {
  local service="$1"
  compose exec -T "$service" sh -c '
    pkill -f newrelic-daemon 2>/dev/null || true
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
# kills the server process by matching on the command string.
trigger_server() {
  local service="$1" match="$2"; shift 2
  compose exec -d "$service" "$@"
  sleep 1
  compose exec -T "$service" \
    php -r '$c=@file_get_contents("http://localhost:8080/sapi.php"); echo $c;'
  compose exec -T "$service" sh -c "pkill -f '$match' || true"
}
```

- [ ] **Step 2: Verify `reset_container_state` and `set_init_mode` work against a running container**

Run:
```bash
docker compose -f tests/daemon-connection/compose.yaml up -d php-cli-musl
```
Then, with the functions sourced (`source tests/daemon-connection/run-scenario.sh` guarded by adding a temporary `return` before `main "$@"` is unnecessary — instead just call them via a one-off subshell):
```bash
bash -c '
  source <(sed "\$d" tests/daemon-connection/run-scenario.sh)  # drop the final main "$@" line
  set_init_mode php-cli-musl
  compose exec -T php-cli-musl sh -c "test -f /etc/newrelic/newrelic.cfg && echo present"
  reset_container_state php-cli-musl
  compose exec -T php-cli-musl sh -c "test -f /etc/newrelic/newrelic.cfg || echo absent"
'
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected: `present` then `absent`.

- [ ] **Step 3: Commit**

```bash
git add tests/daemon-connection/run-scenario.sh
git commit -m "Add shared scenario helpers: reset, external-daemon/init-mode toggles, triggers"
```

---

### Task 8: R7 — agent self-spawns the daemon

**Files:**
- Modify: `tests/daemon-connection/run-scenario.sh`

**Interfaces:**
- Produces: `scenario_r7(libc)` — runs against `php-cli-<libc>` (R7's behavior doesn't depend on which SAPI lane triggers it, and `php-cli` is the simplest one-shot invocation), asserts a fresh daemon spawn happened via pidfile mtime/PID, and that the R8-style failure warning is absent from the agent log. Exits 0 on success, non-zero with a diagnostic message on failure.
- Consumes: `reset_container_state`, `trigger_cli`, `compose` (Task 7).

- [ ] **Step 1: Add `scenario_r7`**

```bash
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
```

- [ ] **Step 2: Verify it fails against a stubbed-out environment first**

Temporarily comment out `newrelic.daemon.location` in `newrelic.ini`, rebuild nothing (just restart the container to pick up the ini change), and run:
```bash
docker compose -f tests/daemon-connection/compose.yaml up -d php-cli-musl
```
then call `scenario_r7 musl` via the same `source <(sed '$d' ...)` pattern from Task 7 Step 2.
Expected: fails with the "no pidfile after trigger" message, since without `daemon.location` pointed at the bundled binary the agent has nothing to spawn — or the connect attempt is skipped entirely. Restore `newrelic.ini` to its real content immediately after observing the failure.

- [ ] **Step 3: Run it for real and verify it passes for both libc**

```bash
docker compose -f tests/daemon-connection/compose.yaml up -d php-cli-musl php-cli-gnu
bash -c 'source <(sed "\$d" tests/daemon-connection/run-scenario.sh); scenario_r7 musl'
bash -c 'source <(sed "\$d" tests/daemon-connection/run-scenario.sh); scenario_r7 gnu'
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected: `R7/musl: PASS` and `R7/gnu: PASS`.

- [ ] **Step 4: Commit**

```bash
git add tests/daemon-connection/run-scenario.sh
git commit -m "Implement R7 scenario: agent self-spawn verified via pidfile"
```

---

### Task 9: R8 — agent forbidden to spawn

**Files:**
- Modify: `tests/daemon-connection/run-scenario.sh`

**Interfaces:**
- Produces: `scenario_r8(libc)` — same lane as R7, but touches `/etc/newrelic/newrelic.cfg` first (forcing `NR_DAEMON_STARTUP_INIT`), then asserts the daemon is **not** spawned and the exact failure warning **is** logged.
- Consumes: `reset_container_state`, `set_init_mode`, `trigger_cli`, `compose` (Task 7).

- [ ] **Step 1: Add `scenario_r8`**

```bash
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
```

- [ ] **Step 2: Verify it fails if the INIT-mode toggle is skipped (proves the assertion actually discriminates R7 from R8)**

```bash
docker compose -f tests/daemon-connection/compose.yaml up -d php-cli-musl
bash -c '
  source <(sed "\$d" tests/daemon-connection/run-scenario.sh)
  reset_container_state php-cli-musl
  trigger_cli php-cli-musl >/dev/null   # no set_init_mode call
  compose exec -T php-cli-musl test -f /var/run/newrelic-daemon.pid && echo "pidfile present, as expected for R7-like behavior"
'
```
Expected: `pidfile present, as expected for R7-like behavior` — confirming that skipping `set_init_mode` reproduces R7's outcome, not R8's, which is exactly why `scenario_r8` must call it.

- [ ] **Step 3: Run the real scenario for both libc**

```bash
bash -c 'source <(sed "\$d" tests/daemon-connection/run-scenario.sh); scenario_r8 musl'
bash -c 'source <(sed "\$d" tests/daemon-connection/run-scenario.sh); scenario_r8 gnu'
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected: `R8/musl: PASS` and `R8/gnu: PASS`.

- [ ] **Step 4: Commit**

```bash
git add tests/daemon-connection/run-scenario.sh
git commit -m "Implement R8 scenario: forced INIT mode verified via pidfile absence and log line"
```

---

### Task 10: R1 and R2 — external `newrelic-daemon` service

**Files:**
- Modify: `tests/daemon-connection/run-scenario.sh`

**Interfaces:**
- Produces: `scenario_r1(libc)` (against `php-server-<libc>`) and `scenario_r2(libc)` (against `php-cli-<libc>` and `frankenphp-<libc>`, i.e. two sub-checks). Both bring up `newrelic-daemon`, call `set_external_daemon`, and assert: no local pidfile was created (no self-spawn — the connect succeeded against the external service instead) and the INIT-mode failure warning is absent (the connect did not fail).
- Consumes: `reset_container_state`, `set_external_daemon`, `trigger_cli`, `trigger_server`, `compose` (Task 7).

- [ ] **Step 1: Add a shared assertion helper and `scenario_r1`/`scenario_r2`**

```bash
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
}

# R1: php -S reports SAPI cli-server, so nr_php_process_will_fork() == true
# (agent/php_minit.c:441-474) while still hitting the Connected outcome.
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
```

- [ ] **Step 2: Verify the assertion discriminates correctly — run against a container where the external-daemon service is NOT up**

```bash
docker compose -f tests/daemon-connection/compose.yaml up -d php-cli-musl
bash -c '
  source <(sed "\$d" tests/daemon-connection/run-scenario.sh)
  reset_container_state php-cli-musl
  set_external_daemon php-cli-musl
  trigger_cli php-cli-musl >/dev/null
  assert_connected_externally "manual-check" php-cli-musl && echo "unexpectedly passed" || echo "correctly failed: no external daemon was up"
'
```
Expected: `correctly failed: no external daemon was up` — since `newrelic-daemon` was never started, the agent's connect attempt to `newrelic-daemon:31339` fails, and (because no `/etc/newrelic/newrelic.cfg` is present) the agent falls into `NR_DAEMON_STARTUP_AGENT` and self-spawns instead — producing a local pidfile, which `assert_connected_externally` correctly flags as wrong for this scenario.

- [ ] **Step 3: Bring up all services and run the real R1/R2 scenarios for both libc**

```bash
docker compose -f tests/daemon-connection/compose.yaml up -d
bash -c 'source <(sed "\$d" tests/daemon-connection/run-scenario.sh); scenario_r1 musl'
bash -c 'source <(sed "\$d" tests/daemon-connection/run-scenario.sh); scenario_r1 gnu'
bash -c 'source <(sed "\$d" tests/daemon-connection/run-scenario.sh); scenario_r2 musl'
bash -c 'source <(sed "\$d" tests/daemon-connection/run-scenario.sh); scenario_r2 gnu'
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected: `R1/musl: PASS`, `R1/gnu: PASS`, `R2-cli/musl: PASS`, `R2-frankenphp/musl: PASS`, `R2-cli/gnu: PASS`, `R2-frankenphp/gnu: PASS`.

- [ ] **Step 4: Commit**

```bash
git add tests/daemon-connection/run-scenario.sh
git commit -m "Implement R1/R2 scenarios against the external newrelic-daemon service"
```

---

### Task 11: Wire up the CLI dispatch and run the full matrix

**Files:**
- Modify: `tests/daemon-connection/run-scenario.sh`

**Interfaces:**
- Produces: the final `main()` dispatch — `run-scenario.sh {r1|r2|r7|r8} {musl|gnu}` — plus an `all` mode that runs every row/libc combination and reports a summary. Every scenario function's dependencies (compose services up, artifacts built) are handled by `main()` itself so the script works from a clean checkout with one command.

- [ ] **Step 1: Replace the placeholder `main()` with the full dispatch**

```bash
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
```

Remove the earlier, now-superseded `main()` definition from Task 2 (the one with only the `build-so` case) so there is exactly one `main()` in the file.

- [ ] **Step 2: Run the full matrix end to end from a clean state**

```bash
rm -rf tests/daemon-connection/artifacts/*.so tests/daemon-connection/artifacts/newrelic-daemon-*
tests/daemon-connection/run-scenario.sh all musl
tests/daemon-connection/run-scenario.sh all gnu
docker compose -f tests/daemon-connection/compose.yaml down
```
Expected: both invocations print `PASS` for all four rows and exit 0 (`=== all requested scenarios passed ===`).

- [ ] **Step 3: Verify a deliberately broken scenario is correctly reported as a failure (confirms exit codes aren't silently swallowed)**

Temporarily edit `scenario_r8` to skip the `set_init_mode "$service"` call, run `tests/daemon-connection/run-scenario.sh r8 musl`, confirm it exits non-zero and prints a `FAIL` line, then revert the edit.

- [ ] **Step 4: Commit**

```bash
git add tests/daemon-connection/run-scenario.sh
git commit -m "Wire up run-scenario.sh CLI dispatch: {r1|r2|r7|r8|all} {musl|gnu}"
```

---

## Self-Review Notes

- **Spec coverage:** R1 (Task 5/10), R2 (Task 4/6/10), R7 (Task 8), R8 (Task 9) all have a task. musl+gnu duplication for every SAPI lane: Tasks 4–6 each create both variants; Tasks 8–11 all take a `libc` argument. `newrelic-daemon` staying singular/musl-only: Task 1 creates it once, never duplicated. No custom Dockerfiles: confirmed — every task uses `image:` with an existing tag, never `build:`. Directory `tests/daemon-connection/`: Task 1. R3–R6/O1–O3 out of scope: no task implements them, matching the spec.
- **Placeholder scan:** none found — a stray `set_external_daemon(service) { :; }` scaffolding line from an earlier draft of Task 7 was removed (the clean function definition is the only one present now), and every other step has real, runnable commands rather than described-but-unwritten behavior.
- **Type/name consistency:** `find_so`/`build_so`/`build_all_so` (Task 2) → used unchanged by `ensure_built` (Task 11). `stage_daemon_binaries` (Task 3) → used unchanged by `ensure_built` (Task 11). `reset_container_state`/`set_external_daemon`/`set_init_mode`/`trigger_cli`/`trigger_server`/`compose` (Task 7) → used with the same names and argument order by Tasks 8–10. `scenario_r1`/`scenario_r2`/`scenario_r7`/`scenario_r8` (Tasks 8–10) → dispatched by identical names in `run_row` (Task 11).
