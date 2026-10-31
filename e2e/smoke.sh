#!/usr/bin/env bash
# Smoke tests of a running network: ./e2e/smoke.sh [compose project]
# Commands run inside the containers via `docker exec`, so they work without
# ports on the host and also in Jenkins, where Docker runs elsewhere.
# Checks of a service from an optional profile that does not run are skipped,
# a service without a profile that does not run is a failure.
# With JUNIT_XML=<file> the results are also written as JUnit (Tests tab in Jenkins).
set -euo pipefail

project="${1:-pouw}"
failed=0
skipped=0
tests=0
cases=""

# Text for XML: escaped and without control characters
xml() {
    tr -d '\000-\010\013\014\016-\037' |
        sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Services in profiles (compose.yml), they may be off
optional=" dashboard node-exporter cadvisor "

# Container of a running service of the project, empty when it does not run
container() {
    docker ps -q --filter "label=com.docker.compose.project=$project" \
        --filter "label=com.docker.compose.service=$1" --filter status=running | head -1
}

# check <description> <service> <shell command inside the container>
check() {
    local out name id
    id="$(container "$2")"
    name="$(printf '%s' "$1" | xml)"
    tests=$((tests + 1))
    if [[ -z "$id" && "$optional" != *" $2 "* ]]; then
        echo "FAIL  $1 ($2 does not run)"
        failed=$((failed + 1))
        cases+="  <testcase classname=\"smoke.$2\" name=\"$name\"><failure message=\"$2 does not run\"/></testcase>"$'\n'
        return
    fi
    if [[ -z "$id" ]]; then
        echo "skip  $1 ($2 does not run)"
        skipped=$((skipped + 1))
        cases+="  <testcase classname=\"smoke.$2\" name=\"$name\"><skipped message=\"$2 does not run\"/></testcase>"$'\n'
        return
    fi
    if out="$(docker exec -i "$id" sh -c "$3" 2>&1)"; then
        echo "ok    $1"
        cases+="  <testcase classname=\"smoke.$2\" name=\"$name\"/>"$'\n'
    else
        echo "FAIL  $1"
        printf '%s\n' "$out" | sed 's/^/      /'
        failed=$((failed + 1))
        cases+="  <testcase classname=\"smoke.$2\" name=\"$name\"><failure message=\"command failed\">$(printf '%s' "$out" | xml)</failure></testcase>"$'\n'
    fi
}

check "prometheus is ready" prometheus \
    'wget -qO- http://localhost:9090/-/ready'

check "prometheus scrapes its own metrics" prometheus \
    'wget -qO- "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22prometheus%22%7D" | grep -q "\"1\"\]"'

check "grafana and its database" grafana \
    'wget -qO- http://localhost:3000/api/health | grep -q "\"database\": *\"ok\""'

check "grafana connects to prometheus" grafana \
    'wget -qO- "http://admin:$(cat /run/secrets/grafana_admin_password)@localhost:3000/api/datasources/uid/prometheus/health" | grep -q "\"status\": *\"OK\""'

check "postgres accepts connections" postgres \
    'pg_isready -U pouw -d pouw'

# Dashboards as code (monitoring/grafana/dashboards), loaded at start without clicking
for uid in pouw-network pouw-services pouw-server; do
    check "grafana has the dashboard $uid" grafana \
        "wget -qO- \"http://admin:\$(cat /run/secrets/grafana_admin_password)@localhost:3000/api/dashboards/uid/$uid\" | grep -q '\"uid\":\"$uid\"'"
done

# Postgres datasource: logs in as the read-only user grafana (ADR-0008)
check "grafana reads the indexer database" grafana \
    'wget -qO- "http://admin:$(cat /run/secrets/grafana_admin_password)@localhost:3000/api/datasources/uid/indexer/health" | grep -q "\"status\": *\"OK\""'

check "the grafana database user is read-only" postgres \
    "psql -U pouw -d pouw -tAc \"SELECT rolsuper OR rolcreatedb OR rolcreaterole OR NOT ('default_transaction_read_only=on' = ANY(coalesce(rolconfig, '{}'))) OR EXISTS (SELECT FROM information_schema.role_table_grants WHERE grantee = 'grafana' AND privilege_type <> 'SELECT') FROM pg_roles WHERE rolname = 'grafana'\" | grep -qx f"

# strict: 500 when the metadata does not match the schema of the indexer
check "hasura is up and its metadata is consistent" hasura \
    'curl -fsS "http://localhost:8080/healthz?strict=true"'

check "hasura serves the api views without a token" hasura \
    "curl -fsS http://localhost:8080/v1/graphql -d '{\"query\": \"{ blocks(limit: 1) { height } }\"}' | grep -q '\"data\"'"

# Every scrape job of monitoring/prometheus/prometheus.yml is a target, also
# when its service does not run (then the target is down)
for job in prometheus pouw-node pouw-indexer pouw-workload node-exporter cadvisor; do
    check "prometheus has the target $job" prometheus \
        "wget -qO- http://localhost:9090/api/v1/targets | grep -q '\"job\":\"$job\"'"
done

# Prometheus scrapes every 15 s, so a new target waits up to ~30 s for its first scrape
for job in node-exporter cadvisor; do
    [[ -n "$(container "$job")" ]] || continue
    check "prometheus scrapes $job" prometheus \
        "for i in \$(seq 20); do wget -qO- 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22$job%22%7D' | grep -q '\"1\"\]' && exit 0; sleep 3; done; exit 1"
done

# Without the Docker and containerd sockets cAdvisor reports only cgroups, without container names
if [[ -n "$(container cadvisor)" ]]; then
    check "cadvisor sees the containers by name" prometheus \
        "for i in \$(seq 20); do wget -qO- 'http://localhost:9090/api/v1/query?query=count(container_last_seen%7Bname%3D~%22.%2B%22%7D)' | grep -q '\"result\":\[{' && exit 0; sleep 3; done; exit 1"
fi

# Network services
# TODO pouw-node#59: curl http://localhost:8000/health once the node serves its API
check "node-1 is running" node-1 'kill -0 1'

check "indexer is healthy (database reachable)" indexer \
    'curl -fsS -o /dev/null http://localhost:8000/health'

if [[ -n "$(container indexer)" ]]; then
    check "indexer applied its migrations" postgres \
        "psql -U pouw -d pouw -tAc 'SELECT count(*) FROM _sqlx_migrations WHERE success' | grep -qv '^0$'"
fi

check "workload is healthy" workload \
    'curl -fsS http://localhost:8000/health | grep -q UP'

check "dashboard serves the explorer" dashboard \
    'wget -qO /dev/null http://localhost:8080/'

if [[ -n "${JUNIT_XML:-}" ]]; then
    mkdir -p "$(dirname "$JUNIT_XML")"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"smoke\" tests=\"$tests\" failures=\"$failed\" skipped=\"$skipped\">"
        printf '%s' "$cases"
        echo '</testsuite>'
    } >"$JUNIT_XML"
fi

((failed == 0))
