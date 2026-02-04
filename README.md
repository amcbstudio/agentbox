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

The binaries `kv`, `jsonl`, `jd`, and `molt` are expected under `tools/` as **git submodules**:

```sh
git submodule update --init --recursive
```

The Docker build copies `tools/` from the working tree. It must succeed offline when submodules are present.

Recommended clone:

```sh
git clone --recurse-submodules <repo-url>
```

## Run

```sh
mkdir -p work
docker compose up --build --force-recreate
```

By default, the runtime reads:

- `/work/task.json` if present (mounted from `./work/task.json`)
- otherwise `/tasks/demo/task.json` from the image

### Publish run (online profile)

Publishing requires outbound HTTPS. Use the profile-enabled service:

```sh
docker compose --profile molt up --build agentbox-molt
```

Provide the API key as a single-line file mounted under `/work`:

```sh
mkdir -p work/secrets
printf '%s' "YOUR_API_KEY" > work/secrets/moltbook_api_key.txt
```

Security note: API keys must only be used with https://www.moltbook.com (moltbox enforces this).

## Task format (minimal)

Task files are JSON with:

- `version` (must be `1`)
- `steps` array of objects with:
  - `cmd` (string; allowlisted)
  - `args` (array of strings; optional)
  - `stdin_path` / `stdout_path` / `stderr_path` (optional; must be under `/work/`)
  - `note` (optional; included in event schema and used by demo to show drift)
- `accept_baseline` (optional boolean; when `true` rewrites `schema.fields.jsonl` to match current events)
- `publish` (optional object; see below)

Parsing and validation are performed with `jq`, so full JSON escaping is supported.

Security note: any **absolute** argument starting with `/` must also start with `/work/`, otherwise the task is rejected.

### Optional publish (Moltbook)

```json
"publish": {
  "provider": "moltbook",
  "enabled": true,
  "mode": "post",
  "submolt": "general",
  "title": "optional string (post only)",
  "post_id": "required if mode=comment",
  "api_key_path": "/work/secrets/moltbook_api_key.txt",
  "jsonl_events": "/work/memory/molt.events.jsonl"
}
```

Rules:

- If `publish` is missing or `enabled=false`, no publish happens.
- If `enabled=true`, `provider` must be exactly `moltbook`.
- `api_key_path` must exist and be a file.
- For `mode=comment`, `post_id` is required.
- `MEMORY.md` must exist (publish fails if missing).
- API keys are never printed or logged.

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
6) publish post (Moltbook)
7) publish comment (Moltbook)

## Non-goals

- Not an LLM agent
- Not a general shell runner
- No network access, package installs, or dynamic plugins
- No “execute arbitrary script” task steps
