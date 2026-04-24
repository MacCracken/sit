# sit

> Sovereign version control — a Cyrius-native git replacement.

**sit** is version control written from scratch in [Cyrius](https://github.com/MacCracken/cyrius). No libgit2, no C, no FFI. Every layer — compression, hashing, storage, protocol — is first-party and benchmarked against its C incumbent.

The name is from *smriti* (स्मृति — "that which is remembered"). Three letters like `git`, same typing rhythm. sit vs stand, park vs push — the wordplay holds.

## Status

- **Version**: 0.2.4 — local single-branch-plus VCS is functional, including branches, tags, config, fsck, and ref resolution (HEAD / branch / tag).
- **Language**: Cyrius (toolchain pinned in `cyrius.cyml`)
- **Commands** (15): `init`, `add`, `rm`, `branch`, `checkout`, `tag`, `commit`, `config`, `fsck`, `log`, `status`, `diff`, `show`, `cat-file`, `owl-file` — see [docs/guides/getting-started.md](docs/guides/getting-started.md)

Objects are SHA-256-hashed (via [sigil](https://github.com/MacCracken/sigil)) and zlib-compressed (via [sankoch](https://github.com/MacCracken/sankoch)); trees are recursive and byte-compatible with git's SHA-256 object format. Still exploratory, post-boot — not on the AGNOS critical path.

## Size and performance

| | sit | git |
|---|---:|---:|
| binary (primary) | **593 KB** | 4.4 MB (7.5× larger) |
| total install footprint | **593 KB** (one static binary) | 7.4 MB across 183 `git-core` binaries (12× larger) |
| dynamic dependencies | **none** | libpcre2, libz-ng, libc |

sit is **faster than git** on `init`, `commit`, and `diff` on this host (static binary, no dispatch through `git-core`). Roughly at parity for `status` and `log`. Notably slower on `add` of a large blob — sigil's software SHA-256 bottleneck. Full methodology and numbers: [docs/development/benchmarks-git-v-sit.md](docs/development/benchmarks-git-v-sit.md).

## Architecture

Each layer lands as sit grows:

| Layer | Crate | Replaces |
|-------|-------|----------|
| Compression | [sankoch](https://github.com/MacCracken/sankoch) | zlib |
| Hashing / trust | [sigil](https://github.com/MacCracken/sigil) | OpenSSL/libsha |
| Object store | [patra](https://github.com/MacCracken/patra) | loose objects + pack files |
| Protocol | sit (first-party) | smart HTTP / ssh wire protocol |

## Build

```sh
# one-shot build
cyrius build src/main.cyr build/sit

# test suite (real tests — SHA-256 known-answers, git-framing, zlib roundtrip, hex)
cyrius test

# benchmarks (sigil + sankoch primitive throughput)
cyrius build tests/sit.bcyr build/sit-bench && ./build/sit-bench

# fuzz harness (random inputs to decompress / hash / hex_decode)
cyrius build tests/sit.fcyr build/sit-fuzz && ./build/sit-fuzz
```

## License

GPL-3.0-only
