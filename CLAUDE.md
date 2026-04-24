# sit — Claude Code Instructions

## Project Identity

**sit** (Sanskrit: *smriti*, स्मृति — "that which is remembered") — sovereign version control, a Cyrius-native git replacement.

- **Type**: Binary (VCS tool)
- **License**: GPL-3.0-only
- **Language**: Cyrius (toolchain pinned in `cyrius.cyml [package].cyrius`, currently 5.6.16)
- **Version**: SemVer, `VERSION` is the source of truth
- **Status**: 0.1.0 — scaffolded via `cyrius init sit`, no functional code yet
- **Genesis repo**: [agnosticos](https://github.com/MacCracken/agnosticos)
- **Standards**: [First-Party Standards](https://github.com/MacCracken/agnosticos/blob/main/docs/development/applications/first-party-standards.md)

## Goal

Own the "track a codebase over time" job on AGNOS. No libgit2, no C, no FFI. Every layer — compression, hashing, storage, protocol — is first-party Cyrius and benchmarked against its C incumbent.

Intentionally not on the AGNOS critical path. This is a post-boot, when-there's-time project. The opening move is getting a minimal `sit init` / `sit add` / `sit commit` loop working against patra-backed objects and sigil-hashed refs.

## Scaffolding

Project was scaffolded with `cyrius init sit`. Do not manually create project structure — use the tools. If the tools are missing something, fix the tools.

## Current State

- **Source**: `src/main.cyr` stub only
- **Tests**: `src/test.cyr` stub only
- **Binary**: not yet building meaningful output
- **Integration**: no downstream consumers yet; owl will consume sit for git-marker gutter decorations once sit is functional

## Dependencies

- **Cyrius stdlib** — `string`, `fmt`, `alloc`, `io`, `vec`, `str`, `syscalls`, `assert`, `fs`, `args`, `chrono`, `hashmap`, `process`, `tagged`, `fnptr`
- **sakshi** (2.1.0) — tracing, error handling, structured logging
- **sankoch** (2.0.1) — LZ4/DEFLATE/zlib/gzip for pack-file compression
- **sigil** (2.9.1) — hashing and trust verification for object IDs and signed commits
- **patra** (1.5.5) — B+ tree / WAL-backed object store and index

All four are git-tag pinned in `cyrius.cyml`. No FFI, no C, no libgit2.

## Rules

- **Read the genesis repo's CLAUDE.md first** — see [agnosticos/CLAUDE.md](https://github.com/MacCracken/agnosticos/blob/main/CLAUDE.md).
- **Never use `gh` CLI** — use `curl` to the GitHub API if needed.
- **Do not commit or push** — the user handles all git operations.
- **Build with `cyrius build`, never raw `cc5`** — the manifest auto-resolves deps and prepends includes.
- **Programs call `main()` at top level** — see Cyrius field notes for the pattern.

## Naming

The name is deliberate and stays:

- **smriti** (स्मृति) — memory, that which is remembered. The Sanskrit root.
- **Three letters**, same typing rhythm as `git`.
- **sit vs stand, park vs push** — the verb wordplay holds.
- **Phonetic echo of "symmetry"** — version control as mirrored state.
- Cultural thread with **sitar**, matching the AGNOS Sanskrit-leaning naming.
