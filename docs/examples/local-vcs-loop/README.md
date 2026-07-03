# Example — Local VCS loop

End-to-end shell walkthrough: init → add → branch → signed-commit → merge → verify → diff. Covers every major sit command in one transcript.

## What it demonstrates

- `sit init` and the `.sit/` layout
- `sit add` + `sit commit` on a single file
- `sit branch` / `sit checkout -b` for feature work
- `sit commit -S` (signed) with `sit key generate` + `sit verify-commit`
- Fast-forward and 3-way merges
- `sit status`, `sit diff`, `sit show --stat`, `sit log`

## Running it

```sh
cyrius build src/main.cyr build/sit
./docs/examples/local-vcs-loop/walkthrough.sh
```

The script cleans up after itself (`/tmp/sit-example-*` directories) and is idempotent — run it twice, get the same output modulo timestamps and hashes. It expects `SIT` to point at a built binary, defaulting to `$PWD/build/sit` if not set.

## Why this exists

`docs/guides/getting-started.md` covers each command individually. This example shows them composing into an actual session — useful when you want to verify a change didn't regress the cross-command flow without reading 300 lines of prose.

Network sync (clone / fetch / push) shipped in v0.5.0 and is exercised by the in-tree integration suite ([`tests/integration/run.sh`](../../../tests/integration/run.sh)) and documented in [getting-started](../../guides/getting-started.md), rather than as a sibling example directory.
