# agentbox

Agentbox is a minimal “dumb agent” runtime designed to run **offline**, under a **tight sandbox**, and produce **persistent, file-based memory** in a mounted `/work` directory:

- `work/memory/events.jsonl` (append-only step log)
- `work/memory/schema.fields.jsonl` (schema baseline, via `jd fields`)
- `work/memory/drift.jsonl` (schema drift report, via `jd drift`)
- `work/memory/state.json` (deterministic compaction summary)
- `work/memory/MEMORY.md` (human-readable summary)

## Security posture (default)

The provided `docker-compose.yml` runs the container with:

- **No network** (`network_mode: none`)
- **Non-root** (`user: 1000:1000`)
- **Read-only root filesystem** (`read_only: true`; only the `/work` bind mount is writable)
- **No Linux capabilities** (`cap_drop: ["ALL"]`)
- **No new privileges** (`no-new-privileges:true`)
- **Resource limits** (pids/memory/cpu)

The runtime itself (`runtime/agent.sh`) additionally enforces:

- Command **allowlist** (see `policy/ALLOWED_COMMANDS.md`)
- No `sh -c ...` and no `eval` of task content
- I/O redirections restricted to `/work/...` (and task steps may not write to `/work/memory/...`)
- Absolute args must be under `/work/` (any arg starting with `/` but not `/work/` is rejected)

## Tools distribution (hard requirement)

The binaries `kv`, `jsonl`, and `jd` are expected under `tools/` as **git submodules**:

```sh
git submodule update --init --recursive
```

The Docker build copies `tools/` from the working tree. It must succeed offline when submodules are present.

## Run

```sh
mkdir -p work
docker compose up --build --force-recreate
```

By default, the runtime reads:

- `/work/task.json` if present (mounted from `./work/task.json`)
- otherwise `/tasks/demo/task.json` from the image

## Task format (minimal)

Task files are JSON with:

- `version` (must be `1`)
- `steps` array of objects with:
  - `cmd` (string; allowlisted)
  - `args` (array of strings; optional)
  - `stdin_path` / `stdout_path` / `stderr_path` (optional; must be under `/work/`)
  - `note` (optional; included in event schema and used by demo to show drift)
- `accept_baseline` (optional boolean; when `true` rewrites `schema.fields.jsonl` to match current events)

Parsing and validation are performed with `jq`, so full JSON escaping is supported.

Security note: any **absolute** argument starting with `/` must also start with `/work/`, otherwise the task is rejected.

## Troubleshooting

- `missing required command: jd` (or `kv` / `jsonl`): initialize submodules on the host and rebuild:
  - `git submodule update --init --recursive`
  - `docker compose up --build --force-recreate`

## Demo

See `tasks/demo/README.md` for a multi-run workflow:

1) baseline creation
2) drift detection
3) baseline acceptance
4) JSON escapes
5) forbidden path rejection

## Non-goals

- Not an LLM agent
- Not a general shell runner
- No network access, package installs, or dynamic plugins
- No “execute arbitrary script” task steps
