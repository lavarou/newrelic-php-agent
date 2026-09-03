# Docker Compose project for agent/daemon connection scenarios

## Purpose

Build integration-test infrastructure that exercises the agent/daemon
connection-lifecycle scenario matrix documented in
`docs/daemon-connection-scenarios.md`, using real process and container
boundaries (separate `newrelic-daemon` process vs. agent-embedded PHP
process), with a focus on the FrankenPHP SAPI (persistent, multithreaded,
non-forking) alongside standard forking/non-forking SAPIs for contrast.
Each SAPI lane runs under both glibc and musl, since the agent and daemon
both ship and are tested against both libc implementations elsewhere in
this repo's own CI.

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

Every row above runs against **both** glibc and musl builds of the SAPI
service in question — see "Image architecture" below. The
`newrelic-daemon` service used for R1/R2 is not duplicated per libc (its
own libc is irrelevant to what these rows test — see that section for
why).

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

No custom Dockerfiles are required anywhere in this project — but
supporting both libc implementations does mean the daemon binary can no
longer *always* come from a single published image (see below).
Everything still uses existing published images, verified directly
against Docker Hub (pulled and inspected, not assumed from documentation):

Target PHP version: **8.4** (the latest version the agent documents
support for, per `docs/development.md`).

| Role | musl (Alpine) | glibc (Debian) |
|---|---|---|
| Build NTS `.so` | `newrelic/nr-php-agent-builder:make-php-8.4-musl` | `newrelic/nr-php-agent-builder:make-php-8.4-gnu` |
| Build ZTS `.so` | `newrelic/nr-php-agent-builder:make-php-8.4-zts-musl` | `newrelic/nr-php-agent-builder:make-php-8.4-zts-gnu` |
| Build daemon (from source) | not needed (see below) | `newrelic/nr-php-agent-builder:make-go-gnu` |
| `php-cli` / `php-server` runtime | `php:8.4-cli-alpine` (official image) | `php:8.4-cli-bookworm` (official image) |
| `frankenphp` runtime | `dunglas/frankenphp:1-php8.4-alpine` | `dunglas/frankenphp:1-php8.4-bookworm` (Debian is FrankenPHP's own recommended default, per their docs) |

All nine image tags above are confirmed to exist on Docker Hub (pulled
and/or `docker manifest inspect`ed this session — the `-zts-gnu` and
`-zts-musl` builder tags live in a private registry reachable with the
same Docker Hub auth already used for the other builder tags). Pulled and
ran every runtime image to confirm libc and thread-safety match
expectations rather than assuming from tag names alone:
- `dunglas/frankenphp:1-php8.4-alpine`: `Thread Safety => enabled`, ZTS.
- `php:8.4-cli-alpine`: Alpine Linux, PHP 8.4.25 **NTS**.
- `php:8.4-cli-bookworm`: Debian 12 (bookworm), PHP 8.4.25 **NTS**.

The Debian/glibc side of `dunglas/frankenphp` is ZTS the same way the
Alpine tag was confirmed to be: FrankenPHP requires ZTS regardless of
libc — inherent to being a multithreaded embed-SAPI server, not an
Alpine-specific build choice.

### `php-cli`/`php-server`: build and runtime are now different images

Switching the runtime to official `php:8.4-cli-*` images (rather than
reusing the `nr-php-agent-builder` image the `.so` was built with, as the
first draft of this design did) means all three SAPI lanes now share the
same build/runtime split that `frankenphp` already had: build the `.so`
in one image, mount it into a different one to actually run it. This
rests on one ABI-compatibility expectation: a `.so` built against PHP
8.4's headers via `nr-php-agent-builder:make-php-8.4-{musl,gnu}` is
expected to load correctly in official `php:8.4-cli-{alpine,bookworm}`,
because PHP's extension ABI (`PHP_API_VERSION`/Zend Module API number) is
a per-minor-version constant baked into PHP's own source — not something
that varies between different vendors' builds of the same PHP minor
version, same NTS/ZTS, same libc. This is the same assumption that makes
distro-packaged PHP extensions work against distro-packaged PHP in
general, and matches direct prior experience building the agent with
these images.

### The `newrelic-daemon` service stays singular, and stays musl

`newrelic-daemon` (the external daemon used by R1/R2) is **not**
duplicated into a glibc variant. Its own libc is irrelevant to what R1/R2
test: it's a separate container, reached over TCP
(`newrelic-daemon:31339` via Compose service-name DNS — see "Networking
model"), and a libc mismatch cannot matter across a network socket. It
stays `newrelic/php-daemon:latest` (Alpine/musl) for every lane,
glibc-SAPI lanes included.

### Daemon binary for R7/R8: per-lane, not per-image

R7/R8 need the daemon binary present *inside* the SAPI container itself
(the agent spawns it locally), so — unlike the external-daemon case above
— its libc has to match the container it's running in:

- **musl lanes:** copy `/usr/bin/newrelic-daemon` straight out of
  `newrelic/php-daemon:latest`, as described in the original (musl-only)
  draft of this design — no rebuild needed. `agent/php_nrini.c:218`
  defines `NR_PHP_INI_DEFAULT_DAEMON_LOCATION` as
  `/usr/bin/newrelic-daemon`, exactly where that image places the binary,
  so no `newrelic.daemon.location` ini override is needed.
- **glibc lanes:** no published glibc/Debian variant of `newrelic/php-daemon`
  was found — checked several plausible tags (`:gnu`, `:debian`,
  `:bookworm`, `:glibc`, `:latest-gnu`) against Docker Hub and none exist.
  Build `bin/daemon` from source instead, via
  `newrelic/nr-php-agent-builder:make-go-gnu` (confirmed to exist) running
  `make daemon` against the bind-mounted repo, then copy the result to
  `/usr/bin/newrelic-daemon` inside the glibc SAPI images (same target
  path, so the ini default still applies with no override).

## Build mechanism: producing all four `.so` ABI variants without clobbering

All four builder images (NTS/ZTS × musl/gnu) run `make agent` (indirectly)
against the **same** bind-mounted repo checkout. Naively running `make
agent` repeatedly — once per builder image — would overwrite
`agent/modules/newrelic.so` on each subsequent run, destroying the
previous build's artifact.

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
- `RELEASE_OS` itself also already varies by libc: it detects the active
  C library (`make/release.mk:17-31`) and appends `-musl` when the
  builder container is musl-based, leaving it as plain `linux` for glibc.
  Combined with the `-zts`/empty suffix, this means all four builds
  (NTS-musl, ZTS-musl, NTS-gnu, ZTS-gnu) land at four distinct paths under
  `releases/` with no extra logic required to keep them apart.

**Build step per lane:** for each of the four `.so` variants, `docker
compose run` the matching builder image against the bind-mounted repo and
execute `make release-agent` — which already bundles the `agent-clean &&
agent-for-release` sequence (`make/release.mk:86-87`), so the runner
script invokes just this one target per variant, not the two-step
sequence spelled out separately. Then locate each produced file by glob
(`releases/*/agent/*/newrelic-*.so`, filtering on whether the path
contains `musl` and whether the filename ends in `-zts.so`) rather than
hardcoding `PHP_API_VERSION` or `RELEASE_OS` — the runner script should
not need to replicate that detection logic.

**Daemon build step (glibc lanes only):** the same `docker compose run`
pattern, against `newrelic/nr-php-agent-builder:make-go-gnu`, executing
`make daemon` against the bind-mounted repo to produce `bin/daemon`;
copied into the glibc SAPI runtime images at `/usr/bin/newrelic-daemon`
for R7/R8. Whether this builder image gets its own named `compose.yaml`
entry or is invoked directly (mirroring how this repo's own CI runs these
builder images via plain `docker run`, not through compose) is an
implementation-plan detail, not a design one. No equivalent step exists
for musl lanes — they get the binary from `newrelic/php-daemon` instead
(see "Daemon binary for R7/R8" above).

## Networking model

- **R1/R2** (external `newrelic-daemon` service): the `newrelic/php-daemon`
  image's default entrypoint already binds TCP `$(hostname):31339`. Docker
  Compose's built-in service-name DNS makes `newrelic-daemon:31339`
  resolvable from any SAPI container — musl or glibc alike, since this is
  plain TCP over the Compose network, not something libc-sensitive — with
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
- `compose.yaml` — seven services: `newrelic-daemon`, plus one musl and
  one glibc variant each of `php-cli`, `php-server`, and `frankenphp`
  (e.g. `php-cli-musl`/`php-cli-gnu`, `php-server-musl`/`php-server-gnu`,
  `frankenphp-musl`/`frankenphp-gnu`). No custom `build:` stanzas.
- `run-scenario.sh` — the scenario runner (see below).
- A minimal `php.ini` snippet (extension path templated per lane) mounted
  into each SAPI container.

Root `docker-compose.yaml` and `files/Dockerfile` are untouched.

## Scenario runner

A single shell script, `run-scenario.sh {r1|r2|r7|r8} {musl|gnu}` — the
libc argument selects which pair of SAPI services (e.g.
`php-server-musl` vs. `php-server-gnu`) the scenario runs against; the
`newrelic-daemon` service is unaffected by it. Per the chosen tooling
approach (no new language/dependency, matches this repo's existing
Makefile-driven shell-heavy conventions), each scenario:

1. Builds (or reuses already-built) `.so` artifacts via the mechanism
   above, if not already present, for the requested libc lane.
2. Brings up the right service combination: `newrelic-daemon` + the
   libc-selected SAPI service for R1/R2; that SAPI service alone (no
   `newrelic-daemon`) for R7/R8, with `/etc/newrelic/newrelic.cfg` touched
   or not per R7/R8.
3. Triggers one request: `curl` for `php-server-*`/`frankenphp-*`, direct
   invocation for `php-cli-*`.
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

- Exact `php.ini` snippet content (extension path, `newrelic.appname`,
  `newrelic.license`, log paths) — mechanical, deferred to the
  implementation plan.

(Build-tooling sufficiency of the `nr-php-agent-builder` images, and
whether a `.so` built through them loads correctly in the corresponding
official/vendor runtime images, were open questions in earlier drafts of
this section — resolved based on direct, extensive prior experience
building the agent with these exact images, rather than needing a
first-build smoke test to confirm.)
