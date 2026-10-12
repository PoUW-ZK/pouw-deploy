#!/usr/bin/env bash
# The only command the SSH key from GitHub Actions (Deploy workflow) may run.
# In ~/.ssh/authorized_keys on the server:
#
#   command="/home/<user>/pouw-deploy/scripts/remote.sh",restrict ssh-ed25519 AAAA... github-actions
#
# Allowed commands (arrive in SSH_ORIGINAL_COMMAND):
#   deploy <sha> [NODE_VERSION=sha-xxxxxxx ...]
#                  deploys a commit that is in origin/main (an older one = rollback)
#                  with the given service versions (without them :main from GHCR).
#                  If the new version does not start, the previous one is restored.
#   restart        restarts the services with the current version
#   status         container status and the deployed version
set -euo pipefail

cd "$(dirname "$0")/.."
read -r -a args <<<"${SSH_ORIGINAL_COMMAND:-}"
action="${args[0]:-}"

status() {
    echo "Deployed version: $(git rev-parse HEAD)"
    [[ -s versions.env ]] && cat versions.env
    docker compose ps --format 'table {{.Service}}\t{{.Status}}'
}

deploy() {
    local sha="${1:-}" prev v
    shift || true
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "deploy needs a full commit SHA" >&2
        exit 2
    fi
    for v in "$@"; do
        if [[ ! "$v" =~ ^(NODE|INDEXER|WORKLOAD|DASHBOARD)_VERSION=sha-[0-9a-f]{7}$ ]]; then
            echo "Invalid service version: $v" >&2
            exit 2
        fi
    done
    git fetch -q origin main
    if ! git merge-base --is-ancestor "$sha" origin/main; then
        echo "Commit $sha is not in main" >&2
        exit 2
    fi

    prev="$(git rev-parse HEAD)"
    cp versions.env versions.env.prev 2>/dev/null || : >versions.env.prev
    git checkout -q --detach "$sha"
    # The Makefile loads versions.env, so the versions also apply to `make restart`
    printf '%s\n' "$@" >versions.env
    if ! make up; then
        echo "Deploy failed, restoring the previous version $prev" >&2
        git checkout -q --detach "$prev"
        mv -f versions.env.prev versions.env
        make up || true
        echo "$(date -u +%FT%TZ) $sha failed, rolled back to $prev" >>deploy-history.log
        exit 1
    fi
    echo "$(date -u +%FT%TZ) $sha $*" >>deploy-history.log
}

case "$action" in
    deploy)
        deploy "${args[@]:1}"
        status
        ;;
    restart | status)
        ((${#args[@]} == 1)) || { echo "Too many arguments" >&2; exit 2; }
        [[ "$action" == restart ]] && make restart
        status
        ;;
    *)
        echo "Unknown command: ${action:-<empty>} (deploy <sha> [versions] | restart | status)" >&2
        exit 2
        ;;
esac
