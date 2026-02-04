#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

mkdir -p work

docker compose up --build --force-recreate --abort-on-container-exit --exit-code-from agentbox

test -f work/memory/events.jsonl
test -f work/memory/schema.fields.jsonl
test -f work/memory/drift.jsonl
test -f work/memory/state.json
test -f work/memory/MEMORY.md

# Confirm compose sets network_mode: none (defense-in-depth check).
cid="$(docker compose ps -aq agentbox | tail -n 1)"
test -n "$cid"
docker inspect "$cid" --format '{{.HostConfig.NetworkMode}}' | grep -qx 'none'

docker compose down --remove-orphans
