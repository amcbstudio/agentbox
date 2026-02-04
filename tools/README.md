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

If `git submodule status` shows nothing, the submodules haven't been added to the repo yet. Add them (once) and commit:

```sh
git submodule add https://github.com/amcbstudio/kv.git tools/kv
git submodule add https://github.com/amcbstudio/jsonl.git tools/jsonl
git submodule add https://github.com/amcbstudio/jd.git tools/jd
git commit -m "Add tool submodules"
```
