#!/bin/sh
set -eu

base=http://workload:8000
started=$(date +%s)
curl -fsS -X POST -H 'Content-Type: application/json' \
    -d '{"scenario_name":"soak"}' "$base/api/v1/start"
echo

while :; do
    status=$(curl -fsS "$base/api/v1/status")
    now=$(date +%s)
    if echo "$status" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"error"'; then
        echo "Soak failed: $status" >&2
        exit 1
    fi
    if echo "$status" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"stopped"'; then
        if [ $((now - started)) -lt 3600 ]; then
            echo "Soak stopped before one hour" >&2
            exit 1
        fi
        break
    fi
    if [ $((now - started)) -gt 3900 ]; then
        echo "Soak timed out: $status" >&2
        exit 1
    fi
    sleep 10
done

curl -fsS "$base/api/v1/results" | awk -F, '
    NR > 1 { completed += $2; failures += $3; rejected += $4 }
    END {
        print "completed=" completed ", failures=" failures ", rejected=" rejected
        if (completed == 0 || failures != 0 || rejected != 0) exit 1
    }'
echo "Inspect generator and node memory in Grafana to complete the soak assessment."
