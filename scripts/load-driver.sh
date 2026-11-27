#!/bin/sh
# The default load of a network: service workload-driver (profile load, on the
# server added by the Makefile). Starts the scenario LOAD_SCENARIO of
# pouw-workload and starts it again whenever it ends; LOAD_SCENARIO=off keeps
# the generator stopped.
#
# make load-start SCENARIO=<name> / make load-stop write load.env and recreate
# this container, which first stops whatever the generator runs, so the switch
# takes effect at once. A scenario started by hand (POST /api/v1/start) is left
# alone until it ends, then the default one comes back. make load (a graded
# load test) refuses to run while the default load is on.
set -eu

base=http://workload:8000/api/v1
scenario="${LOAD_SCENARIO:-off}"
# Scenarios that end in an error one after another before the driver waits
max_errors=3

state() {
    curl -fsS --max-time 10 "$base/status" |
        grep -oE '"status"[[:space:]]*:[[:space:]]*"[a-z]+"' | grep -oE '[a-z]+"$' | tr -d '"'
}

curl -fsS --max-time 30 -X POST "$base/stop" >/dev/null 2>&1 || true
echo "Default load: $scenario"
if [ "$scenario" = off ]; then
    while :; do sleep 3600; done
fi

errors=0
started=0
while :; do
    s="$(state || echo unreachable)"
    case "$s" in
        running | stopping | unreachable) ;;
        *)
            # How the scenario this driver started ended
            if [ "$started" = 1 ]; then
                if [ "$s" = error ]; then errors=$((errors + 1)); else errors=0; fi
            fi
            started=0
            if [ "$errors" -ge "$max_errors" ]; then
                echo "$scenario ended in an error $errors times in a row, next try in 5 minutes" >&2
                errors=0
                sleep 300
            fi
            # A start that is refused (e.g. an unknown scenario) counts as an error too
            if curl -fsS --max-time 30 -X POST -H 'Content-Type: application/json' \
                -d "{\"scenario_name\":\"$scenario\"}" "$base/start" >/dev/null; then
                echo "$(date -u +%FT%TZ) started $scenario (previous state: $s)"
                started=1
            else
                errors=$((errors + 1))
            fi
            ;;
    esac
    sleep 10
done
