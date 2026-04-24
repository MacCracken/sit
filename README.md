# sit

> Sovereign version control — a Cyrius-native git replacement.

**sit** is version control written from scratch in [Cyrius](https://github.com/MacCracken/cyrius). No libgit2, no C, no FFI. Every layer — compression, hashing, storage, protocol — is first-party and benchmarked against its C incumbent.

The name is from *smriti* (स्मृति — "that which is remembered"). Three letters like `git`, same typing rhythm. sit vs stand, park vs push — the wordplay holds.

## Status

- **Version**: 0.1.6 — local single-branch VCS is functional
- **Language**: Cyrius (toolchain pinned in `cyrius.cyml`)
- **Commands**: `init`, `add`, `commit`, `log`, `status`, `diff`, `cat-file`, `owl-file` — see [docs/guides/getting-started.md](docs/guides/getting-started.md)

Objects are SHA-256-hashed (via [sigil](https://github.com/MacCracken/sigil)) and zlib-compressed (via [sankoch](https://github.com/MacCracken/sankoch)); trees are recursive and byte-compatible with git's SHA-256 object format. Still exploratory, post-boot — not on the AGNOS critical path.

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
cyrius build src/main.cyr build/sit
cyrius test src/test.cyr
```

## License

GPL-3.0-only
