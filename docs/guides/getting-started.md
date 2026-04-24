# Getting started

Build sit from source and initialize your first repository.

## Prerequisites

- Cyrius toolchain — version pinned in `cyrius.cyml` under `[package].cyrius` (currently **5.6.16**). Check `cyrius --version`.
- Linux x86_64. Other targets will work when the corresponding `syscalls_*` stdlib modules are exercised, but x86_64 Linux is the primary target today.

## Build

```sh
cyrius build src/main.cyr build/sit
```

First build fetches the git deps (sakshi, sankoch, sigil, patra) into `~/.cyrius/deps/<name>/<tag>/` and symlinks them into `lib/`. Subsequent builds are cached.

Run the test suite:

```sh
cyrius test
```

## Try it

```sh
mkdir /tmp/sit-demo && cd /tmp/sit-demo
/path/to/sit/build/sit init
```

Expected output:

```
initialized empty sit repository in .sit/
```

Inspect the layout:

```sh
find .sit
# .sit
# .sit/HEAD
# .sit/objects
# .sit/refs
# .sit/refs/heads

cat .sit/HEAD
# ref: refs/heads/main
```

Layout and HEAD contents are byte-compatible with a freshly-initialized git repository, by design.

Re-running `sit init` is idempotent: it prints `reinitialized existing sit repository in .sit/` and exits 0.

## What works today

- `sit init` — create empty repository

## What doesn't yet

- `sit add` — staging
- `sit commit` — object creation
- everything else

Track progress in `CHANGELOG.md`. Design notes live in [`../architecture/`](../architecture/); decisions in [`../adr/`](../adr/).
