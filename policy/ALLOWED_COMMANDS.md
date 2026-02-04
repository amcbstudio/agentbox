# Allowed commands

Agentbox is intentionally a **restricted, deterministic, offline** runtime. It is not a general-purpose shell runner.

The runtime (`runtime/agent.sh`) executes task steps by invoking a command **directly** with argv (`cmd` + `args`), never via `sh -c ...` and never via `eval`.

## Allowlist

Task steps may execute only these commands:

- amcbstudio tools: `kv`, `jsonl`, `jd`
- BusyBox utilities:
  - `cat`
  - `wc`
  - `head`
  - `tail`
  - `sed`
  - `awk`
  - `diff`
  - `sha256sum`
  - `date`
  - `mkdir`
  - `ls`

## Rationale (high level)

- **Minimize attack surface**: no package manager, no compiler, no interpreters, no arbitrary shell execution.
- **Reproducibility**: a small toolchain reduces hidden dependencies and nondeterministic behavior.
- **Defense-in-depth**: even if a task is untrusted, it can only drive a narrow set of binaries.

## Enforcement details

The runtime enforces the allowlist by:

- Rejecting any `cmd` not in the allowlist.
- Rejecting `cmd` values containing `/` (no absolute/relative paths).
- Passing `args` as argv elements (no string concatenation / no eval).
- Restricting redirection targets (`stdin_path`, `stdout_path`, `stderr_path`) to files under `/work/` (no `..` path segments).
- Preventing task steps from writing into `/work/memory/` (reserved for agent-managed artifacts).
- Applying extra argument restrictions for dangerous “escape hatches”:
  - `awk`: blocks `system`, `getline`, pipes/redirections, and disallows `-f` to prevent spawning arbitrary commands.
  - `sed`: disallows `-i` and limits flags to reduce the chance of mutating files in-place.

Note: the runtime also intentionally rejects JSON string escape sequences in the task file (no backslashes) to keep parsing and execution semantics strict and predictable.
