#!/usr/bin/env bash
# Smoke tests of a running network: ./e2e/smoke.sh [compose project]
# Commands run inside containers via `docker compose exec`, so they work
# without ports on the host and also in Jenkins, where Docker runs elsewhere.
# With JUNIT_XML=<file> the results are also written as JUnit (Tests tab in Jenkins).
set -euo pipefail

project="${1:-pouw}"
failed=0
tests=0
cases=""

# Text for XML: escaped and without control characters
xml() {
    tr -d '\000-\010\013\014\016-\037' |
        sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# check <description> <service> <shell command inside the container>
check() {
    local out name
    tests=$((tests + 1))
    name="$(printf '%s' "$1" | xml)"
    if out="$(docker compose -p "$project" exec -T "$2" sh -c "$3" 2>&1)"; then
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

if [[ -n "${JUNIT_XML:-}" ]]; then
    mkdir -p "$(dirname "$JUNIT_XML")"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"smoke\" tests=\"$tests\" failures=\"$failed\">"
        printf '%s' "$cases"
        echo '</testsuite>'
    } >"$JUNIT_XML"
fi

((failed == 0))
