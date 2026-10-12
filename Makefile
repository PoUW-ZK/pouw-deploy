SHELL := /bin/bash
.DEFAULT_GOAL := help

# Settings from .env (COMPOSE_PROFILES, SECRETS_SOURCE, SECRETS_DIR, ...)
-include .env
# Service versions on staging, written by scripts/remote.sh on deploy
-include versions.env
export

COMPOSE := docker compose
# Tests use neither profiles from .env nor ports on the host, so they do not
# collide with a running network on the same machine
TEST_PROJECT ?= pouw-test
TEST := COMPOSE_PROFILES= SECRETS_DIR=.secrets $(COMPOSE) -p $(TEST_PROJECT) -f compose.yml -f compose.test.yml

# With IMAGE_TAG, service images from `make images` are used instead of :main from GHCR
ifdef IMAGE_TAG
NODE_VERSION := $(IMAGE_TAG)
INDEXER_VERSION := $(IMAGE_TAG)
WORKLOAD_VERSION := $(IMAGE_TAG)
DASHBOARD_VERSION := $(IMAGE_TAG)
endif

.PHONY: help secrets up down restart ps logs check images test test-down

help: ## List of commands
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{ printf "  make %-10s %s\n", $$1, $$2 }'

secrets: ## Prepare secrets (random locally, from pass on the server)
	@./scripts/secrets.sh

up: secrets ## Start services according to COMPOSE_PROFILES
	$(COMPOSE) pull -q --ignore-buildable
	$(COMPOSE) up -d --build --remove-orphans --wait --wait-timeout 300

down: ## Stop services (data is kept)
	$(COMPOSE) down

restart: secrets ## Restart services, e.g. after a password change in pass
	$(COMPOSE) up -d --force-recreate --wait --wait-timeout 300

ps: ## Service status
	$(COMPOSE) ps

logs: ## Logs, e.g. make logs s=jenkins
	$(COMPOSE) logs -f --tail=200 $(s)

check: ## Validate compose for all profiles and the Prometheus config
	COMPOSE_PROFILES=jenkins,proxy $(COMPOSE) config -q
	docker run --rm -v "$(CURDIR)/monitoring/prometheus:/etc/prometheus:ro" \
		--entrypoint promtool quay.io/prometheus/prometheus:v3.0.0 \
		check config /etc/prometheus/prometheus.yml

images: ## Build service images from main, e.g. make images test IMAGE_TAG=local
	./scripts/build-images.sh

test: ## Smoke tests in a separate copy of the network (results in reports/)
	SECRETS_SOURCE=local SECRETS_DIR=.secrets ./scripts/secrets.sh
	$(TEST) up -d --wait --wait-timeout 300
	JUNIT_XML=reports/smoke.xml ./e2e/smoke.sh $(TEST_PROJECT)

test-down: ## Remove the test copy of the network
	$(TEST) down -v --remove-orphans
