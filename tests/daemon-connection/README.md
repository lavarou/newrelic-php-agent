# Daemon connection scenario tests

Exercises rows R1, R2, R7, and R8 of the agent/daemon connection-lifecycle
matrix (see `docs/daemon-connection-scenarios.md` and
`docs/superpowers/specs/2026-09-01-daemon-connection-docker-compose-design.md`
for the full row definitions and design rationale) against real Docker
containers, for both musl and glibc builds of `php-cli`, `php-server`
(PHP's built-in server), and `frankenphp`.

## Usage

```
./run-scenario.sh {r1|r2|r7|r8|all} {musl|gnu}
```

`all` runs every row against the given libc. Run it twice (once per libc)
to cover the full matrix.

On first run (or after `artifacts/` is cleared), this builds four
`newrelic.so` variants and stages two `newrelic-daemon` binaries — expect
this to take several minutes. Subsequent runs skip the build step if the
artifacts already exist.

To build (or rebuild) a single variant directly, without running any
scenarios, use `build-artifacts.sh`:

```
./build-artifacts.sh {musl|gnu} {nts|zts}   # build one newrelic.so variant
./build-artifacts.sh all                    # build all four (what run-scenario.sh does on first run)
./build-artifacts.sh stage-daemon           # stage both newrelic-daemon binaries
```

It can also be sourced (`source build-artifacts.sh`) to get `build_so`,
`find_so`, etc. as functions in your own shell — it has no top-level
side effects when sourced, only when run directly.

## Prerequisites

- Docker, with `docker compose` v2.
- Docker Hub authentication with access to `newrelic/nr-php-agent-builder`'s
  private `-zts-musl`/`-zts-gnu` tags (`docker login` as an account with
  New Relic org access).
- `NEW_RELIC_LICENSE_KEY`, exported or set in `.env` next to `compose.yaml`
  (git ignores it). `docker compose up` refuses to start without it.
  `NEW_RELIC_HOST` is optional and defaults to `collector.newrelic.com`.
  `newrelic.ini` reads both from the environment, so the daemons connect
  the application to a real collector.

## Things to know before running this

- **This mutates your local agent build state.** `run-scenario.sh` builds
  the agent via `make release-agent` (which runs `make clean` against this
  checkout's `agent/` directory) and rebuilds `bin/daemon`. If you have an
  in-progress local build you care about, commit or stash first.
- **Containers are left running** after a scenario completes (the script
  does not call `docker compose down`) — services are idle
  (`tail -f /dev/null`) between invocations so repeated runs don't pay
  container-startup cost. Run `docker compose -f compose.yaml down` when
  you're done.
- **`releases/` is untracked build output**, not part of the checked-in
  project — `git status` will show it after a build; this is expected.

## How the R1/R2 vs. R7/R8 split works

R1/R2 (external `newrelic-daemon` service) and R7/R8 (agent self-spawns, or
is forbidden to) share the same seven long-lived containers, distinguished
entirely by two small, scenario-time config toggles rather than separate
services:

- `set_external_daemon` writes `newrelic.daemon.port` to a conf.d override
  pointing at the external `newrelic-daemon:31339` service (R1/R2 only).
- `set_init_mode` touches `/etc/newrelic/newrelic.cfg` inside the container,
  which forces the agent's daemon startup mode to `INIT` (R8 only — R7 runs
  with neither toggle set).

`reset_container_state` clears both toggles (plus logs/pidfiles) before
each scenario run, so results never leak between invocations.

## Known gaps

- R1's assertion (`scenario_r1`) confirms `php -S` reports SAPI name
  `cli-server` and that the agent connected to the external daemon, but
  does not yet assert the MINIT-boundary behavior specific to
  `will_fork() == true` (the pre-fork `nr_agent_close_daemon_connection()`
  call, logged at `agent/php_minit.c:706`/`axiom/nr_agent.c:633`). That log
  line also fires unconditionally at MSHUTDOWN, so a reliable check needs
  occurrence-counting or ordering against a fixture-emitted marker, not a
  bare grep — left as a follow-up rather than risking a subtly-wrong check.
- R7 checks for the self-spawned daemon's pidfile one `compose exec`
  round-trip after the fixture exits. Only `newrelic.daemon.start_timeout
  = "2s"` in `newrelic.ini` orders that check after the write: the agent
  waits for the progenitor process (`axiom/nr_daemon_spawn.c:260`), the
  progenitor waits up to that long for the worker to listen, and the
  watcher writes the pidfile before it starts the worker. The setting
  defaults to `"0s"` (`agent/php_minit.c:662`), which makes the progenitor
  return at once; with that, or with a worker slower than 2s, the check
  races the daemon again. A bounded poll would remove the dependency.
  `reset_container_state` races the daemon in reverse: it signals the
  daemon and removes the pidfile without waiting for the process to exit,
  so a surviving daemon could let a following R8 run connect to it and
  fail misleadingly.
- Nothing waits for the `newrelic-daemon` service to be ready: `main()`
  runs `compose up -d` and goes straight into scenarios, relying on
  incidental setup latency before R1/R2 connect. A compose `healthcheck`
  plus `depends_on: condition: service_healthy`, or a bounded poll, would
  make it deterministic.
- `reset_container_state ... || true` swallows every failure, including
  the service not running, which then surfaces later as a misleading
  scenario diagnostic instead of at the point of failure.
