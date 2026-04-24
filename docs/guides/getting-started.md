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

## Add a file

```sh
echo "hello, sit!" > greeting.txt
/path/to/sit/build/sit add greeting.txt
# added 37f70a18b0d2 greeting.txt
```

What that did:

1. Wrapped the file content with git's `"blob <len>\0<content>"` framing.
2. Hashed the framed bytes with sigil (SHA-256) → 64-char hex object ID.
3. Compressed the framed bytes with sankoch (`zlib_compress`, level 6).
4. Wrote the compressed blob to `.sit/objects/37/f70a18b0d2...`.
5. Appended `<hash>\t<path>\n` to the staging index at `.sit/index`.

Verify with any zlib-capable tool:

```sh
python3 -c "
import zlib
print(zlib.decompress(open('.sit/objects/37/f70a18b0d27d5dd912f6080063bf6fe10820814bccc4bcd13c67ce97c2a96c','rb').read()))
# b'blob 12\\x00hello, sit!\\n'
"
```

Sit's object hashes are byte-identical to git's SHA-256 object hashes for the same content — see [ADR 0001](../adr/0001-no-ffi-first-party-only.md) for why we reimplement the stack rather than bind to libgit2.

## What works today

- `sit init` — create empty repository
- `sit add <path>` — hash, compress, and store a file as a blob object; append to staging index

## What doesn't yet

- `sit commit` — tree + commit object creation
- `sit status`, `sit log`, `sit cat-file`, everything else

Track progress in `CHANGELOG.md`. Design notes live in [`../architecture/`](../architecture/); decisions in [`../adr/`](../adr/).
