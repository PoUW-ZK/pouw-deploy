SHELL := /bin/bash
.DEFAULT_GOAL := help

# Settings from .env (COMPOSE_PROFILES, SECRETS_SOURCE, SECRETS_DIR, ...)
-include .env
# Service versions on staging, written by scripts/remote.sh on deploy
-include versions.env
export

# Nightly dumps of the database (service backup). A path: a bare name would be
# a Docker volume
BACKUP_DIR ?= ./backups

# With IMAGE_TAG, build/skip.yml from `make images` keeps the services that have
# no image at all (neither built nor in GHCR) from starting. $(shell) and not
# $(wildcard): make caches directories at start and would miss the file that
# `make images` writes in the same run (make dev).
SKIP_FILE = $(if $(IMAGE_TAG),$(shell [ -f build/skip.yml ] && echo -f build/skip.yml))
COMPOSE = docker compose -f compose.yml $(SKIP_FILE)
comma := ,

# The server is the place with the profile proxy. There the explorer lives next
# to Grafana (grafana.<domain> -> explorer.<domain>) unless .env says otherwise,
# and node-exporter and cAdvisor always run, so the panels of the server and of
# the containers have data. Without it a new variable in compose would need a
# manual edit of .env on the server first.
ifneq ($(filter proxy,$(subst $(comma), ,$(COMPOSE_PROFILES))),)
EXPLORER_HOST ?= $(patsubst grafana.%,explorer.%,$(GRAFANA_HOST))
ifeq ($(filter host-metrics,$(subst $(comma), ,$(COMPOSE_PROFILES))),)
override COMPOSE_PROFILES := $(COMPOSE_PROFILES),host-metrics
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
TEST_COMPOSE = $(COMPOSE) -f compose.test.yml -p $(TEST_PROJECT)
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

.PHONY: help secrets up down restart seed ps logs check images test test-down dev dev-test \
	backup restore-test test-alert load test-load

help: ## List of commands
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  make %-12s %s\n", $$1, $$2 }'

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
up: secrets ## Start services according to COMPOSE_PROFILES
	@mkdir -p -m 700 "$(BACKUP_DIR)"
ifndef IMAGE_TAG
	$(COMPOSE) pull -q --ignore-buildable
endif
	$(COMPOSE) up -d --build --pull missing --remove-orphans --wait --wait-timeout 300
	$(COMPOSE) exec -T prometheus kill -HUP 1

down: ## Stop services of all profiles (data is kept)
	$(COMPOSE) down --remove-orphans

restart: secrets ## Restart services, e.g. after a password change in pass
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
	COMPOSE_PROFILES=jenkins,proxy,network,host-metrics $(COMPOSE) config -q
	docker run --rm -v "$(CURDIR)/monitoring/prometheus:/etc/prometheus:ro" \
		--entrypoint /bin/sh quay.io/prometheus/prometheus:v3.0.0 -c \
		'promtool check config /etc/prometheus/prometheus.yml && promtool test rules /etc/prometheus/tests/*.yml'
	for email in alerts@example.org ""; do \
		docker run --rm -v "$(CURDIR)/monitoring/alertmanager:/etc/alertmanager:ro" \
			-e SMTP_HOST=smtp.example.org -e ALERT_EMAIL="$$email" \
			--entrypoint /bin/sh quay.io/prometheus/alertmanager:v0.35.0 \
			/etc/alertmanager/run.sh check || exit 1; \
	done
	docker run --rm -v "$(CURDIR)/proxy/Caddyfile:/etc/caddy/Caddyfile:ro" \
		-e ACME_EMAIL=admin@localhost -e JENKINS_HOST=jenkins.localhost \
		-e GRAFANA_HOST=grafana.localhost -e EXPLORER_HOST=explorer.localhost \
		caddy:2 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

images: ## Build service images from main (or SRC=..), e.g. make images test IMAGE_TAG=local
	./scripts/build-images.sh

backup: ## Dump the database into BACKUP_DIR now (the service backup does it every night)
	$(COMPOSE) exec -T backup bash /backup.sh once

restore-test: ## Trial restore of the newest dump into a separate database (DUMP=<file> another)
	./scripts/restore.sh $(DUMP)

test-alert: ## Send a test alert; with SMTP_HOST and ALERT_EMAIL it arrives by e-mail
	$(COMPOSE) exec -T alertmanager amtool alert add alertname=PouwTestAlert severity=info \
		--annotation=summary="Test alert from make test-alert" --alertmanager.url=http://localhost:9093

# A dump and a trial restore of it run every time, so a backup that cannot be
# restored fails the nightly build. Without IMAGE_TAG the test copy runs :main
# from GHCR, pulled first, so not an old image that happens to be cached.
test: ## Smoke and e2e tests in a separate copy of the network (results in reports/)
	SECRETS_SOURCE=local SECRETS_DIR=.secrets ./scripts/secrets.sh
ifndef IMAGE_TAG
	$(TEST) pull -q --ignore-buildable
endif
	$(TEST) up -d --wait --wait-timeout 300
	JUNIT_XML=reports/smoke.xml ./e2e/smoke.sh $(TEST_PROJECT)
	$(TEST) exec -T backup bash /backup.sh once
	$(TEST_ENV) COMPOSE="$(TEST_COMPOSE)" ./scripts/restore.sh
	@failed=0; \
	echo "== e2e/run.sh (the devnet)"; \
	JUNIT_DIR=reports ./e2e/run.sh $(TEST_PROJECT) || failed=1; \
	found=0; for t in $(E2E_SRC)/*/e2e/run.sh; do \
		[ -x "$$t" ] || continue; \
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

load: ## Load test on the running network (staging); watch it in Grafana: PoUW · Load test
	./scripts/load-test.sh pouw $(SCENARIO)

test-load: ## Load test in a separate network copy, like the Jenkins job pouw-load-test
	SECRETS_SOURCE=local SECRETS_DIR=.secrets ./scripts/secrets.sh
ifndef IMAGE_TAG
	$(TEST) pull -q --ignore-buildable
endif
	$(TEST) up -d --wait --wait-timeout 300
	GRAFANA_URL= ./scripts/load-test.sh $(TEST_PROJECT) $(SCENARIO)
