# Docker Compose project for agent/daemon connection scenarios

## Purpose

Build integration-test infrastructure that exercises the agent/daemon
connection-lifecycle scenario matrix documented in
`docs/daemon-connection-scenarios.md`, using real process and container
boundaries (separate `newrelic-daemon` process vs. agent-embedded PHP
process), with a focus on the FrankenPHP SAPI (persistent, multithreaded,
non-forking) alongside standard forking/non-forking SAPIs for contrast.

This is new, greenfield test infrastructure — no docker-compose-based
scenario testing of this kind exists in the repo today. It is intentionally
separate from the root `docker-compose.yaml`/`files/Dockerfile`, which serve
the existing mysql/redis/devenv dev-and-integration-test workflow; this
project must not risk regressing that.

## Scope

### In scope — MINIT-boundary matrix rows

| Row | Connect outcome | Startup mode | Will fork? | Covered by |
|---|---|---|---|---|
| R1 | Connected | n/a | true | `php-server` service (`php -S`, SAPI name `cli-server`) |
| R2 | Connected | n/a | false | `php-cli` and `frankenphp` services |
| R7 | Failed (refused) | AGENT | irrelevant | SAPI service run with no external daemon; agent self-spawns |
| R8 | Failed (refused) | INIT | irrelevant | Same, with agent forbidden to spawn |

**R1 verified via source, not assumed:** `nr_php_process_will_fork()`
(`agent/php_minit.c:462-474`) returns `true` unless
`NR_PHP_PROCESS_GLOBALS(cli)` is set — and that flag is only set when
`sapi_module.name` string-compares equal to exactly `"cli"`
(`agent/php_minit.c:441`). PHP's built-in web server reports SAPI name
`cli-server`, a different string, so it falls through to `will_fork() ==
true` — satisfying R1 without needing a forking SAPI like FPM or Apache
prefork.

### Explicitly out of scope

- **R3–R6** (the `EINPROGRESS`/`EALREADY` in-progress-connect rows): these
  require winning a race against a hardcoded, non-configurable 10ms window
  (`NR_PHP_MINIT_DAEMON_CONNECTION_TIMEOUT_MS`). Not reliably reachable via
  container-level timing. A future fault-injection component test (a
  deliberately slow-accepting TCP listener) is the right tool for these,
  not this project.
- **O1–O3** (orthogonal cases: mid-request RPC failure, MSHUTDOWN close,
  threaded-Apache-MPM self-disable): out of scope per explicit direction —
  none of them are exercised by this project.
- **R1-vs-R2 boolean logic** (`nr_php_process_will_fork()` itself) and the
  **daemon-side pidfile lock race** (concurrent spawns) are unit-test
  concerns (C in `agent/tests/`, Go in `daemon/internal/newrelic/`
  respectively), not container-orchestration concerns. This project treats
  the pidfile lock as a given (verified behavior, see
  `docs/daemon-connection-scenarios.md`'s "Daemon-side spawn collision
  guard" section) and uses it only as an *assertion technique* for R7.

## Image architecture

No custom Dockerfiles or image builds are required anywhere in this
project. Everything uses existing published images, verified directly
against Docker Hub (pulled and inspected, not assumed from documentation):

| Role | Image | Verified facts |
|---|---|---|
| Build NTS `.so` | `newrelic/nr-php-agent-builder:make-php-8.2-musl` | Alpine/musl, PHP 8.2.x NTS, has `phpize`/`php-config`/`make`/`git`; no Go toolchain (daemon builds are intentionally not this image's job) |
| Build ZTS `.so` | `newrelic/nr-php-agent-builder:make-php-8.2-zts-musl` | Alpine/musl, PHP 8.2.19 **ZTS**, same toolchain; private registry, requires the same Docker Hub auth already used for the other builder tags |
| `newrelic-daemon` service | `newrelic/php-daemon:latest` | Alpine/musl; binary at `/usr/bin/newrelic-daemon`; default entrypoint (`/usr/bin/docker-entrypoint.sh`) runs `newrelic-daemon --logfile /proc/self/fd/1 --watchdog-foreground --address=$(hostname):31339` — a **TCP** listener, not the abstract-socket default the agent itself would use standalone |
| `php-cli` / `php-server` service | `newrelic/nr-php-agent-builder:make-php-8.2-musl` (same image reused as runtime, matching the existing root `docker-compose.yaml` `php` service pattern) | has a working `php` CLI binary already |
| `frankenphp` service | `dunglas/frankenphp:1-php8.2-alpine` | Alpine/musl; confirmed by running it: `Thread Safety => enabled`, PHP 8.2.33 built `(ZTS)`; `/usr/local/bin/phpize` and `/usr/local/bin/php-config` present (not just documented — actually invoked) |

All five images are musl/Alpine-based **by design**: it lets the single
`newrelic/php-daemon` binary be copied as-is into every SAPI runtime
container (for R7/R8 self-spawn) with no rebuild and no libc mismatch. The
copy target matters: `agent/php_nrini.c:218` defines
`NR_PHP_INI_DEFAULT_DAEMON_LOCATION` as `/usr/bin/newrelic-daemon` — which
is exactly where `newrelic/php-daemon` already places the binary — so no
`newrelic.daemon.location` ini override is needed in the SAPI containers.

### Why not build the daemon from source

`newrelic/nr-php-agent-builder:make-go-*` exists and could build
`bin/daemon`, but there's no reason to: `newrelic/php-daemon` already
ships a working, musl-compatible binary at the exact path the agent
expects by default. Building from source would only be needed if a
scenario required a daemon binary the published image doesn't have (none
of R1/R2/R7/R8 do).

## Build mechanism: producing both `.so` ABI variants without clobbering

Both builder images run `make agent` (indirectly) against the **same**
bind-mounted repo checkout. Naively running `make agent` twice — once
under `make-php-8.2-musl` (NTS), once under `make-php-8.2-zts-musl` (ZTS)
— would overwrite `agent/modules/newrelic.so` the second time, destroying
the first build's artifact.

The repo already solves exactly this problem via `make/release.mk`,
verified by reading its source rather than assumed:

- `agent-for-release` (`make/release.mk:96-107`) depends on `agent`, then
  **copies** (does not move) `agent/modules/newrelic.so` to
  `releases/$(RELEASE_OS)/agent/$(RELEASE_ARCH)/newrelic-$(PHP_API_VERSION)$(PHP_ZTS).so`,
  where `PHP_ZTS` is auto-detected from the *active* `php-config`'s
  `php_config.h` (`-zts` suffix, or empty for NTS) and `PHP_API_VERSION`
  from `php.h`. The `-zts`/empty suffix is derived unconditionally from
  whether the `ZTS` macro is defined in the active `php_config.h` — so the
  two builds' output filenames are guaranteed to differ by that suffix
  alone, regardless of whether their `PHP_API_VERSION` values also happen
  to match (not itself verified this session, and irrelevant to the
  collision-avoidance argument).
- `agent-clean` (top-level `Makefile:143-145`) runs `cd agent; make clean;
  phpize --clean` — strictly inside `agent/`, and never touches
  `releases/`. It cannot delete `agent-for-release`'s output.
- Confirmed this is the intended, load-bearing pattern (not an accident of
  file layout) by reading `release-agent`'s own recipe
  (`make/release.mk:86-87`): `@$(MAKE) agent-clean && $(MAKE)
  agent-for-release` — the real release pipeline runs `agent-clean`
  immediately before `agent-for-release` on every invocation, and the
  doc comment above `agent-for-release` (lines 96-99) states this
  explicitly: *"allows to preserve agent between PHP version switches."*
- `RELEASE_ARCH` resolves from `ARCH ?= $(shell uname -m)`
  (`make/php_versions.mk:23`) — i.e., whatever the container's actual
  architecture reports (`x86_64`/`aarch64`), not something the build
  script needs to hardcode.

**Build step per lane:** `docker compose run` the relevant builder image
against the bind-mounted repo, execute `make release-agent` — which
already bundles the `agent-clean && agent-for-release` sequence
(`make/release.mk:86-87`), so the runner script invokes just this one
target, not the two-step sequence spelled out separately. Then locate the
produced file by glob (`releases/*/agent/*/newrelic-*.so` for NTS,
`releases/*/agent/*/newrelic-*-zts.so` for ZTS) rather than hardcoding
`PHP_API_VERSION` — the runner script should not need to replicate that
detection logic.

## Networking model

- **R1/R2** (external `newrelic-daemon` service): the `newrelic/php-daemon`
  image's default entrypoint already binds TCP `$(hostname):31339`. Docker
  Compose's built-in service-name DNS makes `newrelic-daemon:31339`
  resolvable from the `php-cli`/`php-server`/`frankenphp` containers with
  no extra networking config. (An earlier draft of this design proposed
  working around Linux abstract-socket network-namespace isolation with a
  shared-volume UDS path — that workaround is unnecessary once the actual
  entrypoint behavior is known: it was never going to use an abstract
  socket in the first place.)
- **R7/R8** (agent-managed or no daemon): each SAPI container runs
  entirely standalone — no `newrelic-daemon` service involved, no shared
  volume, no cross-container networking. The agent connects to (or spawns)
  a daemon local to its own container using its own default socket
  behavior.

## Scenario toggle: R7 vs. R8

Both rows use the same container (no external `newrelic-daemon` service,
local `/usr/bin/newrelic-daemon` binary present), differing only in
whether `nr_php_get_daemon_startup_mode()` (`agent/php_minit.c:158-219`)
returns `NR_DAEMON_STARTUP_AGENT` (R7) or `NR_DAEMON_STARTUP_INIT` (R8).
Verified gates, in the order the function checks them:

1. Presence of `/etc/newrelic/newrelic.cfg` forces INIT unconditionally.
2. `no_daemon_launch` value `3` forces INIT unconditionally; `1`/`2` force
   INIT conditionally on CLI-vs-non-CLI SAPI.
3. A `daemon.port` pointing at a non-local TCP host also forces INIT — not
   relevant here since R7/R8 use the default local socket.

**R7** setup: no `/etc/newrelic/newrelic.cfg`, `no_daemon_launch` unset —
agent spawns `/usr/bin/newrelic-daemon` itself.
**R8** setup: touch an (empty is sufficient) `/etc/newrelic/newrelic.cfg`
inside the container before triggering the request — agent must not spawn.

## Directory layout

New, self-contained directory: `tests/docker/daemon-connection/`
- `compose.yaml` — the four services (`newrelic-daemon`, `php-cli`,
  `php-server`, `frankenphp`), no custom `build:` stanzas.
- `run-scenario.sh` — the scenario runner (see below).
- A minimal `php.ini` snippet (extension path templated per lane) mounted
  into each SAPI container.

Root `docker-compose.yaml` and `files/Dockerfile` are untouched.

## Scenario runner

A single shell script, `run-scenario.sh {r1|r2|r7|r8}`, per the chosen
tooling approach (no new language/dependency, matches this repo's
existing Makefile-driven shell-heavy conventions). Each scenario:

1. Builds (or reuses already-built) `.so` artifacts via the mechanism
   above, if not already present.
2. Brings up the right service combination: `newrelic-daemon` + one SAPI
   service for R1/R2; the SAPI service alone (no `newrelic-daemon`) for
   R7/R8, with `/etc/newrelic/newrelic.cfg` touched or not per R7/R8.
3. Triggers one request: `curl` for `php-server`/`frankenphp`, direct
   invocation for `php-cli`.
4. Asserts:
   - Agent log `nrl_debug`/`nrl_info` lines matching the expected
     MINIT-boundary behavior for that row (e.g. daemon-connection-failure
     messages for R7/R8 before a spawn succeeds).
   - For R7 specifically: `stat` the pidfile's mtime/PID inside the
     container before and after triggering MINIT, to distinguish "the
     agent actually spawned a daemon" from "got lucky and connected to
     something already running" — reliable because the Watcher process
     holds an exclusive `fcntl` lock on the pidfile for its whole
     lifetime (`daemon/internal/newrelic/pidfile.go`,
     `daemon/cmd/daemon/watcher.go`), so only a genuine new spawn produces
     a fresh timestamp/PID.

## Open implementation-time items (not design blockers)

- Exact package/tooling needs beyond `phpize`/`php-config` for `make
  agent` to succeed inside the Alpine builder images (e.g. `protobuf-c`,
  `pcre`) — the images are already used for this purpose in this repo's
  own CI (`agent-unit-test-*` jobs, `platform: musl` matrix entries), so
  this is expected to just work, but should be confirmed empirically on
  first build rather than assumed.
- Exact `php.ini` snippet content (extension path, `newrelic.appname`,
  `newrelic.license`, log paths) — mechanical, deferred to the
  implementation plan.
