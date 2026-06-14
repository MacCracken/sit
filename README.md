# sit

> Sovereign version control — a Cyrius-native git replacement.

**sit** is version control written from scratch in [Cyrius](https://github.com/MacCracken/cyrius). No libgit2, no C, no FFI. Every layer — compression, hashing, storage, signing, protocol — is first-party and benchmarked against its C incumbent.

The name is from *smriti* (स्मृति — "that which is remembered"). Three letters like `git`, same typing rhythm. sit vs stand, park vs push — the wordplay holds.

## Status

- **Version**: see [`VERSION`](VERSION) (single source of truth) and [`docs/development/state.md`](docs/development/state.md) for the live state snapshot (current version, dep pins, source layout, recent releases).
- **Language**: Cyrius (toolchain pinned in [`cyrius.cyml`](cyrius.cyml) under `[package].cyrius`).
- **Commands** (26): `init`, `add`, `rm`, `branch`, `checkout`, `tag`, `merge`, `merge-base`, `reset`, `commit`, `config`, `fsck`, `key`, `verify-commit`, `remote`, `fetch`, `pull`, `push`, `clone`, `serve`, `log`, `status`, `diff`, `show`, `cat-file`, `owl-file` — see [docs/guides/getting-started.md](docs/guides/getting-started.md).
- **Transports**: `file://` (+ bare paths) · `http://` · **`https://`** (first-party TLS 1.3, TOFU-pinned) · `ssh://`. Clone / fetch / push work over all four; `sit serve` is the loopback HTTP daemon (`--tls` for HTTPS, `--stdio` for SSH).

Objects are SHA-256-hashed (via [sigil](https://github.com/MacCracken/sigil)) and zlib-compressed (via [sankoch](https://github.com/MacCracken/sankoch)), stored in a [patra](https://github.com/MacCracken/patra) table with a `COL_BYTES` content column. Trees are recursive and byte-compatible with git's SHA-256 object format. Commits can be ed25519-signed via sigil.

**What works** (the full git-parity surface, heading into the v1.0.0 cut): the local VCS loop (init → add → commit → branch → merge → tag); ed25519 signed commits + `verify-commit`; `fsck` with integrity + reachability (`dangling`) + `--prune`; git-parity `.sitignore` (negation, `**`, char classes, anchoring); `log --graph`, shallow clone (`--depth N`), and `merge-base` (full-DAG lowest common ancestor); and network sync — clone / fetch / push over HTTP, **HTTPS (first-party Cyrius TLS — no libssl)**, and SSH, with `sit serve` on the host side. Intentionally post-boot — not on the AGNOS critical path.

## Size and performance

sit is a single statically-linked binary with **no dynamic dependencies**. git's primary binary plus its `git-core/*` dispatch tree pull in libpcre2, libz-ng, and libc. The footprint comparison and live `git-vs-sit` numbers (where sit wins, where it loses, what bounds each lagging row, and how the picture has evolved across releases) live in [docs/development/benchmarks-git-v-sit.md](docs/development/benchmarks-git-v-sit.md). Honest reporting — slow rows are kept in plain sight.

Per-release snapshots with before/after tables and "what didn't move and why" decompositions sit under [docs/benchmarks/](docs/benchmarks/).

## Architecture

Each layer is first-party, no C below the Cyrius compiler:

| Layer | Crate | Replaces |
|-------|-------|----------|
| Compression | [sankoch](https://github.com/MacCracken/sankoch) | zlib |
| Hashing / signing | [sigil](https://github.com/MacCracken/sigil) | OpenSSL / libsha / ed25519 |
| Object store | [patra](https://github.com/MacCracken/patra) | loose objects + pack files |
| Wire protocol | sit (first-party `/sit/v1/...` JSON/REST, in-tree) | git smart-HTTP |
| TLS (HTTPS) | cyrius `lib/tls_native.cyr` (TLS 1.3) | OpenSSL / libssl |

The no-FFI thesis holds end-to-end: `ldd build/sit` reports *not a dynamic executable*, and HTTPS rides cyrius's own pure-Cyrius TLS 1.3 stack rather than libssl ([ADR 0007](docs/adr/0007-network-transport-security.md)). SSH reuses the system `ssh` binary as a process boundary, not an FFI dep ([ADR 0008](docs/adr/0008-ssh-transport.md)).

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
cyrius bench tests/sit.bcyr   # SHA-256 / zlib / patra / LCS-diff / .sitignore / blob-hash
cyrius run tests/sit.fcyr     # fuzz: hash / zlib / hex-decode / URL / ssh-url / want-frame
```

## Docs

- [`docs/guides/getting-started.md`](docs/guides/getting-started.md) — build + use
- [`CHANGELOG.md`](CHANGELOG.md) — shipped history (tagged releases) · [`docs/development/roadmap.md`](docs/development/roadmap.md) — what's next · [`docs/development/state.md`](docs/development/state.md) — live state snapshot
- [`docs/adr/`](docs/adr/) — decisions, starting with [0001 — no FFI](docs/adr/0001-no-ffi-first-party-only.md)
- [`docs/architecture/`](docs/architecture/) — non-obvious constraints that outlive the code
- [`docs/examples/`](docs/examples/) — runnable examples

## Contributing & security

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — build/test gates, Cyrius conventions, the no-FFI bar
- [`SECURITY.md`](SECURITY.md) — threat model + how to report a vulnerability (don't open a public issue)
- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)

## License

GPL-3.0-only

