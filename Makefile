SHELL := /bin/bash
.DEFAULT_GOAL := help

# Settings from .env (COMPOSE_PROFILES, SECRETS_SOURCE, SECRETS_DIR, ...)
-include .env
# Service versions on staging, written by scripts/remote.sh on deploy
-include versions.env
# The default load of the network (LOAD_SCENARIO), written by make load-start / load-stop
-include load.env
export

# Nightly dumps of the database (service backup). A path: a bare name would be
# a Docker volume
BACKUP_DIR ?= ./backups

# With IMAGE_TAG, build/skip.yml from `make images` keeps the services that have
# no image at all (neither built nor in GHCR) from starting. $(shell) and not
# $(wildcard): make caches directories at start and would miss the file that
# `make images` writes in the same run (make dev).
SKIP_FILE = $(if $(IMAGE_TAG),$(shell [ -f build/skip.yml ] && echo -f build/skip.yml))
# EDGE_NETWORK: the Docker network the Caddy of staging shares with the dev
# network on the server (compose.edge.yml); set there, never in a test copy
EDGE_FILE = $(if $(EDGE_NETWORK),-f compose.edge.yml)
COMPOSE = docker compose -f compose.yml $(SKIP_FILE) $(EDGE_FILE)
comma := ,

# The server is the place with the profile proxy. There the explorer and
# Alertmanager live next to Grafana (grafana.<domain> -> explorer.<domain>,
# alerts.<domain>) unless .env says otherwise,
# and node-exporter and cAdvisor always run, so the panels of the server and of
# the containers have data. Without it a new variable in compose would need a
# manual edit of .env on the server first.
ifneq ($(filter proxy,$(subst $(comma), ,$(COMPOSE_PROFILES))),)
EXPLORER_HOST ?= $(patsubst grafana.%,explorer.%,$(GRAFANA_HOST))
ALERTMANAGER_HOST ?= $(patsubst grafana.%,alerts.%,$(GRAFANA_HOST))
ALERTMANAGER_URL ?= https://$(ALERTMANAGER_HOST)
# ...the explorer and Grafana of the dev network (scripts/dev-setup.sh) behind
# the same Caddy, over the shared Docker network
EXPLORER_DEV_HOST ?= $(patsubst grafana.%,explorer-dev.%,$(GRAFANA_HOST))
GRAFANA_DEV_HOST ?= $(patsubst grafana.%,grafana-dev.%,$(GRAFANA_HOST))
EDGE_NETWORK ?= pouw-edge
ifeq ($(filter host-metrics,$(subst $(comma), ,$(COMPOSE_PROFILES))),)
override COMPOSE_PROFILES := $(COMPOSE_PROFILES),host-metrics
endif
# ...and the network has its default load (workload-driver)
ifeq ($(filter load,$(subst $(comma), ,$(COMPOSE_PROFILES))),)
override COMPOSE_PROFILES := $(COMPOSE_PROFILES),load
endif
endif

# SRC=.. builds the services from your working copies next to pouw-deploy
# (../pouw-node, ...) instead of main from GitHub, tags them :local and runs
# them with the `network` profile. `make dev` and `make dev-test` set it.
ifdef SRC
IMAGE_TAG ?= local
# := and not ?=: make dev runs a sub-make, which inherits E2E_SRC=build/src
# exported by the parent
E2E_SRC := $(SRC)
override COMPOSE_PROFILES := $(if $(COMPOSE_PROFILES),$(COMPOSE_PROFILES)$(comma))network
TEST_PROFILES ?= network
endif

# Tests use neither profiles from .env nor ports on the host, so they do not
# collide with a running network on the same machine. Their alerts are never
# e-mailed.
TEST_PROJECT ?= pouw-test
TEST_ENV = COMPOSE_PROFILES=$(TEST_PROFILES) SECRETS_DIR=.secrets ALERT_EMAIL=
TEST_COMPOSE = docker compose -f compose.yml $(SKIP_FILE) -f compose.test.yml -p $(TEST_PROJECT)
TEST = $(TEST_ENV) $(TEST_COMPOSE)

# e2e/run.sh of the services from these clones (made by `make images`),
# with SRC from your working copies (set above)
E2E_SRC ?= build/src

# With IMAGE_TAG, service images from `make images` are used instead of :main from GHCR
ifdef IMAGE_TAG
NODE_VERSION := $(IMAGE_TAG)
INDEXER_VERSION := $(IMAGE_TAG)
WORKLOAD_VERSION := $(IMAGE_TAG)
DASHBOARD_VERSION := $(IMAGE_TAG)
DASHBOARD_HASURA_VERSION := $(IMAGE_TAG)
endif

.PHONY: help secrets edge up down restart seed ps logs check images test test-down dev dev-test \
	backup restore-test test-alert load test-load test-up test-run test-smoke test-backup \
	test-devnet test-services load-start load-stop load-status

help: ## List of commands
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  make %-14s %s\n", $$1, $$2 }'

dev: ## Build the services from ../pouw-* and start the whole network locally
	$(MAKE) images up SRC=..

dev-test: ## Build the services from ../pouw-* and test them in a separate copy
	$(MAKE) images test SRC=..

secrets: ## Prepare secrets (random locally, from pass on the server)
	@./scripts/secrets.sh

# With IMAGE_TAG the service images are local builds that are not in GHCR,
# so only missing images (Postgres, Grafana, ...) are pulled. Prometheus reads
# its configuration and alert rules only at start, so a deploy that changes
# them without recreating the container reloads it.
up: secrets edge ## Start services according to COMPOSE_PROFILES
	@mkdir -p -m 700 "$(BACKUP_DIR)"
ifndef IMAGE_TAG
	$(COMPOSE) pull -q --ignore-buildable
endif
	$(COMPOSE) up -d --build --pull missing --remove-orphans --wait --wait-timeout 300
	$(COMPOSE) exec -T prometheus kill -HUP 1

# The shared network of compose.edge.yml, created by whichever network starts first
edge:
ifneq ($(EDGE_NETWORK),)
	@docker network inspect $(EDGE_NETWORK) >/dev/null 2>&1 || docker network create $(EDGE_NETWORK)
endif

down: ## Stop services of all profiles (data is kept)
	$(COMPOSE) down --remove-orphans

restart: secrets edge ## Restart services, e.g. after a password change in pass
	@mkdir -p -m 700 "$(BACKUP_DIR)"
	$(COMPOSE) up -d --force-recreate --wait --wait-timeout 300

seed: ## Fixture blocks of pouw-indexer into the database; never with the devnet, its sync stops
	$(COMPOSE) --profile network exec -T indexer /bin/sh -c \
		'DATABASE_URL="postgres://pouw:$$(cat /run/secrets/postgres_password)@postgres:5432/pouw" exec pouw-indexer seed'

ps: ## Service status
	$(COMPOSE) ps

logs: ## Logs of a service, e.g. make logs SERVICE=indexer [SINCE=1h] (without SERVICE all)
	$(COMPOSE) logs -f --tail=$(if $(SINCE),all --since $(SINCE),200) $(or $(SERVICE),$(s))

check: ## Validate compose, Prometheus with tests of its alerts, Alertmanager and the Caddyfile
	COMPOSE_PROFILES=jenkins,proxy,network,host-metrics,load $(COMPOSE) config -q
	sh -n scripts/load-driver.sh scripts/load-test.sh
	EDGE_NETWORK=pouw-edge COMPOSE_PROFILES=jenkins,proxy,load docker compose -f compose.yml -f compose.edge.yml config -q
	docker run --rm -v "$(CURDIR)/monitoring/prometheus:/etc/prometheus:ro" \
		--entrypoint /bin/sh quay.io/prometheus/prometheus:v3.0.0 -c \
		'promtool check config /etc/prometheus/prometheus.yml && promtool test rules /etc/prometheus/tests/*.yml'
	for email in alerts@example.org ""; do \
		docker run --rm -v "$(CURDIR)/monitoring/alertmanager:/etc/alertmanager:ro" \
			-e SMTP_HOST=smtp.example.org -e ALERT_EMAIL="$$email" \
			--entrypoint /bin/sh quay.io/prometheus/alertmanager:v0.35.0 \
			/etc/alertmanager/run.sh check || exit 1; \
	done
	# the hash comes from stdin as in proxy/run.sh, so that path is checked too
	docker run --rm -v "$(CURDIR)/proxy/Caddyfile:/etc/caddy/Caddyfile:ro" \
		-e ACME_EMAIL=admin@localhost -e JENKINS_HOST=jenkins.localhost \
		-e GRAFANA_HOST=grafana.localhost -e EXPLORER_HOST=explorer.localhost \
		-e ALERTMANAGER_HOST=alerts.localhost -e ALERTMANAGER_USER=admin \
		-e EXPLORER_DEV_HOST=explorer-dev.localhost -e GRAFANA_DEV_HOST=grafana-dev.localhost \
		--entrypoint /bin/sh caddy:2 -c \
		'ALERTMANAGER_HASH="$$(echo check | caddy hash-password)" && export ALERTMANAGER_HASH && \
		caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile'

images: ## Build service images from main (or SRC=..), e.g. make images test IMAGE_TAG=local
	./scripts/build-images.sh

backup: ## Dump the database into BACKUP_DIR now (the service backup does it every night)
	$(COMPOSE) exec -T backup bash /backup.sh once

restore-test: ## Trial restore of the newest dump into a separate database (DUMP=<file> another)
	./scripts/restore.sh $(DUMP)

test-alert: ## Send a test alert; with SMTP_HOST and ALERT_EMAIL it arrives by e-mail
	$(COMPOSE) exec -T alertmanager amtool alert add alertname=PouwTestAlert severity=info \
		--annotation=summary="Test alert from make test-alert" --alertmanager.url=http://localhost:9093

# Test groups, in this order: smoke, backup (a dump and a trial restore of it,
# so a backup that cannot be restored fails the nightly build), devnet (e2e of
# the whole network) and services (e2e/run.sh of every service). A failure of
# smoke or backup stops the run, the e2e groups all run and fail at the end.
#
#   make test SUITES=devnet,services     only some groups
#   make test SERVICES=node,indexer      only the e2e of these services
#   make test TESTS="height or transfer" only the pytest tests that match (-k)
#
# Rerunning against one copy: make test-up, then make test-devnet TESTS=...
# as often as needed, then make test-down.
SUITES ?= smoke,backup,devnet,services
SERVICES ?=
TESTS ?=
# pytest in every e2e/run.sh reads it (passed into its container)
ifneq ($(TESTS),)
export PYTEST_ADDOPTS = -k "$(TESTS)"
endif
SUITE_ORDER = smoke backup devnet services

test: test-up test-run ## Smoke and e2e tests in a separate copy of the network (results in reports/)

# Without IMAGE_TAG the test copy runs :main from GHCR, pulled first, so not an
# old image that happens to be cached.
test-up: ## Start the test copy of the network (make test without the tests)
	SECRETS_SOURCE=local SECRETS_DIR=.secrets ./scripts/secrets.sh
ifndef IMAGE_TAG
	$(TEST) pull -q --ignore-buildable
endif
	$(TEST) up -d --wait --wait-timeout 300

test-run: ## The groups of SUITES against the running test copy
	@for s in $(subst $(comma), ,$(SUITES)); do \
		[[ " $(SUITE_ORDER) " == *" $$s "* ]] || { echo "Unknown suite: $$s (one of: $(SUITE_ORDER))" >&2; exit 2; }; \
	done; \
	failed=0; \
	for s in $(SUITE_ORDER); do \
		[[ ",$(SUITES)," == *",$$s,"* ]] || continue; \
		case $$s in \
			smoke | backup) $(MAKE) --no-print-directory test-$$s || exit 1 ;; \
			*) $(MAKE) --no-print-directory test-$$s || failed=1 ;; \
		esac; \
	done; \
	exit $$failed

test-smoke: ## Smoke tests of the running test copy (reports/smoke.xml)
	JUNIT_XML=reports/smoke.xml ./e2e/smoke.sh $(TEST_PROJECT)

test-backup: ## Dump of the running test copy and a trial restore of it
	$(TEST) exec -T backup bash /backup.sh once
	$(TEST_ENV) COMPOSE="$(TEST_COMPOSE)" ./scripts/restore.sh

test-devnet: ## e2e tests of the devnet against the running test copy (TESTS=<pytest -k>)
	@echo "== e2e/run.sh (the devnet)"
	JUNIT_DIR=reports ./e2e/run.sh $(TEST_PROJECT)

test-services: ## e2e tests of the services against the running test copy (SERVICES=node,indexer)
	@want=""; \
	for s in $(subst $(comma), ,$(SERVICES)); do \
		s="pouw-$${s#pouw-}"; \
		[ -x "$(E2E_SRC)/$$s/e2e/run.sh" ] || { echo "Unknown service $$s: no $(E2E_SRC)/$$s/e2e/run.sh" >&2; exit 2; }; \
		want+=" $$s"; \
	done; \
	failed=0; found=0; \
	for t in $(E2E_SRC)/*/e2e/run.sh; do \
		[ -x "$$t" ] || continue; \
		repo="$$(basename "$$(dirname "$$(dirname "$$t")")")"; \
		[[ -z "$$want" || "$$want " == *" $$repo "* ]] || continue; \
		found=1; echo "== $$t"; \
		JUNIT_DIR=reports "$$t" $(TEST_PROJECT) || failed=1; \
	done; \
	[ $$found = 1 ] || echo "WARNING: no e2e/run.sh in $(E2E_SRC)/*, the e2e tests of the services did not run"; \
	exit $$failed

test-down: ## Remove the test copy of the network
	$(TEST) down -v --remove-orphans

# Load tests with pouw-workload, report in reports/load (scripts/load-test.sh).
# Scenarios: transfers-steady, transfers-spike, transfers, devnet, smoke, soak.
SCENARIO ?= devnet
# The running network: pouw (staging), pouw-dev in the checkout of the dev network
LOAD_PROJECT ?= $(or $(COMPOSE_PROJECT_NAME),pouw)

load: ## Load test on the running network (staging); watch it in Grafana: PoUW · Load test
	./scripts/load-test.sh $(LOAD_PROJECT) $(SCENARIO)

# The default load of the running network: workload-driver runs LOAD_SCENARIO
# from load.env again and again (scripts/load-driver.sh). Recreating it stops
# the current scenario, so a switch takes effect at once. LOAD_SCENARIO is
# given explicitly, make has exported the old value from load.env.
load-start: ## Switch the default load of the running network to SCENARIO=<name> (repeats)
ifeq ($(origin SCENARIO),file)
	$(error Which scenario? make load-start SCENARIO=transfers-steady (transfers-spike, transfers, devnet, smoke, soak))
endif
	@[[ "$(SCENARIO)" =~ ^[a-z0-9-]+$$ ]] || { echo "Invalid scenario name: $(SCENARIO)" >&2; exit 2; }
	echo "LOAD_SCENARIO=$(SCENARIO)" >load.env
	LOAD_SCENARIO=$(SCENARIO) $(COMPOSE) --profile load up -d --force-recreate --no-deps workload-driver

load-stop: ## Turn the default load of the running network off (until load-start)
	echo "LOAD_SCENARIO=off" >load.env
	LOAD_SCENARIO=off $(COMPOSE) --profile load up -d --force-recreate --no-deps workload-driver

load-status: ## The default load and what the generator of the running network runs now
	@echo "Default load: $${LOAD_SCENARIO:-transfers-steady}$$([ -s load.env ] || echo ' (no load.env)')"
	@$(COMPOSE) --profile load ps --format '{{.Service}}: {{.Status}}' workload-driver | grep . || echo "workload-driver: does not run"
	@$(COMPOSE) exec -T workload curl -fsS http://localhost:8000/api/v1/status; echo

test-load: test-up ## Load test in a separate network copy, like the Jenkins job PouwZK-dev/load-test
	GRAFANA_URL= ./scripts/load-test.sh $(TEST_PROJECT) $(SCENARIO)
