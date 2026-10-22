# FrankenPHP + newrelic-daemon: k8s topology PoC spec

Captures the design decisions from the D1/D2/D3 topology discussion (see
[docs/daemon-connection-scenarios.md](../../../docs/daemon-connection-scenarios.md)
for the underlying MINIT/RINIT connection matrix). Goal: stand up D1 and D3
side by side on a local single-node cluster (Rancher Desktop / k3s) so their
behavior can be compared directly, before committing to one for real
deployments. D2 was ruled out earlier in the discussion (shared cgroup with
FrankenPHP, ambiguous shutdown signal, no isolation win over D3 for the same
total resource cost) and isn't part of this PoC.

## Topologies

- **D1** — `newrelic-daemon` runs as its own Deployment (`replicas: M`),
  fronted by a `ClusterIP` Service. FrankenPHP pods (`replicas: N`, N > M)
  connect to it over TCP via the Service's DNS name. No ordering guarantee
  between the two Deployments — FrankenPHP's own `readinessProbe` is the only
  safeguard against a cold-start pod hitting a not-yet-ready daemon.
- **D3** — `newrelic-daemon` runs as a **native sidecar** (`restartPolicy:
  Always` on an `initContainers` entry) inside the same pod as FrankenPHP.
  kubelet gates FrankenPHP's start on the sidecar's `readinessProbe` passing
  — a real, kubelet-enforced ordering guarantee. Transport is the Linux
  abstract Unix socket, which works because pod containers share one network
  namespace (and abstract-socket namespaces are scoped to the network
  namespace, per `network_namespaces(7)`) — no shared volume needed.

Each topology lives in its own namespace (`d1`, `d3`) so both can be applied
and run at the same time without name or label-selector collisions. The one
thing namespaces don't isolate is the LoadBalancer host-port bind (k3s's
ServiceLB binds on the shared node/VM network regardless of namespace) — D1
and D3 use different external ports (`8081` / `8082`) for exactly that
reason.

## Decisions pinned down

| Concern | D1 | D3 |
|---|---|---|
| Daemon transport | TCP via ClusterIP Service | Linux abstract socket `@newrelic` (confirmed default — see below) |
| Daemon replica count | Independent `replicas: M`, own Deployment | Implicitly = FrankenPHP's `replicas`, one sidecar per pod |
| Ordering guarantee | None structural — relies on FrankenPHP's own readinessProbe | kubelet-enforced via sidecar `restartPolicy: Always` + readinessProbe |
| Resource isolation | Full — separate pod entirely | Per-container cgroup, but same pod lifecycle |
| Curl access | `frankenphp` Service, `type: LoadBalancer`, port `${D1_PORT}` (default `8081`) | same, `${D3_PORT}` (default `8082`) |

**Daemon address — corrected after actually tracing the runtime path, not
just finding a plausibly-named function.** `NR_PHP_INI_DEFAULT_PORT`
(`agent/php_agent.h:53`) is confirmed `@newrelic` on Linux — that's the
*agent's* default and is real. `DefaultListenSocket()`
(`daemon/internal/newrelic/listener.go:53`) also returns `@newrelic`, but an
earlier pass in this doc wrongly assumed that's therefore also the
*daemon's* compiled-in default. It isn't: `defaultCfg`
(`daemon/cmd/daemon/main.go:419`) never calls it, and grepping every call
site shows it's only used by `cmd/stressor`, `cmd/client`, and tests. Tracing
the real path (`worker.go:131` → `listenAndServe(cfg.BindAddr, ...)` →
`parseBindAddr`, `worker.go:275`) shows an empty `BindAddr` hits
`strconv.Atoi("")`, fails, and the daemon **refuses to start** — no
TCP fallback exists in this source at all. Both topologies now pass
`--address` explicitly rather than relying on any default:
- **D1**: `--address 0.0.0.0:20080`. The host must be explicit —
  `parseBindAddr` defaults the IP to `127.0.0.1` whenever the host portion
  is empty (`worker.go:296`), which would be unreachable from the Service.
- **D3**: `--address @newrelic`.

**On the agent side the setting is `newrelic.daemon.address`.** Found by
running the PoC: the ConfigMaps first said `newrelic.daemon=...`, which is
not a registered setting, and PHP ignores unknown ini names without a
warning. D1's agents therefore fell back to `@newrelic`, got
`ECONNREFUSED`, found no `/usr/bin/newrelic-daemon` to spawn, and logged
"New Relic PHP Agent globally disabled". D3 was unaffected only because
`@newrelic` is the default.

**`--port` is a dead flag — do not use it.** `BindPort` (`--port`) is parsed
into the config struct (`main.go:62`) but never read anywhere else in the
codebase; `listenAndServe` only ever consumes `cfg.BindAddr` (`--address`,
or the legacy `-P`). The daemon silently accepts `--port` and does nothing
with it. Both manifests originally used `--port` for exactly this reason —
fixed to `--address` above.

**Whatever the `newrelic/php-daemon:latest` image defaults to when given
neither flag is still unverified.** Since the Go binary itself has no
usable fallback, the image's default `CMD`/config must be supplying
something — see Known gap 3 below. Both topologies now sidestep this by
never relying on it.

**App code, ini, and the extension binary** are delivered via `hostPath`
volumes (single-node Rancher Desktop cluster, `$HOME` is bind-mounted
into the VM by default; the Makefile fills in `${REPO_ROOT}` with this
checkout's path) and one `ConfigMap` per namespace for `newrelic.ini`
(content differs per topology — the `newrelic.daemon.address` line above). None of
this is how a real multi-node deployment would ship code or the extension —
see Known gaps.

**Container startup**: neither image needs a `command:` override.
`newrelic-daemon` needs `args:` only (its own `ENTRYPOINT` is presumably
already the daemon binary — confirm with `docker inspect
newrelic/php-daemon:latest --format '{{.Config.Entrypoint}}'` before
relying on this). `dunglas/frankenphp`'s default `CMD` already serves
`/app/public` via its built-in Caddyfile — confirmed directly by running the
image.

**Daemon process mode differs by topology, and is not optional.** The
daemon's true default (neither flag) is `RoleProgenitor`
(`daemon/cmd/daemon/main.go:486`) — it double-forks a detached Watcher+Worker
and exits, which is broken as a container's PID 1 (the container ends the
moment PID 1 exits). One of the two flags below is required in both
topologies:

- **D1 → `--foreground`.** Daemon crashes become ordinary, visible
  container restarts (`RESTARTS` count, `CrashLoopBackOff` protection) —
  exactly what you want on a dedicated daemon Deployment already fronted by
  a Service that tolerates one replica blipping.
- **D3 → `--watchdog-foreground`.** The in-container Watcher absorbs worker
  crashes without the sidecar container itself restarting — because pod
  readiness is the AND of every container, a `--foreground`-style container
  restart on the sidecar would drag the co-located, otherwise-healthy
  FrankenPHP container's readiness down with it. Trades away daemon-specific
  crash visibility (no restart count bump) for not destabilizing the app
  pod on a transient daemon crash.

**Labels follow the k8s "Recommended Labels" convention**
(`app.kubernetes.io/name` / `/component` / `/part-of`), not a bare `app:`
key. `name` distinguishes `newrelic-daemon` from `frankenphp` and is the
only key used in selectors (`spec.selector.matchLabels` /
`Service.spec.selector`) — kept minimal deliberately. `component`
(`daemon` vs `web`) and `part-of` (`frankenphp-daemon-poc`, shared across
both Deployments in D1 and the one in D3) are descriptive only, not used
for selection. D3's single pod can't express the sidecar's own
`component: daemon` at the pod-label level — pod labels apply to every
container in the pod — so it stays `web` throughout, with the daemon
sidecar remaining distinguishable only at the container level (`-c
newrelic-daemon`).

**PHP agent logs get their own `newrelic-agent-log` sidecar, in both
topologies.** Redirecting to stdout (as the daemon does via
`/proc/self/fd/1`) was considered and rejected — `frankenphp`'s own stdout
already carries FrankenPHP's request/server logs, and mixing the agent's
logs into that same stream would defeat being able to view them separately.
Instead: `newrelic.logfile` points at `/var/log/newrelic/newrelic-agent.log`
on a shared `emptyDir` volume (`/tmp` is private per-container, not shared),
and a small `busybox` container mounts the same volume and runs `tail -f`
against it — giving the agent's log its own `kubectl logs -c
newrelic-agent-log` stream, distinct from both `frankenphp` and (in D3)
`newrelic-daemon`. It's a plain `containers:` entry, not an
initContainer/native-sidecar — there's no ordering dependency to express —
and deliberately carries no `readinessProbe`, since a passive log-tailer
should never be able to drag the whole pod's readiness down.

## A second "web" component: `php -S`, alongside FrankenPHP, not replacing it

Both topologies now carry a second, independent `phpcli` Deployment +
Service next to the existing `frankenphp` one — added, not cloned, per
namespace: it reuses the shared daemon (D1) or the same native-sidecar
*pattern* (D3, necessarily its own copy — see below), the same `app-code`
hostPath volume, and the same `newrelic-agent-log` sidecar approach. Each
web stack has its own selective `make d1-up-frankenphp` / `make
d1-up-phpcli` target (and the D3 equivalents), composed together by the
plain `d1-up`/`d3-up` targets — `kubectl apply` being idempotent means the
shared files simply get re-applied harmlessly when both run. (Found by
smoke test: `logs-d3-daemon` was missed when the other D3 targets were
split per-web-stack — D3 has two independent daemon sidecars, one per pod,
so it needed the same split. D1's `logs-d1-daemon` stays singular
correctly — one shared daemon Deployment, no ambiguity there.)

**`php -S` is not "FrankenPHP without extra features" at the connection
level — it's categorically the same as Apache prefork/FPM, not CLI.**
`sapi_module.name` for the CLI built-in web server is `"cli-server"`, not
plain `"cli"` (`agent/php_minit.c:438-439`'s own comment says so).
`nr_php_process_may_fork()` only special-cases literal `"cli"` and (under
ZTS) `"frankenphp"` — everything else, `cli-server` included, falls through
to `return true` (`php_minit.c:462-474`), confirmed independently of
`docs/daemon-connection-scenarios.md`'s own R1 row, which already listed
`cli-server` alongside Apache prefork and FPM. Practically: unlike
FrankenPHP (connects once at MINIT, holds the fd for the process's life),
`php -S` reconnects to the daemon on **every request**, for the entire time
that one long-running process serves traffic — despite never actually
forking a new OS process the way prefork/FPM do. This makes it a
genuinely different, more reconnect-sensitive case worth comparing
side-by-side, and makes D3's cheap abstract-socket reconnect arguably more
valuable for it than it ever was for FrankenPHP.

**No ZTS gap for this component.** Confirmed via `docker run --rm
php:8.5-cli php -i`: `Thread Safety => disabled`, `PHP API => 20250925`,
`extension_dir => .../no-debug-non-zts-20250925` — matching the existing
`releases/linux/agent/aarch64/newrelic-20250925.so` exactly, both in API
version and thread-safety build. Unlike FrankenPHP, this one just works
with what's already on disk.

**D3's `phpcli` Deployment carries its own copy of the native-sidecar
daemon** — it's a different pod from `frankenphp`'s, so it cannot share
that pod-local sidecar. This is the one place this addition isn't pure
reuse: D1's shared, external daemon needed nothing duplicated; D3's
per-pod daemon model means every additional web-stack variant brings its
own daemon sidecar copy.

**Two ConfigMaps per namespace, not one, because `newrelic.appname` has to
differ** (`FrankenPHP D1/D3 PoC` vs `PHP-CLI D1/D3 PoC`) — everything else
in each pair is identical. Renamed `01-newrelic-ini-configmap.yaml` to
`01-frankenphp-ini-configmap.yaml` in both namespaces specifically so the
Makefile's filename-based `*frankenphp*`/`*phpcli*` filtering (used by the
selective `-up-frankenphp`/`-up-phpcli` targets) doesn't leave an unused,
mismatched ConfigMap behind as a byproduct of a single-stack deploy.

## `newrelic.license` is injected via a Secret, never hardcoded

Found by smoke test. `newrelic.license=${NEW_RELIC_LICENSE_KEY}` in all
four ini ConfigMaps is not a secret — it's a reference PHP's own ini parser
expands against the process environment. Confirmed empirically, not from
memory or docs: `docker run --rm -e MY_TEST_VAR=hello-from-env php:8.5-cli
php -d 'highlight.comment=${MY_TEST_VAR}' -i` shows the expanded value —
this is native Zend ini-parser behavior, unrelated to any New Relic-specific
code (grepped `agent/php_nrini.c` for `getenv`-style handling; there is
none). The real value lives in a `newrelic-license` Secret, one per
namespace (shared by both web stacks in that namespace — the key doesn't
vary by SAPI, only `appname` does, which already lived in the ConfigMap).
Each web-stack container reads it via `env: valueFrom: secretKeyRef`.

`make secret-d1`/`secret-d3` create/update the Secret from
`$NEW_RELIC_LICENSE_KEY` in your shell (never written to any file in this
directory) and refuse to run with a clear error if it's unset — verified
both the success and the failure path. They also idempotently ensure the
namespace exists first, since they're a prerequisite of the `-up-*` targets
and may run before `00-namespace.yaml` itself gets applied.

## Distinguishing agent logs across replicas of the same web stack

Found by smoke test: with `replicas: 3`, `newrelic-agent-log`'s `kubectl
logs -l ...` streams from all three pods interleaved, and the underlying
question — "which replica did this line come from?" — turned out to have
no answer at either layer, checked rather than assumed:

- **Viewing layer**: `kubectl logs` with a label selector matching
  multiple pods gives no per-line source indication unless asked. Fixed
  with `--prefix` on every `logs-*` target — `kubectl logs --help`
  confirms it prepends the source pod/container to each line.
- **Content layer, the deeper problem**: the agent's own log preamble
  (`util_logging.c:194-196`, `"%s (%d %d) %s: "` — timestamp, PID, TID,
  level) has no hostname field at all, and PID is actively misleading here,
  not just unhelpful — `nr_getpid()` returns `1` in every replica
  identically, since each pod has its own PID namespace and the web
  process is PID 1 in all of them. `--prefix` only helps *live* `kubectl
  logs` viewing; a file extracted via `kubectl cp` would still carry zero
  distinguishing information on its own. Fixed by injecting the pod's own
  name via the Downward API (`fieldRef: metadata.name`) as `POD_NAME`, and
  folding it into `newrelic.logfile`'s path itself:
  `newrelic-agent-${POD_NAME}.log`. `newrelic.logfile` was the right place
  for this (unlike `newrelic.appname`, which should stay identical across
  replicas of the same logical app for correct NR-backend aggregation —
  making that per-pod-unique would have fragmented one app into N in the
  UI). The `newrelic-agent-log` sidecar needed the same `POD_NAME` env var
  added too, since its `tail` command has to target the same
  now-dynamic filename. Applied identically across all four web-stack
  Deployments — FrankenPHP has the exact same PID-1-per-pod, no-hostname
  situation as `phpcli`, just not yet reported.

## Known gaps — this PoC will run, but not fully correctly, until these are closed

1. **The `frankenphp` Deployments mount a non-ZTS `newrelic.so`.** The real
   `dunglas/frankenphp` image reports `Thread Safety => enabled`,
   `PHP API => 20250925`,
   `extension_dir => /usr/local/lib/php/extensions/no-debug-zts-20250925`
   (confirmed by running the image directly). Every manifest mounts
   `releases/linux/agent/aarch64/newrelic-20250925.so` from this checkout,
   the **non-ZTS** PHP 8.5 build that `make release-agent` leaves there
   (for example in the `newrelic/nr-php-agent-builder:make-php-8.5-gnu`
   image), so build it before `make up`. For `phpcli` it is the right
   build; for `frankenphp` it is a **placeholder**: PHP treats a failed
   `dlopen()` on an incompatible extension as a startup warning, not a
   fatal error, so FrankenPHP will still start and serve requests —
   `extension_loaded('newrelic')` will just report `false` until a ZTS
   build replaces it. `../build-artifacts.sh` builds ZTS variants
   (`./build-artifacts.sh gnu zts`), but its `builder_tag` pins PHP 8.4
   (API 20240924), so either change the tag to the image's PHP version or
   pin the image to PHP 8.4 and update the `mountPath` (gap 2).
2. **`extension_dir` is pinned to `no-debug-zts-20250925`.** If you swap the
   base image or PHP version, re-run
   `docker run --rm <image> php -i | grep extension_dir` and update the
   `mountPath` in both `frankenphp` Deployments to match.
3. **`newrelic/php-daemon:latest`'s actual `ENTRYPOINT` was not inspected**
   this session — confirm with the `docker inspect` command above before
   assuming `args:`-only is sufficient; if the entrypoint isn't the daemon
   binary, you'll need `command:` too.
4. **`hostPath` is a single-node dev convenience, not a production
   pattern** — no shared node filesystem exists across a real multi-node
   cluster. Don't carry this forward past this PoC.

## Files

```
tests/daemon-connection/k8s/
├── spec.md                          (this file)
├── Makefile
├── app/
│   └── index.php                    shared demo app (hostPath-mounted into all web stacks)
├── d1/
│   ├── 00-namespace.yaml
│   ├── 01-frankenphp-ini-configmap.yaml
│   ├── 02-daemon-deployment.yaml     shared by both web stacks
│   ├── 03-daemon-service.yaml        shared by both web stacks
│   ├── 04-frankenphp-deployment.yaml
│   ├── 05-frankenphp-service.yaml
│   ├── 06-phpcli-ini-configmap.yaml
│   ├── 07-phpcli-deployment.yaml
│   └── 08-phpcli-service.yaml
└── d3/
    ├── 00-namespace.yaml
    ├── 01-frankenphp-ini-configmap.yaml
    ├── 02-frankenphp-deployment.yaml  own native-sidecar daemon
    ├── 03-frankenphp-service.yaml
    ├── 04-phpcli-ini-configmap.yaml
    ├── 05-phpcli-deployment.yaml      own, separate native-sidecar daemon
    └── 06-phpcli-service.yaml
```
