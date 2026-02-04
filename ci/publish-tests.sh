#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."

fail() {
  echo "publish-tests: $1" >&2
  exit 1
}

reset_work() {
  rm -rf work/memory work/out work/task.json work/mock work/secrets
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

write_mock_moltbox() {
  mkdir -p work/mock
  cat > work/mock/moltbox <<'EOF'
#!/bin/sh
set -eu

out="/work/out/mock-argv.txt"
mkdir -p /work/out
printf '%s\n' "$0" "$@" > "$out"

jsonl=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jsonl-events)
      shift
      jsonl="$1"
      ;;
  esac
  shift
done

if [ -n "$jsonl" ]; then
  mkdir -p "$(dirname "$jsonl")"
  echo '{"type":"moltbox-mock","ok":true}' >> "$jsonl"
fi
EOF
  chmod +x work/mock/moltbox
}

# 4) post mode success path (mocked moltbox)
reset_work
write_mock_moltbox
mkdir -p work/secrets
printf '%s' "moltbook_test_key" > work/secrets/moltbook_api_key.txt
cat > work/task.json <<'EOF'
{
  "version": 1,
  "steps": [
    {
      "cmd": "date",
      "args": ["-u", "+%Y-%m-%dT%H:%M:%SZ"],
      "stdout_path": "/work/out/test-post/utc.txt"
    }
  ],
  "publish": {
    "provider": "moltbook",
    "enabled": true,
    "mode": "post",
    "submolt": "general",
    "title": "Mock publish test",
    "api_key_path": "/work/secrets/moltbook_api_key.txt",
    "jsonl_events": "/work/memory/molt.events.jsonl"
  }
}
EOF
docker compose run --rm -e MOLTBOX_BIN=/work/mock/moltbox agentbox
test -f work/out/mock-argv.txt
grep -q '^post$' work/out/mock-argv.txt || fail "mock argv missing post"
grep -q '^--submolt$' work/out/mock-argv.txt || fail "mock argv missing --submolt"
grep -q '^general$' work/out/mock-argv.txt || fail "mock argv missing submolt value"
grep -q '^--title$' work/out/mock-argv.txt || fail "mock argv missing --title"
grep -q '^Mock publish test$' work/out/mock-argv.txt || fail "mock argv missing title value"
grep -q '^--content-file$' work/out/mock-argv.txt || fail "mock argv missing --content-file"
grep -q '^/work/memory/MEMORY.md$' work/out/mock-argv.txt || fail "mock argv missing MEMORY.md"
grep -q '^--api-key-file$' work/out/mock-argv.txt || fail "mock argv missing --api-key-file"
grep -q '^/work/secrets/moltbook_api_key.txt$' work/out/mock-argv.txt || fail "mock argv missing api key path"
grep -q '^--jsonl-events$' work/out/mock-argv.txt || fail "mock argv missing --jsonl-events"
grep -q '^/work/memory/molt.events.jsonl$' work/out/mock-argv.txt || fail "mock argv missing jsonl events path"
test -f work/memory/molt.events.jsonl || fail "molt jsonl-events file missing"

docker compose down --remove-orphans
