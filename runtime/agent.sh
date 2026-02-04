#!/bin/sh
#
# agentbox "dumb agent" runtime
# - Reads a JSON task file (no eval; no sh -c).
# - Executes only an allowlisted set of commands.
# - Appends step events to /work/memory/events.jsonl.
# - Maintains a schema baseline and drift report via `jd`.
# - Produces compacted /work/memory/state.json and /work/memory/MEMORY.md.

set -u
umask 077

PATH="/tools/kv/bin:/tools/jsonl:/tools/jd/bin:/tools/moltbox/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

LC_ALL=C
LANG=C
TZ=UTC
export LC_ALL LANG TZ

WORK_DIR="/work"
MEMORY_DIR="${WORK_DIR}/memory"
TMP_DIR="${MEMORY_DIR}/tmp"

TASK_DEFAULT="/tasks/demo/task.json"
TASK_PATH="${WORK_DIR}/task.json"

EVENTS_PATH="${MEMORY_DIR}/events.jsonl"
SCHEMA_BASELINE_PATH="${MEMORY_DIR}/schema.fields.jsonl"
DRIFT_PATH="${MEMORY_DIR}/drift.jsonl"
STATE_PATH="${MEMORY_DIR}/state.json"
MEMORY_MD_PATH="${MEMORY_DIR}/MEMORY.md"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

emit_error() {
  message="$1"
  stage="$2"
  ts="$3"
  task_path="$4"

  if command -v jq >/dev/null 2>&1; then
    jq -nc \
      --arg ts "$ts" \
      --arg stage "$stage" \
      --arg message "$message" \
      --arg task_path "$task_path" \
      '{type:"error",ts:$ts,stage:$stage,message:$message,task_path:$task_path}'
  else
    msg_esc="$(json_escape "$message")"
    stage_esc="$(json_escape "$stage")"
    task_esc="$(json_escape "$task_path")"
    printf '{"type":"error","ts":"%s","stage":"%s","message":"%s","task_path":"%s"}' "$ts" "$stage_esc" "$msg_esc" "$task_esc"
  fi
}

emit_error_line() {
  message="$1"
  stage="$2"
  ts="${3:-${now:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}}"
  task_path="${4:-${task_path_used:-}}"

  if [ -n "${EVENTS_PATH:-}" ] && [ -w "$EVENTS_PATH" ]; then
    if emit_error "$message" "$stage" "$ts" "$task_path" >>"$EVENTS_PATH"; then
      return 0
    fi
  fi
  emit_error "$message" "$stage" "$ts" "$task_path" >&2
}

cleanup_tmp() {
  [ -n "${TMP_DIR:-}" ] || return 0
  [ -d "$TMP_DIR" ] || return 0
  rm -f "$TMP_DIR"/* 2>/dev/null || :
}

error_exit() {
  message="$1"
  stage="${2:-runtime}"
  emit_error_line "$message" "$stage"
  cleanup_tmp
  exit 2
}

require_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi

  case "$1" in
    kv|jsonl|jd)
      error_exit "missing required command: $1 (check submodules under ./tools and rebuild image)" "runtime"
      ;;
    *)
      error_exit "missing required command: $1" "runtime"
      ;;
  esac
}

is_allowed_cmd() {
  case "$1" in
    kv|jsonl|jd|molt|cat|wc|head|tail|sed|awk|diff|sha256sum|date|mkdir|ls) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_work_path() {
  p="$1"
  [ -n "$p" ] || error_exit "path must be non-empty" "validate"
  case "$p" in
    /work/*) ;;
    *) error_exit "path must be under /work: $p" "validate" ;;
  esac
  case "$p" in
    *"/../"*|*"/.."|"/.."|*"/./"*|*"/."|"/.") error_exit "path contains dot-segments: $p" "validate" ;;
  esac
  case "$p" in
    */) error_exit "path must be a file, not a directory: $p" "validate" ;;
  esac
}

ensure_work_output_path() {
  p="$1"
  ensure_work_path "$p"
  case "$p" in
    /work/memory/*) error_exit "task output paths may not target /work/memory: $p" "validate" ;;
  esac
}

ensure_arg_allowed() {
  arg="$1"
  case "$arg" in
    /*)
      case "$arg" in
        /work|/work/*) ;;
        *) error_exit "arg path outside /work: $arg" "validate" ;;
      esac
      ;;
  esac
}

sha256_file() {
  # Prints hex sha256 for a file path.
  sha256sum "$1" | awk '{print $1}'
}

bytes_file() {
  wc -c <"$1" | awk '{print $1}'
}

append_event() {
  ts="$1"
  seq="$2"
  task_path="$3"
  task_sha="$4"
  step_index="$5"
  cmd="$6"
  args_json="$7"
  stdin_path="$8"
  stdout_path="$9"
  stderr_path="${10}"
  exit_code="${11}"
  stdout_bytes="${12}"
  stdout_sha="${13}"
  stderr_bytes="${14}"
  stderr_sha="${15}"
  note="${16}"

  jq -nc \
    --arg ts "$ts" \
    --arg task_path "$task_path" \
    --arg task_sha "$task_sha" \
    --arg cmd "$cmd" \
    --arg stdin_path "$stdin_path" \
    --arg stdout_path "$stdout_path" \
    --arg stderr_path "$stderr_path" \
    --arg note "$note" \
    --argjson seq "$seq" \
    --argjson step_index "$step_index" \
    --argjson args "$args_json" \
    --argjson exit_code "$exit_code" \
    --argjson stdout_bytes "$stdout_bytes" \
    --argjson stderr_bytes "$stderr_bytes" \
    --arg stdout_sha "$stdout_sha" \
    --arg stderr_sha "$stderr_sha" \
    '{
      ts: $ts,
      type: "step",
      seq: $seq,
      task_path: $task_path,
      task_sha256: $task_sha,
      step_index: $step_index,
      cmd: $cmd,
      args: $args,
      stdin_path: $stdin_path,
      stdout_path: $stdout_path,
      stderr_path: $stderr_path,
      exit_code: $exit_code,
      stdout_bytes: $stdout_bytes,
      stdout_sha256: $stdout_sha,
      stderr_bytes: $stderr_bytes,
      stderr_sha256: $stderr_sha
    } | (if $note != "" then . + {note: $note} else . end)' >>"$EVENTS_PATH" \
    || error_exit "failed to write event log" "runtime"
}

validate_task() {
  task_path="$1"
  jq -e '
    .version == 1
    and (.accept_baseline? | if . == null then true else type == "boolean" end)
    and (.steps | type == "array" and length > 0)
    and (all(.steps[]; type == "object"
      and (.cmd | type == "string" and length > 0)
      and (.args? | if . == null then true else (type == "array" and all(.[]; type == "string")) end)
      and (.stdin_path? | if . == null then true else type == "string" end)
      and (.stdout_path? | if . == null then true else type == "string" end)
      and (.stderr_path? | if . == null then true else type == "string" end)
      and (.note? | if . == null then true else type == "string" end)
    ))
    and (
      .publish? as $p
      | if $p == null then true
        else ($p | type == "object")
          and (($p.enabled? // false) | type == "boolean")
          and (
            if ($p.enabled? // false) then
              ($p.provider == "moltbook")
              and ($p.mode | type == "string" and ($p.mode == "post" or $p.mode == "comment"))
              and ($p.submolt | type == "string" and length > 0)
              and ($p.api_key_path | type == "string" and length > 0)
              and ($p.jsonl_events | type == "string" and length > 0)
              and (if $p.mode == "comment" then ($p.post_id | type == "string" and length > 0) else true end)
              and (if $p.mode == "post" then ($p.title? | if . == null then true else type == "string" end) else true end)
            else true end
          )
      end
    )
  ' "$task_path" >/dev/null 2>"$TMP_DIR/jq.validate.err"
}

build_steps_jsonl() {
  task_path="$1"
  jq -c '
    .steps
    | to_entries[]
    | {
        index: .key,
        cmd: .value.cmd,
        args: (.value.args // []),
        stdin_path: (.value.stdin_path // ""),
        stdout_path: (.value.stdout_path // ""),
        stderr_path: (.value.stderr_path // ""),
        note: (.value.note // "")
      }
  ' "$task_path"
}

validate_awk_argv() {
  # Prevent `awk` from spawning arbitrary commands via system()/pipes.
  # Allow only:
  # - optional `-F <sep>`
  # - one program argument
  # - optional input files under /work
  program=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -F)
        shift
        [ "$#" -gt 0 ] || error_exit "awk: -F requires an argument" "validate"
        shift
        ;;
      -*)
        error_exit "awk: only -F is allowed" "validate"
        ;;
      *)
        if [ -z "$program" ]; then
          program="$1"
        else
          # Input file args are allowed only under /work.
          ensure_work_path "$1"
        fi
        shift
        ;;
    esac
  done

  [ -n "$program" ] || error_exit "awk: missing program" "validate"
  case "$program" in
    *system*|*getline*|*'|'*|*'>'*|*'<'*|*'&'*|*'`'*) error_exit "awk: forbidden constructs in program" "validate" ;;
  esac
}

validate_sed_argv() {
  # Disallow in-place edits and obvious exec hooks.
  # This is intentionally conservative.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -i*) error_exit "sed: -i is not allowed" "validate" ;;
      -n) shift ;;
      -*)
        # Keep flags surface small.
        error_exit "sed: only -n is allowed" "validate"
        ;;
      *)
        # First non-flag arg is script; remaining are input files (allowed under /work).
        script="$1"
        case "$script" in
          e\ *|*";e "*|*";e") error_exit "sed: forbidden exec-like script" "validate" ;;
        esac
        shift
        while [ "$#" -gt 0 ]; do
          ensure_work_path "$1"
          shift
        done
        return 0
        ;;
    esac
  done
}

run_step() {
  step_index="$1"
  cmd="$2"
  args_json="$3"
  args_file="$4"
  stdin_path="$5"
  stdout_path="$6"
  stderr_path="$7"
  note="$8"
  ts="$9"
  seq="${10}"
  task_path="${11}"
  task_sha="${12}"

  case "$cmd" in
    */*) error_exit "cmd must be a bare name (no slashes): $cmd" "validate" ;;
  esac
  is_allowed_cmd "$cmd" || error_exit "disallowed cmd: $cmd" "validate"
  require_cmd "$cmd"

  set --
  if [ -f "$args_file" ]; then
    while IFS= read -r arg; do
      ensure_arg_allowed "$arg"
      set -- "$@" "$arg"
    done <"$args_file"
  fi

  # stdin: only allow reading from /work (or unset => /dev/null).
  stdin_file="/dev/null"
  if [ -n "$stdin_path" ]; then
    ensure_work_path "$stdin_path"
    [ -f "$stdin_path" ] || error_exit "stdin_path does not exist: $stdin_path" "runtime"
    stdin_file="$stdin_path"
  fi

  # stdout/stderr: only allow writing under /work. If not set, capture into $TMP_DIR (under /work).
  out_file=""
  err_file=""
  out_path_for_event="$stdout_path"
  err_path_for_event="$stderr_path"

  if [ -n "$stdout_path" ]; then
    ensure_work_output_path "$stdout_path"
    out_dir="${stdout_path%/*}"
    mkdir -p "$out_dir" || error_exit "failed to create dir: $out_dir" "runtime"
    out_file="$stdout_path"
  else
    out_file="${TMP_DIR}/agentbox.step.${seq}.stdout"
    out_path_for_event=""
  fi

  if [ -n "$stderr_path" ]; then
    ensure_work_output_path "$stderr_path"
    err_dir="${stderr_path%/*}"
    mkdir -p "$err_dir" || error_exit "failed to create dir: $err_dir" "runtime"
    err_file="$stderr_path"
  else
    err_file="${TMP_DIR}/agentbox.step.${seq}.stderr"
    err_path_for_event=""
  fi

  # Ensure files exist (and truncate).
  : >"$out_file" || error_exit "failed to open stdout file: $out_file" "runtime"
  : >"$err_file" || error_exit "failed to open stderr file: $err_file" "runtime"

  case "$cmd" in
    awk) validate_awk_argv "$@" ;;
    sed) validate_sed_argv "$@" ;;
  esac

  "$cmd" "$@" <"$stdin_file" >"$out_file" 2>"$err_file"
  exit_code="$?"

  out_bytes="$(bytes_file "$out_file")"
  out_sha="$(sha256_file "$out_file")"
  err_bytes="$(bytes_file "$err_file")"
  err_sha="$(sha256_file "$err_file")"

  [ -n "$args_json" ] || args_json="[]"

  append_event \
    "$ts" \
    "$seq" \
    "$task_path" \
    "$task_sha" \
    "$step_index" \
    "$cmd" \
    "$args_json" \
    "$stdin_path" \
    "$out_path_for_event" \
    "$err_path_for_event" \
    "$exit_code" \
    "$out_bytes" \
    "$out_sha" \
    "$err_bytes" \
    "$err_sha" \
    "$note"

  return "$exit_code"
}

run_jd_fields() {
  # Writes schema fields JSONL to $1.
  # Compatibility: prefer stdin, fall back to file-arg mode if needed.
  out_path="$1"
  events_path="$2"
  : >"$out_path" || error_exit "failed to open schema output: $out_path" "runtime"

  jd fields <"$events_path" >"$out_path"
  ec="$?"
  if [ "$ec" -ne 0 ]; then
    jd fields "$events_path" >"$out_path"
    return "$?"
  fi
  return 0
}

run_jd_drift() {
  # Writes drift JSONL to $2.
  # Compatibility: prefer stdin, fall back to file-arg mode if needed.
  baseline="$1"
  out_path="$2"
  events_path="$3"
  : >"$out_path" || error_exit "failed to open drift output: $out_path" "runtime"

  jd drift --baseline "$baseline" <"$events_path" >"$out_path"
  ec="$?"
  if [ "$ec" -gt 1 ]; then
    jd drift --baseline "$baseline" "$events_path" >"$out_path"
    return "$?"
  fi
  return "$ec"
}

write_state() {
  generated_at="$1"
  task_path="$2"
  task_sha="$3"
  accept_baseline="$4"
  step_failures="$5"
  drift_detected="$6"
  drift_events="$7"

  events_lines="$(wc -l <"$EVENTS_PATH" | awk '{print $1}')"
  schema_lines="$(wc -l <"$SCHEMA_BASELINE_PATH" | awk '{print $1}')"
  drift_lines="$(wc -l <"$DRIFT_PATH" | awk '{print $1}')"

  events_sha="$(sha256_file "$EVENTS_PATH")"
  schema_sha="$(sha256_file "$SCHEMA_BASELINE_PATH")"
  drift_sha="$(sha256_file "$DRIFT_PATH")"

  cat >"$STATE_PATH" <<EOF
{
  "version": 1,
  "generated_at": "${generated_at}",
  "task_path": "${task_path}",
  "task_sha256": "${task_sha}",
  "accept_baseline": ${accept_baseline},
  "step_failures": ${step_failures},
  "events": {
    "path": "memory/events.jsonl",
    "lines": ${events_lines},
    "sha256": "${events_sha}"
  },
  "schema_fields": {
    "path": "memory/schema.fields.jsonl",
    "lines": ${schema_lines},
    "sha256": "${schema_sha}"
  },
  "drift": {
    "path": "memory/drift.jsonl",
    "lines": ${drift_lines},
    "sha256": "${drift_sha}",
    "detected": ${drift_detected},
    "events": ${drift_events}
  }
}
EOF
}

write_memory_md() {
  generated_at="$1"
  task_path="$2"
  task_sha="$3"
  accept_baseline="$4"
  step_failures="$5"
  drift_detected="$6"
  drift_events="$7"

  events_lines="$(wc -l <"$EVENTS_PATH" | awk '{print $1}')"
  drift_lines="$(wc -l <"$DRIFT_PATH" | awk '{print $1}')"

  cat >"$MEMORY_MD_PATH" <<EOF
# Agentbox Memory

- Updated (UTC): ${generated_at}
- Task: \`${task_path}\`
- Task sha256: \`${task_sha}\`
- accept_baseline: \`${accept_baseline}\`
- step_failures: \`${step_failures}\`
- Events: \`${events_lines}\` lines
- Drift: \`${drift_lines}\` lines (non-fatal)
- Drift detected: \`${drift_detected}\`
- Drift events: \`${drift_events}\`

## Recent events (last 25)

\`\`\`jsonl
EOF
  tail -n 25 "$EVENTS_PATH" >>"$MEMORY_MD_PATH" 2>/dev/null || :
  cat >>"$MEMORY_MD_PATH" <<'EOF'
\`\`\`
EOF
}

publish_phase() {
  publish_enabled="$(jq -r '.publish.enabled // false' "$task_path_used")"
  if [ "$publish_enabled" != "true" ]; then
    return 0
  fi

  provider="$(jq -r '.publish.provider // ""' "$task_path_used")"
  mode="$(jq -r '.publish.mode // ""' "$task_path_used")"
  submolt="$(jq -r '.publish.submolt // ""' "$task_path_used")"
  title="$(jq -r '.publish.title // ""' "$task_path_used")"
  post_id="$(jq -r '.publish.post_id // ""' "$task_path_used")"
  api_key_path="$(jq -r '.publish.api_key_path // ""' "$task_path_used")"
  jsonl_events="$(jq -r '.publish.jsonl_events // ""' "$task_path_used")"

  [ "$provider" = "moltbook" ] || error_exit "publish.provider must be \"moltbook\"" "publish"
  case "$mode" in
    post|comment) ;;
    *) error_exit "publish.mode must be \"post\" or \"comment\"" "publish" ;;
  esac
  [ -n "$submolt" ] || error_exit "publish.submolt is required" "publish"
  [ -n "$api_key_path" ] || error_exit "publish.api_key_path is required" "publish"
  [ -n "$jsonl_events" ] || error_exit "publish.jsonl_events is required" "publish"

  ensure_work_path "$api_key_path"
  ensure_work_path "$jsonl_events"

  [ -f "$api_key_path" ] || error_exit "publish.api_key_path missing: $api_key_path" "publish"

  if [ "${AGENTBOX_TEST_DELETE_MEMORY:-}" = "1" ]; then
    rm -f "$MEMORY_MD_PATH" 2>/dev/null || :
  fi

  [ -f "$MEMORY_MD_PATH" ] || error_exit "MEMORY.md missing: $MEMORY_MD_PATH" "publish"

  if [ "$mode" = "comment" ] && [ -z "$post_id" ]; then
    error_exit "publish.post_id is required for comment mode" "publish"
  fi

  jsonl_dir="${jsonl_events%/*}"
  mkdir -p "$jsonl_dir" || error_exit "failed to create dir: $jsonl_dir" "publish"
  if [ "$jsonl_events" != "$EVENTS_PATH" ]; then
    cat "$EVENTS_PATH" >"$jsonl_events" || error_exit "failed to write jsonl_events: $jsonl_events" "publish"
  fi

  require_cmd molt

  publish_args_json="$(
    jq -nc \
      --arg api_key_path "$api_key_path" \
      --arg jsonl_events "$jsonl_events" \
      --arg submolt "$submolt" \
      --arg mode "$mode" \
      --arg title "$title" \
      --arg post_id "$post_id" \
      '[
        "--api-key-file", $api_key_path,
        "--jsonl-events", $jsonl_events,
        "publish", "agentbox",
        "--memory-dir", "/work/memory",
        "--submolt", $submolt,
        "--mode", $mode
      ]
      + (if $title != "" then ["--title", $title] else [] end)
      + (if $post_id != "" then ["--post-id", $post_id] else [] end)'
  )"

  publish_args_path="${TMP_DIR}/agentbox.args.${$}.publish"
  if ! printf '%s' "$publish_args_json" | jq -r '.[]' >"$publish_args_path"; then
    error_exit "failed to build publish args" "publish"
  fi

  publish_out_dir="/work/out/publish"
  mkdir -p "$publish_out_dir" || error_exit "failed to create dir: $publish_out_dir" "publish"
  publish_stdout="${publish_out_dir}/molt.stdout"
  publish_stderr="${publish_out_dir}/molt.stderr"

  seq="$((seq + 1))"
  if run_step \
    "-1" \
    "molt" \
    "$publish_args_json" \
    "$publish_args_path" \
    "" \
    "$publish_stdout" \
    "$publish_stderr" \
    "" \
    "$now" \
    "$seq" \
    "$task_path_used" \
    "$task_sha"; then
    :
  else
    step_failures="$((step_failures + 1))"
  fi
}

main() {
  require_cmd awk
  require_cmd wc
  require_cmd sha256sum
  require_cmd date
  require_cmd mkdir
  require_cmd jq
  require_cmd jd

  mkdir -p "$MEMORY_DIR" || error_exit "failed to create memory dir: $MEMORY_DIR" "runtime"
  mkdir -p "$TMP_DIR" || error_exit "failed to create tmp dir: $TMP_DIR" "runtime"

  # Pick task path.
  if [ -f "$TASK_PATH" ]; then
    task_path_used="$TASK_PATH"
  else
    task_path_used="$TASK_DEFAULT"
  fi
  [ -f "$task_path_used" ] || error_exit "task file not found: $task_path_used" "runtime"

  # Cap task size to keep parsing predictable.
  task_bytes="$(wc -c <"$task_path_used" | awk '{print $1}')"
  if [ "$task_bytes" -gt 262144 ]; then
    error_exit "task too large (>256KiB): $task_bytes bytes" "parse"
  fi

  task_sha="$(sha256_file "$task_path_used")"
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Ensure events file exists.
  : >>"$EVENTS_PATH" || error_exit "failed to open events log: $EVENTS_PATH" "runtime"

  # Current event sequence starts after the existing number of lines.
  base_seq="$(wc -l <"$EVENTS_PATH" | awk '{print $1}')"
  seq="$base_seq"

  if ! validate_task "$task_path_used"; then
    error_exit "task.json: invalid JSON or schema" "parse"
  fi

  accept_baseline="$(jq -r '.accept_baseline // false' "$task_path_used")"
  step_failures=0

  steps_path="${TMP_DIR}/agentbox.steps.$$"
  if ! build_steps_jsonl "$task_path_used" >"$steps_path"; then
    error_exit "task.json: failed to parse steps" "parse"
  fi

  while IFS= read -r step_json; do
    step_idx="$(printf '%s' "$step_json" | jq -r '.index')"
    cmd="$(printf '%s' "$step_json" | jq -r '.cmd')"
    args_json="$(printf '%s' "$step_json" | jq -c '.args')"
    stdin_path="$(printf '%s' "$step_json" | jq -r '.stdin_path')"
    stdout_path="$(printf '%s' "$step_json" | jq -r '.stdout_path')"
    stderr_path="$(printf '%s' "$step_json" | jq -r '.stderr_path')"
    note="$(printf '%s' "$step_json" | jq -r '.note')"

    args_path="${TMP_DIR}/agentbox.args.${$}.${step_idx}"
    if ! printf '%s' "$step_json" | jq -r '.args[]' >"$args_path"; then
      error_exit "task.json: failed to read args for step ${step_idx}" "parse"
    fi

    seq="$((seq + 1))"
    if run_step \
      "$step_idx" \
      "$cmd" \
      "$args_json" \
      "$args_path" \
      "$stdin_path" \
      "$stdout_path" \
      "$stderr_path" \
      "$note" \
      "$now" \
      "$seq" \
      "$task_path_used" \
      "$task_sha"; then
      :
    else
      step_failures="$((step_failures + 1))"
    fi
  done <"$steps_path"

  # Initialize baseline if missing.
  if [ ! -f "$SCHEMA_BASELINE_PATH" ]; then
    run_jd_fields "$SCHEMA_BASELINE_PATH" "$EVENTS_PATH" || error_exit "jd fields failed" "runtime"
  fi

  # Drift is non-fatal: treat exit 0/1 as OK (drift/no drift), >1 as operational error.
  run_jd_drift "$SCHEMA_BASELINE_PATH" "$DRIFT_PATH" "$EVENTS_PATH"
  drift_ec="$?"
  if [ "$drift_ec" -gt 1 ]; then
    error_exit "jd drift failed (exit=$drift_ec)" "runtime"
  fi

  if [ "$accept_baseline" = "true" ]; then
    run_jd_fields "$SCHEMA_BASELINE_PATH" "$EVENTS_PATH" || error_exit "jd fields failed (accept_baseline)" "runtime"
    run_jd_drift "$SCHEMA_BASELINE_PATH" "$DRIFT_PATH" "$EVENTS_PATH"
    drift_ec="$?"
    if [ "$drift_ec" -gt 1 ]; then
      error_exit "jd drift failed after accept_baseline (exit=$drift_ec)" "runtime"
    fi
  fi

  drift_events="$(jq -s '[.[] | select(.type != "summary")] | length' "$DRIFT_PATH" 2>/dev/null || echo 0)"
  case "$drift_events" in
    ''|*[!0-9]*) drift_events=0 ;;
  esac
  if [ "$drift_events" -gt 0 ]; then
    drift_detected="true"
  else
    drift_detected="false"
  fi

  write_state "$now" "$task_path_used" "$task_sha" "$accept_baseline" "$step_failures" "$drift_detected" "$drift_events" \
    || error_exit "failed to write state.json" "runtime"
  write_memory_md "$now" "$task_path_used" "$task_sha" "$accept_baseline" "$step_failures" "$drift_detected" "$drift_events" \
    || error_exit "failed to write MEMORY.md" "runtime"

  publish_phase

  cleanup_tmp
  if [ "$step_failures" -gt 0 ]; then
    exit 2
  fi
  exit 0
}

main "$@"
