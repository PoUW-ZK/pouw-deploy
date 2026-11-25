#!/usr/bin/env bash
# Sets up the dev network on the server, next to staging. Run once from the
# checkout of staging, as the user the networks run under (no sudo):
#
#   ./scripts/dev-setup.sh
#
# The dev network is a second checkout ../pouw-deploy-dev, compose project
# pouw-dev, with its own volumes, random secrets in its .secrets and other
# ports on 127.0.0.1. Nobody gets its alerts. Its nodes mine with a quarter of
# the CPU weight of staging (NODE_CPU_SHARES), so they give way when cores are
# busy. The Caddy of staging serves it on explorer-dev.<domain> and
# grafana-dev.<domain> over the Docker network pouw-edge (compose.edge.yml).
# Jenkins (PouwZK-dev) deploys branches there through the Deploy workflow:
# remote.sh dev deploy <sha> ... Safe to re-run, an existing .env is kept.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dev="$(cd "$root/.." && pwd)/pouw-deploy-dev"

grafana_host="$(sed -n 's/^GRAFANA_HOST=//p' "$root/.env")"
domain="${grafana_host#grafana.}"
if [[ -z "$grafana_host" || "$domain" == "$grafana_host" ]]; then
    echo "GRAFANA_HOST=grafana.<domain> is not in $root/.env" >&2
    exit 1
fi

if [[ ! -d "$dev/.git" ]]; then
    git clone -q "$(git -C "$root" remote get-url origin)" "$dev"
fi

if [[ ! -s "$dev/.env" ]]; then
    cat >"$dev/.env" <<EOF
# The dev network (scripts/dev-setup.sh in the checkout of staging)
COMPOSE_PROJECT_NAME=pouw-dev
COMPOSE_PROFILES=load
EDGE_NETWORK=pouw-edge
SECRETS_SOURCE=local
SECRETS_DIR=.secrets
GRAFANA_URL=https://grafana-dev.$domain/
NODE_CPU_SHARES=256
# A new chain (devnet-reset) starts 8 times easier than pouw-node's target, see devnet/genesis.sh
DEVNET_INITIAL_TARGET=000001ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
BACKUP_DIR=./backups
# Next to the ports of staging, all on 127.0.0.1
PROMETHEUS_PORT=19090
ALERTMANAGER_PORT=19093
GRAFANA_PORT=13000
HASURA_PORT=18081
INDEXER_PORT=18083
DASHBOARD_PORT=18082
EOF
    echo "Wrote $dev/.env"
fi

cd "$dev"
git fetch -q origin main
if [[ -z "$(docker compose ps -q 2>/dev/null)" ]]; then
    git checkout -q --detach origin/main
    make up
fi
echo
echo "The dev network runs: https://explorer-dev.$domain, https://grafana-dev.$domain"
echo "Grafana admin password: $dev/.secrets/grafana_admin_password"
