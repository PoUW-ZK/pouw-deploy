#!/usr/bin/env bash
# Deploys the tested version to staging via the Deploy workflow and waits for the result.
# Called by Jenkins after a successful evening test:
#
#   GH_TOKEN=<token GitHub App> ./scripts/staging-deploy.sh <sha pouw-deploy>
#
# Service versions come from build/versions.env (scripts/build-images.sh).
# The GitHub App needs the Actions: Read and write permission.
set -euo pipefail

sha="$1"
repo="PoUW-ZK/pouw-deploy"
api="https://api.github.com/repos/$repo/actions"
versions="$(paste -sd ' ' build/versions.env)"

gh_api() {
    curl -fsS -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" "$@"
}

# Dispatch does not return a run ID, so the run is found by its start time
since="$(date -u -d '1 minute ago' +%FT%TZ)"
jq -n --arg sha "$sha" --arg versions "$versions" \
    '{ref: "main", inputs: {action: "deploy", sha: $sha, versions: $versions}}' |
    gh_api -X POST "$api/workflows/deploy.yml/dispatches" --data @-
echo "Deploying $sha $versions"

run=""
for _ in $(seq 30); do
    sleep 10
    run="$(gh_api "$api/workflows/deploy.yml/runs?event=workflow_dispatch&created=%3E%3D$since" |
        jq -r '.workflow_runs[0].id // empty')"
    [[ -n "$run" ]] && break
done
[[ -n "$run" ]] || { echo "Deploy workflow run not found" >&2; exit 1; }
echo "Deploy: https://github.com/$repo/actions/runs/$run"

while :; do
    read -r state conclusion < <(gh_api "$api/runs/$run" | jq -r '"\(.status) \(.conclusion)"')
    [[ "$state" == completed ]] && break
    sleep 15
done
echo "Result: $conclusion"
[[ "$conclusion" == success ]]
