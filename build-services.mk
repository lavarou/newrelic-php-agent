# PHPs supported by composer build services
PHPS=7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3
SERVICES=go redisdb mysqldb $(addprefix php-,$(PHPS))

# Shell user - default to `root`, can be overriden to `root`
SHELL_USER=root

start:
	@test -z $$PULL || docker compose -f build-services.yml pull $(SERVICES)
	docker compose -f build-services.yml up --remove-orphans -d $(SERVICES)

stop:
	docker compose -f build-services.yml stop

exec:
	@test -z $$PHP && { echo "Please provide PHP version with PHP=<VERSION>"; exit 2; } || true
	@test -z $$CMD && { echo "Please provide CMD to run with CMD=<target>"; exit 2; } || true
	@docker compose -f build-services.yml exec php-${PHP} $(CMD) $(ARGS)

.PHONY: shell
shell:
	@test -z $$PHP && { echo "Please provide PHP version with PHP=<VERSION>"; exit 2; } || \
	docker compose -f build-services.yml exec --user $(SHELL_USER) -it php-$${PHP} /bin/bash

bin/integration_runner:
	docker compose -f build-services.yml exec go make bin/integration_runner

build-integration-runner: bin/integration_runner
	

build-agent: build-integration-runner
	@for PHP in $(PHPS); do \
		echo "=====[php-$${PHP}]======"; \
		ver=`echo $$PHP | cut -d '-' -f 1`; \
		docker compose -f build-services.yml exec php-$${ver} make agent; \
		echo "Saving agent/modules/newrelic.so to ./newrelic-for-php-$${ver}.so"; \
		cp agent/modules/newrelic.so "./newrelic-for-php-$${ver}.so"; \
		docker compose -f build-services.yml exec php-$${ver} make agent-clean; \
	done

LOGLEVEL=info
run-tests:
	@for PHP in $(PHPS); do \
		echo "=====[php-$${PHP}]======"; \
		ver=`echo $$PHP | cut -d '-' -f 1`; \
		docker compose -f build-services.yml --env-file integration-tests.env exec php-$${ver} bin/integration_runner -agent ./newrelic-for-php-$${ver}.so -loglevel $(LOGLEVEL) $$TESTS; \
	done
