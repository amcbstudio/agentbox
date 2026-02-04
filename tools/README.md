# Tools (git submodules)

This repo expects the following tool repositories to be present as **git submodules** under `tools/`:

- `tools/kv`
- `tools/jsonl`
- `tools/jd`

The Docker build **must not** fetch these tools from the network. It copies `tools/` from the working tree into the image.

If you're using git, initialize submodules before building:

```sh
git submodule update --init --recursive
```

