# sit

> Sovereign version control — a Cyrius-native git replacement.

**sit** is version control written from scratch in [Cyrius](https://github.com/MacCracken/cyrius). No libgit2, no C, no FFI. Every layer — compression, hashing, storage, signing, protocol — is first-party and benchmarked against its C incumbent.

The name is from *smriti* (स्मृति — "that which is remembered"). Three letters like `git`, same typing rhythm. sit vs stand, park vs push — the wordplay holds.

## Status

- **Version**: 0.6.0 — security hardening. All CRITICAL + HIGH findings from the 2026-04-24 P(-1) audit fixed: input validators for ref names / tree entries / hash prefixes / config values / remote URLs, local-clone symlink guards (CVE-2023-22490 class), tightened decompression caps, output escape filter for attacker-controlled identity bytes. 3 new ADRs, 101 test assertions (up from 31). Network transport shifts to v0.7.0.
- **Language**: Cyrius (toolchain pinned in `cyrius.cyml` under `[package].cyrius`)
- **Commands** (24): `init`, `add`, `rm`, `branch`, `checkout`, `tag`, `merge`, `reset`, `commit`, `config`, `fsck`, `key`, `verify-commit`, `remote`, `fetch`, `pull`, `push`, `clone`, `log`, `status`, `diff`, `show`, `cat-file`, `owl-file` — see [docs/guides/getting-started.md](docs/guides/getting-started.md)

Objects are SHA-256-hashed (via [sigil](https://github.com/MacCracken/sigil)) and zlib-compressed (via [sankoch](https://github.com/MacCracken/sankoch)), stored in a [patra](https://github.com/MacCracken/patra) table with a `COL_BYTES` content column. Trees are recursive and byte-compatible with git's SHA-256 object format. Commits can be ed25519-signed via sigil. Still exploratory, post-boot — not on the AGNOS critical path.

## Size and performance

| | sit | git |
|---|---:|---:|
| binary (primary) | **593 KB** | 4.4 MB (7.5× larger) |
| total install footprint | **593 KB** (one static binary) | 7.4 MB across 183 `git-core` binaries (12× larger) |
| dynamic dependencies | **none** | libpcre2, libz-ng, libc |

sit is **faster than git** on `init`, `commit`, `diff`, `log`, and `status` on this host (static binary, no dispatch through `git-core`). Notably slower on `add` of a large blob — sigil's software SHA-256 bottleneck. Full methodology and numbers: [docs/development/benchmarks-git-v-sit.md](docs/development/benchmarks-git-v-sit.md).

## Architecture

Each layer is first-party, no C below the Cyrius compiler:

| Layer | Crate | Replaces |
|-------|-------|----------|
| Compression | [sankoch](https://github.com/MacCracken/sankoch) | zlib |
| Hashing / signing | [sigil](https://github.com/MacCracken/sigil) | OpenSSL / libsha / ed25519 |
| Object store | [patra](https://github.com/MacCracken/patra) | loose objects + pack files |
| Wire protocol | sit (first-party, in-tree) | smart-HTTP / ssh |

See [ADR 0001](docs/adr/0001-no-ffi-first-party-only.md) for the first-party thesis.

## Quickstart

```sh
# build
cyrius build src/main.cyr build/sit

# run tests (sigil SHA-256 / git-framing / zlib roundtrip / patra BYTES / ed25519)
cyrius test tests/sit.tcyr

# use it
mkdir /tmp/demo && cd /tmp/demo
/path/to/sit/build/sit init
echo "hello, sit!" > greeting.txt
/path/to/sit/build/sit add greeting.txt
/path/to/sit/build/sit commit -m "first commit"

# sign commits (ed25519 via sigil)
/path/to/sit/build/sit key generate
/path/to/sit/build/sit commit -S -m "signed commit"
/path/to/sit/build/sit verify-commit
```

Full walkthrough: [docs/guides/getting-started.md](docs/guides/getting-started.md).

## Benchmarks and fuzz

```sh
cyrius build tests/sit.bcyr build/sit-bench && ./build/sit-bench
cyrius build tests/sit.fcyr build/sit-fuzz && ./build/sit-fuzz
```

## Docs

- [`docs/guides/getting-started.md`](docs/guides/getting-started.md) — build + use
- [`docs/development/roadmap.md`](docs/development/roadmap.md) — what shipped, what's next
- [`docs/adr/`](docs/adr/) — decisions, starting with [0001 — no FFI](docs/adr/0001-no-ffi-first-party-only.md)
- [`docs/architecture/`](docs/architecture/) — non-obvious constraints that outlive the code
- [`docs/examples/`](docs/examples/) — runnable examples

## License

GPL-3.0-only
