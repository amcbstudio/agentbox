# Demo tasks

These tasks are designed to show:

1) first-run baseline creation (`schema.fields.jsonl`)
2) schema drift detection (`drift.jsonl`)
3) baseline acceptance workflow (`accept_baseline`)

## Run 1 (default)

```sh
docker compose up --build --force-recreate
```

Uses `tasks/demo/task.json` (only when `work/task.json` is not present).

## Run 2 (introduce drift)

```sh
cp tasks/demo/task.drift.json work/task.json
docker compose up --build --force-recreate
```

This task adds a per-step `note`, which changes the event schema and should show up in `work/memory/drift.jsonl`.

## Run 3 (accept baseline)

```sh
cp tasks/demo/task.accept-baseline.json work/task.json
docker compose up --build --force-recreate
```

This task sets `"accept_baseline": true`, which updates `schema.fields.jsonl` to match the current event schema and re-runs drift.

## Run 4 (JSON escapes)

```sh
cp tasks/demo/task.escapes.json work/task.json
docker compose up --build --force-recreate
```

This task includes a `note` with quotes, newlines, and backslashes to prove `jq`-based parsing works.

## Run 5 (forbidden path)

```sh
cp tasks/demo/task.forbidden-path.json work/task.json
docker compose up --build --force-recreate
```

This task tries to read `/etc/passwd` via an absolute arg. It should fail with exit code 2 and emit a JSON `type=error` event.

## Run 6 (publish post)

```sh
cp tasks/demo/task.publish.post.json work/task.json
docker compose --profile molt up --build agentbox-molt
```

Requires `work/secrets/moltbook_api_key.txt` (single-line API key).

## Run 7 (publish comment)

```sh
cp tasks/demo/task.publish.comment.json work/task.json
docker compose --profile molt up --build agentbox-molt
```

This task requires a real `post_id` in the JSON.
