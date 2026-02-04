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

PATH="/tools/kv/bin:/tools/jsonl/bin:/tools/jd/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

LC_ALL=C
LANG=C
TZ=UTC
export LC_ALL LANG TZ

TAB='	'

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

die() {
  echo "agentbox: $*" >&2
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

is_allowed_cmd() {
  case "$1" in
    kv|jsonl|jd|cat|wc|head|tail|sed|awk|diff|sha256sum|date|mkdir|ls) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_safe_scalar() {
  # Ensure strings are JSON-safe with our minimal encoder.
  # We intentionally reject backslashes and quotes (no escape handling).
  val="$1"
  [ -n "$val" ] || return 0
  case "$val" in
    *\\*|*\"*) die "task contains unsupported escape/quote character: $val" ;;
  esac
  case "$val" in
    *"$TAB"*) die "task contains unsupported control character" ;;
  esac
}

ensure_work_path() {
  p="$1"
  ensure_safe_scalar "$p"
  case "$p" in
    /work/*) ;;
    *) die "path must be under /work: $p" ;;
  esac
  case "$p" in
    *"/../"*|*"/.."|"/.."|*"/./"*|*"/."|"/.") die "path contains dot-segments: $p" ;;
  esac
  case "$p" in
    */) die "path must be a file, not a directory: $p" ;;
  esac
}

ensure_work_output_path() {
  p="$1"
  ensure_work_path "$p"
  case "$p" in
    /work/memory/*) die "task output paths may not target /work/memory: $p" ;;
  esac
}

sha256_file() {
  # Prints hex sha256 for a file path.
  sha256sum "$1" | awk '{print $1}'
}

bytes_file() {
  wc -c <"$1" | awk '{print $1}'
}

json_array_from_lines() {
  # Reads lines from stdin; prints a JSON array of strings.
  # NOTE: strings must already be validated by ensure_safe_scalar.
  first=1
  printf '['
  while IFS= read -r line; do
    ensure_safe_scalar "$line"
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ','
    fi
    printf '"%s"' "$line"
  done
  printf ']'
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

  ensure_safe_scalar "$task_path"
  ensure_safe_scalar "$task_sha"
  ensure_safe_scalar "$cmd"
  ensure_safe_scalar "$stdin_path"
  ensure_safe_scalar "$stdout_path"
  ensure_safe_scalar "$stderr_path"
  ensure_safe_scalar "$note"

  if [ -n "$note" ]; then
    note_kv=",\"note\":\"${note}\""
  else
    note_kv=""
  fi

  # Fixed key order for deterministic logs.
  printf '{' >>"$EVENTS_PATH"
  printf '"ts":"%s",' "$ts" >>"$EVENTS_PATH"
  printf '"type":"step",' >>"$EVENTS_PATH"
  printf '"seq":%s,' "$seq" >>"$EVENTS_PATH"
  printf '"task_path":"%s",' "$task_path" >>"$EVENTS_PATH"
  printf '"task_sha256":"%s",' "$task_sha" >>"$EVENTS_PATH"
  printf '"step_index":%s,' "$step_index" >>"$EVENTS_PATH"
  printf '"cmd":"%s",' "$cmd" >>"$EVENTS_PATH"
  printf '"args":%s,' "$args_json" >>"$EVENTS_PATH"
  printf '"stdin_path":"%s",' "$stdin_path" >>"$EVENTS_PATH"
  printf '"stdout_path":"%s",' "$stdout_path" >>"$EVENTS_PATH"
  printf '"stderr_path":"%s",' "$stderr_path" >>"$EVENTS_PATH"
  printf '"exit_code":%s,' "$exit_code" >>"$EVENTS_PATH"
  printf '"stdout_bytes":%s,' "$stdout_bytes" >>"$EVENTS_PATH"
  printf '"stdout_sha256":"%s",' "$stdout_sha" >>"$EVENTS_PATH"
  printf '"stderr_bytes":%s,' "$stderr_bytes" >>"$EVENTS_PATH"
  printf '"stderr_sha256":"%s"%s' "$stderr_sha" "$note_kv" >>"$EVENTS_PATH"
  printf '}\n' >>"$EVENTS_PATH"
}

parse_task_to_spec() {
  # Outputs a line-oriented spec:
  # META_ACCEPT_BASELINE<TAB>true|false
  # STEP_BEGIN<TAB>0
  # CMD<TAB>date
  # ARG<TAB>-u
  # ...
  # STEP_END<TAB>0
  task_path="$1"

  awk -f - "$task_path" <<'AWK'
function err(msg) {
  print "task.json: " msg > "/dev/stderr"
  exit 2
}
function emit_kv(k, v) {
  # We reject tabs in values to keep the protocol unambiguous.
  if (index(v, "\t") != 0) err("value contains tab for key " k)
  print k "\t" v
}
function emit_step(idx, obj, m, rest, x) {
  # Disallow JSON escapes to keep parsing and execution safe/simple.
  if (index(obj, "\\") != 0) err("step " idx ": backslashes/escapes are not supported")

  emit_kv("STEP_BEGIN", idx)

  if (match(obj, /"cmd"[[:space:]]*:[[:space:]]*"([^"]*)"/, m) == 0) err("step " idx ": missing cmd")
  emit_kv("CMD", m[1])

  if (match(obj, /"args"[[:space:]]*:[[:space:]]*\[([^]]*)\]/, m)) {
    rest = m[1]
    while (match(rest, /"([^"]*)"/, x)) {
      emit_kv("ARG", x[1])
      rest = substr(rest, RSTART + RLENGTH)
    }
  }

  if (match(obj, /"stdin_path"[[:space:]]*:[[:space:]]*"([^"]*)"/, m)) emit_kv("STDIN_PATH", m[1])
  if (match(obj, /"stdout_path"[[:space:]]*:[[:space:]]*"([^"]*)"/, m)) emit_kv("STDOUT_PATH", m[1])
  if (match(obj, /"stderr_path"[[:space:]]*:[[:space:]]*"([^"]*)"/, m)) emit_kv("STDERR_PATH", m[1])
  if (match(obj, /"note"[[:space:]]*:[[:space:]]*"([^"]*)"/, m)) emit_kv("NOTE", m[1])

  emit_kv("STEP_END", idx)
}
BEGIN {
  s = ""
  arr_end = 0
}
{
  s = s $0 "\n"
}
END {
  gsub(/\r/, "", s)
  if (s == "") err("empty task file")

  if (match(s, /"version"[[:space:]]*:[[:space:]]*([0-9]+)/, m) == 0) err("missing version")
  if (m[1] != 1) err("unsupported version: " m[1])

  accept = "false"
  if (match(s, /"accept_baseline"[[:space:]]*:[[:space:]]*(true|false)/, m2)) accept = m2[1]
  emit_kv("META_ACCEPT_BASELINE", accept)

  steps_pos = index(s, "\"steps\"")
  if (steps_pos == 0) err("missing steps")

  # Find the '[' that starts the steps array.
  i = steps_pos
  while (i <= length(s) && substr(s, i, 1) != "[") i++
  if (i > length(s)) err("steps array not found")
  arr_start = i

  # Find the matching ']'.
  depth = 0
  in_str = 0
  esc = 0
  for (i = arr_start; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (in_str) {
      if (esc) esc = 0
      else if (c == "\\") esc = 1
      else if (c == "\"") in_str = 0
    } else {
      if (c == "\"") in_str = 1
      else if (c == "[") depth++
      else if (c == "]") {
        depth--
        if (depth == 0) { arr_end = i; break }
      }
    }
  }
  if (arr_end == 0) err("unterminated steps array")

  steps = substr(s, arr_start + 1, arr_end - arr_start - 1)

  # Walk the steps array, extracting top-level JSON objects.
  idx = -1
  depth = 0
  in_str = 0
  esc = 0
  obj_start = 0
  for (i = 1; i <= length(steps); i++) {
    c = substr(steps, i, 1)
    if (in_str) {
      if (esc) esc = 0
      else if (c == "\\") esc = 1
      else if (c == "\"") in_str = 0
    } else {
      if (c == "\"") in_str = 1
      else if (c == "{") {
        if (depth == 0) obj_start = i
        depth++
      } else if (c == "}") {
        depth--
        if (depth == 0) {
          idx++
          obj = substr(steps, obj_start, i - obj_start + 1)
          emit_step(idx, obj)
          obj_start = 0
        }
      }
    }
  }
  if (depth != 0) err("unterminated step object")
  if (idx < 0) err("no steps")
}
AWK
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
        [ "$#" -gt 0 ] || die "awk: -F requires an argument"
        ensure_safe_scalar "$1"
        shift
        ;;
      -*)
        die "awk: only -F is allowed"
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

  [ -n "$program" ] || die "awk: missing program"
  ensure_safe_scalar "$program"
  case "$program" in
    *system*|*getline*|*'|'*|*'>'*|*'<'*|*'&'*|*'`'*) die "awk: forbidden constructs in program" ;;
  esac
}

validate_sed_argv() {
  # Disallow in-place edits and obvious exec hooks.
  # This is intentionally conservative.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -i*) die "sed: -i is not allowed" ;;
      -n) shift ;;
      -*)
        # Keep flags surface small.
        die "sed: only -n is allowed"
        ;;
      *)
        # First non-flag arg is script; remaining are input files (allowed under /work).
        script="$1"
        ensure_safe_scalar "$script"
        case "$script" in
          e\ *|*";e "*|*";e") die "sed: forbidden exec-like script" ;;
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
  args_file="$3"
  stdin_path="$4"
  stdout_path="$5"
  stderr_path="$6"
  note="$7"
  ts="$8"
  seq="$9"
  task_path="${10}"
  task_sha="${11}"

  ensure_safe_scalar "$cmd"
  ensure_safe_scalar "$note"

  case "$cmd" in
    */*) die "cmd must be a bare name (no slashes): $cmd" ;;
  esac
  is_allowed_cmd "$cmd" || die "disallowed cmd: $cmd"
  require_cmd "$cmd"

  set --
  if [ -f "$args_file" ]; then
    while IFS= read -r arg; do
      ensure_safe_scalar "$arg"
      set -- "$@" "$arg"
    done <"$args_file"
  fi

  # stdin: only allow reading from /work (or unset => /dev/null).
  stdin_file="/dev/null"
  if [ -n "$stdin_path" ]; then
    ensure_work_path "$stdin_path"
    [ -f "$stdin_path" ] || die "stdin_path does not exist: $stdin_path"
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
    mkdir -p "$out_dir" || die "failed to create dir: $out_dir"
    out_file="$stdout_path"
  else
    out_file="${TMP_DIR}/agentbox.step.${seq}.stdout"
    out_path_for_event=""
  fi

  if [ -n "$stderr_path" ]; then
    ensure_work_output_path "$stderr_path"
    err_dir="${stderr_path%/*}"
    mkdir -p "$err_dir" || die "failed to create dir: $err_dir"
    err_file="$stderr_path"
  else
    err_file="${TMP_DIR}/agentbox.step.${seq}.stderr"
    err_path_for_event=""
  fi

  # Ensure files exist (and truncate).
  : >"$out_file" || die "failed to open stdout file: $out_file"
  : >"$err_file" || die "failed to open stderr file: $err_file"

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

  if [ -f "$args_file" ] && [ -s "$args_file" ]; then
    args_json="$(json_array_from_lines <"$args_file")"
  else
    args_json="[]"
  fi

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
  : >"$out_path" || die "failed to open schema output: $out_path"

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
  : >"$out_path" || die "failed to open drift output: $out_path"

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
    "sha256": "${drift_sha}"
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

## Recent events (last 25)

\`\`\`jsonl
EOF
  tail -n 25 "$EVENTS_PATH" >>"$MEMORY_MD_PATH" 2>/dev/null || :
  cat >>"$MEMORY_MD_PATH" <<'EOF'
\`\`\`
EOF
}

main() {
  require_cmd awk
  require_cmd wc
  require_cmd sha256sum
  require_cmd date
  require_cmd mkdir
  require_cmd jd

  mkdir -p "$MEMORY_DIR" || die "failed to create memory dir: $MEMORY_DIR"
  mkdir -p "$TMP_DIR" || die "failed to create tmp dir: $TMP_DIR"

  # Pick task path.
  if [ -f "$TASK_PATH" ]; then
    task_path_used="$TASK_PATH"
  else
    task_path_used="$TASK_DEFAULT"
  fi
  [ -f "$task_path_used" ] || die "task file not found: $task_path_used"

  # Cap task size to keep parsing predictable.
  task_bytes="$(wc -c <"$task_path_used" | awk '{print $1}')"
  if [ "$task_bytes" -gt 262144 ]; then
    die "task too large (>256KiB): $task_bytes bytes"
  fi

  task_sha="$(sha256_file "$task_path_used")"
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Ensure events file exists.
  : >>"$EVENTS_PATH" || die "failed to open events log: $EVENTS_PATH"

  # Current event sequence starts after the existing number of lines.
  base_seq="$(wc -l <"$EVENTS_PATH" | awk '{print $1}')"
  seq="$base_seq"

  spec_path="${TMP_DIR}/agentbox.task.$$"
  : >"$spec_path" || die "failed to open temp spec: $spec_path"
  parse_task_to_spec "$task_path_used" >"$spec_path" || die "failed to parse task"

  accept_baseline="false"
  step_failures=0

  step_idx=""
  cmd=""
  stdin_path=""
  stdout_path=""
  stderr_path=""
  note=""
  args_path=""

  while IFS="$TAB" read -r key value; do
    case "$key" in
      META_ACCEPT_BASELINE)
        case "$value" in
          true|false) accept_baseline="$value" ;;
          *) die "invalid accept_baseline (must be true|false)" ;;
        esac
        ;;
      STEP_BEGIN)
        step_idx="$value"
        cmd=""
        stdin_path=""
        stdout_path=""
        stderr_path=""
        note=""
        args_path="${TMP_DIR}/agentbox.args.${$}.${step_idx}"
        : >"$args_path" || die "failed to open temp args: $args_path"
        ;;
      CMD)
        cmd="$value"
        ;;
      ARG)
        ensure_safe_scalar "$value"
        printf '%s\n' "$value" >>"$args_path" || die "failed to write args"
        ;;
      STDIN_PATH)
        stdin_path="$value"
        ;;
      STDOUT_PATH)
        stdout_path="$value"
        ;;
      STDERR_PATH)
        stderr_path="$value"
        ;;
      NOTE)
        note="$value"
        ;;
      STEP_END)
        [ -n "$cmd" ] || die "step $step_idx: missing cmd"
        ensure_safe_scalar "$cmd"
        ensure_safe_scalar "$stdin_path"
        ensure_safe_scalar "$stdout_path"
        ensure_safe_scalar "$stderr_path"
        ensure_safe_scalar "$note"

        seq="$((seq + 1))"
        if run_step \
          "$step_idx" \
          "$cmd" \
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
        ;;
      *)
        die "unknown task spec key: $key"
        ;;
    esac
  done <"$spec_path"

  # Initialize baseline if missing.
  if [ ! -f "$SCHEMA_BASELINE_PATH" ]; then
    run_jd_fields "$SCHEMA_BASELINE_PATH" "$EVENTS_PATH" || die "jd fields failed"
  fi

  # Drift is non-fatal: treat exit 0/1 as OK (drift/no drift), >1 as operational error.
  run_jd_drift "$SCHEMA_BASELINE_PATH" "$DRIFT_PATH" "$EVENTS_PATH"
  drift_ec="$?"
  if [ "$drift_ec" -gt 1 ]; then
    die "jd drift failed (exit=$drift_ec)"
  fi

  if [ "$accept_baseline" = "true" ]; then
    run_jd_fields "$SCHEMA_BASELINE_PATH" "$EVENTS_PATH" || die "jd fields failed (accept_baseline)"
    run_jd_drift "$SCHEMA_BASELINE_PATH" "$DRIFT_PATH" "$EVENTS_PATH"
    drift_ec="$?"
    if [ "$drift_ec" -gt 1 ]; then
      die "jd drift failed after accept_baseline (exit=$drift_ec)"
    fi
  fi

  write_state "$now" "$task_path_used" "$task_sha" "$accept_baseline" "$step_failures" || die "failed to write state.json"
  write_memory_md "$now" "$task_path_used" "$task_sha" "$accept_baseline" "$step_failures" || die "failed to write MEMORY.md"

  if [ "$step_failures" -gt 0 ]; then
    exit 2
  fi
  exit 0
}

main "$@"
