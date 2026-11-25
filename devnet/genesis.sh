#!/bin/sh
# Service genesis (compose.yml): the chain spec of the devnet, which all nodes
# share. Written once, when the volume devnet is empty: the template
# devnet/chainspec.json (a copy of pouw-node/chainspec/devnet.json) with the
# current time as genesis.timestamp and the matching expected_genesis_id.
#
# DEVNET_INITIAL_TARGET (64 hex digits) replaces initial_target and
# genesis.target. pouw-node's 2^230 - 1 is one core of an i7 with SHA extensions
# at 10 s (pouw-node docs/CHAINSPEC.md); on the server (no SHA extensions, the
# miners of staging and dev next to the Jenkins test copies) a new chain made a
# block in about a minute and the load test timed out waiting for a transfer.
# The server sets 2^233 - 1 (the Jenkins agent, the dev network); the target
# rule then tunes the chain to 10 s either way. A fast CPU (GitHub runners)
# keeps the default, an easier target would give it blocks every second.
#
# Why not the spec built into the node: the target schedule of the chain counts
# from genesis.timestamp (pouw-node docs/CHAINSPEC.md), so a chain started
# days after its genesis mines a burst of easy blocks until it catches up. So
# every new devnet (staging, every test copy) gets a genesis of its own. The
# volume keeps it: a node never sees another genesis than the one of its
# database, which it would refuse (exit 1). A new devnet: scripts/devnet-reset.sh
set -eu

spec=/devnet/chainspec.json

if [ -s "$spec" ]; then
    echo "Devnet genesis $(pouw genesis-id "$spec")"
    exit 0
fi

sed "s/\"timestamp\": *[0-9]*/\"timestamp\": $(date +%s)/" /template/chainspec.json >"$spec.part"
if [ -n "${DEVNET_INITIAL_TARGET:-}" ]; then
    if ! echo "$DEVNET_INITIAL_TARGET" | grep -qxE '[0-9a-f]{64}'; then
        echo "DEVNET_INITIAL_TARGET must be 64 hex digits" >&2
        exit 1
    fi
    sed -i -e "s/\"initial_target\": *\"[0-9a-f]*\"/\"initial_target\": \"$DEVNET_INITIAL_TARGET\"/" \
        -e "s/\"target\": *\"[0-9a-f]*\"/\"target\": \"$DEVNET_INITIAL_TARGET\"/" "$spec.part"
fi
id="$(pouw genesis-id "$spec.part")"
sed -i "s/\"expected_genesis_id\": *\"[^\"]*\"/\"expected_genesis_id\": \"$id\"/" "$spec.part"
chmod 644 "$spec.part"
mv "$spec.part" "$spec"
echo "New devnet genesis $id at $(date -u +%FT%TZ)"
