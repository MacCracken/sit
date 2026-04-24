# sit

> Sovereign version control — a Cyrius-native git replacement.

**sit** is version control written from scratch in [Cyrius](https://github.com/MacCracken/cyrius). No libgit2, no C, no FFI. Every layer — compression, hashing, storage, protocol — is first-party and benchmarked against its C incumbent.

The name is from *smriti* (स्मृति — "that which is remembered"). Three letters like `git`, same typing rhythm. sit vs stand, park vs push — the wordplay holds.

## Status

- **Version**: 0.1.0 (scaffolded — not yet functional)
- **Language**: Cyrius (toolchain pinned in `cyrius.cyml`)

This is an exploratory, post-boot project. Not on the AGNOS critical path.

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
