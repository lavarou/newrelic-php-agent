# Operate the D1/D3 topology PoC. Assumes `kubectl config current-context`
# is `rancher-desktop`. See spec.md for what's being stood up and why.
#
# NEW_RELIC_LICENSE_KEY must be set in your shell before *-up-* targets —
# it's never written to a ConfigMap or committed anywhere; see spec.md.

REPLICAS       ?= 1
D1_PORT        ?= 8081
D3_PORT        ?= 8082
D1_PHPCLI_PORT ?= 8083
D3_PHPCLI_PORT ?= 8084
# The hostPath volumes (app code, newrelic.so) need absolute paths, so the
# manifests take them relative to this checkout. Rancher Desktop mounts
# $HOME into its VM at the same path, so the checkout must live under it.
REPO_ROOT      ?= $(shell git rev-parse --show-toplevel)
export D1_PORT D3_PORT D1_PHPCLI_PORT D3_PHPCLI_PORT REPO_ROOT

.PHONY: up down \
        d1-up d1-up-frankenphp d1-up-phpcli d1-down \
        d3-up d3-up-frankenphp d3-up-phpcli d3-down \
        secret-d1 secret-d3 \
        status \
        logs-d1-frankenphp logs-d1-phpcli logs-d1-daemon logs-d1-agent-frankenphp logs-d1-agent-phpcli \
        logs-d3-frankenphp logs-d3-phpcli logs-d3-daemon-frankenphp logs-d3-daemon-phpcli logs-d3-agent-frankenphp logs-d3-agent-phpcli \
        curl-d1-frankenphp curl-d1-phpcli curl-d3-frankenphp curl-d3-phpcli \
        watch-d1 watch-d3 endpoints-d1 scale-d1-daemon clean

up: d1-up d3-up

down: d1-down d3-down

# secret-d1/secret-d3 also idempotently ensure the namespace exists, since
# they may run before the namespace's own YAML file is applied (Make
# deduplicates a shared prerequisite within one invocation, so this runs
# once per `make d1-up`, not once per sub-target).
secret-d1:
	@test -n "$(NEW_RELIC_LICENSE_KEY)" || { echo "NEW_RELIC_LICENSE_KEY is not set — export it or pass NEW_RELIC_LICENSE_KEY=... on the make command line" >&2; exit 1; }
	kubectl create namespace d1 --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic newrelic-license -n d1 --from-literal=license=$(NEW_RELIC_LICENSE_KEY) --dry-run=client -o yaml | kubectl apply -f -

secret-d3:
	@test -n "$(NEW_RELIC_LICENSE_KEY)" || { echo "NEW_RELIC_LICENSE_KEY is not set — export it or pass NEW_RELIC_LICENSE_KEY=... on the make command line" >&2; exit 1; }
	kubectl create namespace d3 --dry-run=client -o yaml | kubectl apply -f -
	kubectl create secret generic newrelic-license -n d3 --from-literal=license=$(NEW_RELIC_LICENSE_KEY) --dry-run=client -o yaml | kubectl apply -f -

# Each web stack is its own selective target so either can run alone or
# both side by side — the shared files (namespace, daemon) get applied by
# whichever sub-target runs first; kubectl apply is idempotent, so applying
# them again from the second sub-target is a harmless no-op, not a conflict.
d1-up: d1-up-frankenphp d1-up-phpcli

d1-up-frankenphp: secret-d1
	for f in d1/*.yaml; do case "$$f" in *phpcli*) continue ;; esac; envsubst '$$D1_PORT $$REPO_ROOT' < "$$f"; echo "---"; done | kubectl apply -f -

d1-up-phpcli: secret-d1
	for f in d1/*.yaml; do case "$$f" in *frankenphp*) continue ;; esac; envsubst '$$D1_PHPCLI_PORT $$REPO_ROOT' < "$$f"; echo "---"; done | kubectl apply -f -

d1-down:
	kubectl delete namespace d1 --ignore-not-found

d3-up: d3-up-frankenphp d3-up-phpcli

d3-up-frankenphp: secret-d3
	for f in d3/*.yaml; do case "$$f" in *phpcli*) continue ;; esac; envsubst '$$D3_PORT $$REPO_ROOT' < "$$f"; echo "---"; done | kubectl apply -f -

d3-up-phpcli: secret-d3
	for f in d3/*.yaml; do case "$$f" in *frankenphp*) continue ;; esac; envsubst '$$D3_PHPCLI_PORT $$REPO_ROOT' < "$$f"; echo "---"; done | kubectl apply -f -

d3-down:
	kubectl delete namespace d3 --ignore-not-found

status:
	@echo "--- d1 ---"; kubectl get pods,svc -n d1 -o wide
	@echo "--- d3 ---"; kubectl get pods,svc -n d3 -o wide

logs-d1-frankenphp:
	kubectl logs -n d1 -l app.kubernetes.io/name=frankenphp -c frankenphp --tail=50 -f --prefix

logs-d1-phpcli:
	kubectl logs -n d1 -l app.kubernetes.io/name=phpcli -c phpcli --tail=50 -f --prefix

logs-d1-daemon:
	kubectl logs -n d1 -l app.kubernetes.io/name=newrelic-daemon -c newrelic-daemon --tail=50 -f --prefix

logs-d1-agent-frankenphp:
	kubectl logs -n d1 -l app.kubernetes.io/name=frankenphp -c newrelic-agent-log --tail=50 -f --prefix

logs-d1-agent-phpcli:
	kubectl logs -n d1 -l app.kubernetes.io/name=phpcli -c newrelic-agent-log --tail=50 -f --prefix

logs-d3-frankenphp:
	kubectl logs -n d3 -l app.kubernetes.io/name=frankenphp -c frankenphp --tail=50 -f --prefix

logs-d3-phpcli:
	kubectl logs -n d3 -l app.kubernetes.io/name=phpcli -c phpcli --tail=50 -f --prefix

# D3 has two independent daemon sidecars, one per web-stack pod — unlike
# D1's single shared daemon, there's no single "logs-d3-daemon" that makes
# sense.
logs-d3-daemon-frankenphp:
	kubectl logs -n d3 -l app.kubernetes.io/name=frankenphp -c newrelic-daemon --tail=50 -f --prefix

logs-d3-daemon-phpcli:
	kubectl logs -n d3 -l app.kubernetes.io/name=phpcli -c newrelic-daemon --tail=50 -f --prefix

logs-d3-agent-frankenphp:
	kubectl logs -n d3 -l app.kubernetes.io/name=frankenphp -c newrelic-agent-log --tail=50 -f --prefix

logs-d3-agent-phpcli:
	kubectl logs -n d3 -l app.kubernetes.io/name=phpcli -c newrelic-agent-log --tail=50 -f --prefix

curl-d1-frankenphp:
	curl -sS localhost:$(D1_PORT)

curl-d1-phpcli:
	curl -sS localhost:$(D1_PHPCLI_PORT)

curl-d3-frankenphp:
	curl -sS localhost:$(D3_PORT)

curl-d3-phpcli:
	curl -sS localhost:$(D3_PHPCLI_PORT)

watch-d1:
	kubectl get pods -n d1 -w

watch-d3:
	kubectl get pods -n d3 -w

# Watch which newrelic-daemon pods are actually backing the D1 Service —
# scale-d1-daemon below to see fan-in/failover happen live against this.
endpoints-d1:
	kubectl get endpointslice -n d1 -l kubernetes.io/service-name=newrelic-daemon

scale-d1-daemon:
	kubectl scale deployment/newrelic-daemon -n d1 --replicas=$(REPLICAS)

clean: down
