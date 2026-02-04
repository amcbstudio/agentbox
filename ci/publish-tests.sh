#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

fail() {
  echo "publish-tests: $1" >&2
  exit 1
}

reset_work() {
  rm -rf work/memory work/out work/task.json
  mkdir -p work
}

run_expect_fail() {
  desc="$1"
  shift
  set +e
  "$@"
  ec="$?"
  set -e
  if [ "$ec" -eq 0 ]; then
    fail "$desc: expected non-zero exit"
  fi
}

assert_error_event() {
  [ -f work/memory/events.jsonl ] || fail "events.jsonl missing"
  tail -n 1 work/memory/events.jsonl | grep -q '"type":"error"' || fail "missing error event"
}

docker compose build

# 1) publish enabled but api_key_path missing
reset_work
cat > work/task.json <<'EOF'
{
  "version": 1,
  "steps": [
    {
      "cmd": "date",
      "args": ["-u", "+%Y-%m-%dT%H:%M:%SZ"],
      "stdout_path": "/work/out/test-missing-key/utc.txt"
    }
  ],
  "publish": {
    "provider": "moltbook",
    "enabled": true,
    "mode": "post",
    "submolt": "general",
    "title": "Missing key test",
    "api_key_path": "/work/secrets/moltbook_api_key.txt",
    "jsonl_events": "/work/memory/molt.events.jsonl"
  }
}
EOF
run_expect_fail "missing api_key_path" docker compose run --rm agentbox
assert_error_event

# 2) comment mode missing post_id
reset_work
cat > work/task.json <<'EOF'
{
  "version": 1,
  "steps": [
    {
      "cmd": "date",
      "args": ["-u", "+%Y-%m-%dT%H:%M:%SZ"],
      "stdout_path": "/work/out/test-missing-post-id/utc.txt"
    }
  ],
  "publish": {
    "provider": "moltbook",
    "enabled": true,
    "mode": "comment",
    "submolt": "general",
    "api_key_path": "/work/secrets/moltbook_api_key.txt",
    "jsonl_events": "/work/memory/molt.events.jsonl"
  }
}
EOF
run_expect_fail "comment missing post_id" docker compose run --rm agentbox
assert_error_event

# 3) publish enabled but MEMORY.md missing
reset_work
cat > work/task.json <<'EOF'
{
  "version": 1,
  "steps": [
    {
      "cmd": "date",
      "args": ["-u", "+%Y-%m-%dT%H:%M:%SZ"],
      "stdout_path": "/work/out/test-missing-memory/utc.txt"
    }
  ],
  "publish": {
    "provider": "moltbook",
    "enabled": true,
    "mode": "post",
    "submolt": "general",
    "title": "Missing memory test",
    "api_key_path": "/work/secrets/moltbook_api_key.txt",
    "jsonl_events": "/work/memory/molt.events.jsonl"
  }
}
EOF
run_expect_fail "missing MEMORY.md" docker compose run --rm -e AGENTBOX_TEST_DELETE_MEMORY=1 agentbox
assert_error_event

docker compose down --remove-orphans

