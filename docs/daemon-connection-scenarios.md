# Agent/daemon connection scenarios

This documents every distinct code path for how the agent connects to the
`newrelic-daemon`, from MINIT through RINIT/transaction-begin, across SAPIs
and daemon-reachability states. Verified against source in
`agent/php_minit.c`, `axiom/nr_agent.c`, `agent/php_txn.c`, and
`daemon/cmd/daemon/*.go`.

## Schema

| Column | What it captures |
|---|---|
| **MINIT connect outcome** | `Connected` / `In-progress` (`EINPROGRESS`/`EALREADY`, fd stays allocated) / `Failed` (fd closed, reset to `-1`) — the 3-way result of `nr_agent_try_daemon_connect()` |
| **Daemon startup mode** | `AGENT` (agent may spawn) / `INIT` (won't spawn) — from `nr_php_get_daemon_startup_mode()`; only actually matters when connect outcome ≠ `Connected` |
| **Will fork?** | `nr_php_process_will_fork()` — derived from SAPI (`true` for everything except CLI/FrankenPHP-ZTS) |
| **Spawn attempted?** | derived: only `Yes` when outcome ≠ `Connected` AND mode = `AGENT` |
| **fd state entering RINIT** | what `nr_agent_daemon_fd`/`nr_agent_connection_state` actually is once MINIT finishes |
| **First RINIT/txn-begin behavior** | No-op / fresh `connect()` / resume in-progress handshake |
| **Example SAPI(s)** | concrete instances of this row |

## Core MINIT-boundary matrix

| ID | Connect outcome | Startup mode | Will fork? | Spawn attempted? | fd entering RINIT | RINIT behavior | Example SAPI(s) |
|---|---|---|---|---|---|---|---|
| R1 | Connected | n/a | true | No | closed → `-1` | real fresh `connect()` | Apache prefork, FPM, `cli-server`, unknown SAPIs |
| R2 | Connected | n/a | false | No | kept, `CONNECTED` | no-op (early return) | CLI, FrankenPHP/ZTS |
| R3 | In-progress | AGENT | true | **Yes** (racing against its own pending connect) | closed mid-handshake → `-1` | real fresh `connect()` (new socket) | any will-fork SAPI + agent-managed daemon that's slow to accept |
| R4 | In-progress | AGENT | false | **Yes** (racing) | kept, `IN_PROGRESS` | resumes handshake on same fd | CLI/FrankenPHP + agent-managed + slow daemon |
| R5 | In-progress | INIT | true | No | closed mid-handshake → `-1` | real fresh `connect()` | will-fork SAPI + externally-managed daemon, slow to accept |
| R6 | In-progress | INIT | false | No | kept, `IN_PROGRESS` | resumes handshake on same fd | CLI/FrankenPHP + externally-managed, slow daemon |
| R7 | Failed (refused) | AGENT | true / false (irrelevant — fd already `-1`) | **Yes** | `-1` (already reset before close-decision runs) | real fresh `connect()` | any SAPI, daemon not running yet, agent spawns it |
| R8 | Failed (refused) | INIT | true / false (irrelevant) | No | `-1` | real fresh `connect()`, succeeds once/if external daemon comes up | any SAPI, externally-managed daemon not up yet |

R7 and R8 collapse the will-fork axis because closing an already-`-1` fd is
a no-op regardless — the code path differs (one calls
`nr_agent_close_daemon_connection()`, one doesn't) but the observable effect
is identical.

## Orthogonal cases

These apply independently of the MINIT-boundary matrix above.

| ID | Case | Trigger | Effect |
|---|---|---|---|
| O1 | Mid-request daemon RPC failure | Any failed `nr_cmd_appinfo_tx`/`nr_cmd_txndata_tx`/`nr_cmd_span_batch_tx`, any SAPI, any time | Immediate close (`nr_agent_close_daemon_connection()`); next `nr_get_daemon_fd()` call — same or later request — does a fresh reconnect |
| O2 | MSHUTDOWN | Every process, unconditionally, on shutdown | Unconditional close; no reconnect follows (process is exiting) |
| O3 | Threaded Apache MPM | `is_apache && apache_threaded` | Agent disables itself at MINIT before any daemon-connect code runs at all — zero rows above ever apply |

## Daemon-side spawn collision guard

Rows R3, R4, and R7 involve the agent attempting to spawn a daemon that may
already be starting or running (e.g. spawned by another PHP process racing
the same startup window). The daemon guards against this itself: the
Watcher process acquires an exclusive `fcntl` lock on the pid file
(`daemon/internal/newrelic/pidfile.go`) before doing anything else. A
redundant daemon process that loses the race gets `ErrLocked` and exits
immediately and silently (`daemon/cmd/daemon/main.go`), so a spawn attempt
in R3/R4/R7 is always safe even when it turns out to be unnecessary.
