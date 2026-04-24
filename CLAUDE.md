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

- **Source**: `src/main.cyr` — subcommand dispatch; `init`, `add`, `rm`, `branch`, `checkout`, `tag`, `commit`, `config`, `fsck`, `log`, `status`, `diff`, `show`, `cat-file`, `owl-file` implemented
- **Tests**: `tests/sit.tcyr` smoke only; integration coverage is shell-level for now
- **Binary**: `cyrius build src/main.cyr build/sit`
- **Object writer**: single type-agnostic `write_typed_object(type, len, content, content_len)` drives blob, tree, and commit writes. SHA-256 via sigil, zlib via sankoch, loose storage at `.sit/objects/<hex[0:2]>/<hex[2:64]>`. Framing `"<type> <len>\0<content>"` is byte-compatible with git's SHA-256 object format for all three object types
- **Trees**: recursive. `build_tree` walks sorted index entries, groups by next path segment, emits subtree objects for each group. Root tree has `40000` dir entries + `100644` file entries, byte-compatible with git's SHA-256 tree format. `flatten_tree` + `read_head_tree_entries` produce a full-path view for status/diff. Arch 003 (flat-only) resolved in v0.1.6
- **Commits**: git-parity body format; author/email from `SIT_AUTHOR_NAME` / `SIT_AUTHOR_EMAIL` env (fallback placeholder), timestamp via `clock_epoch_secs()`, tz fixed `+0000`. `.sit/refs/heads/main` updated atomically. Parent pointer linked from the previous ref value
- **Staging index**: patra-backed at `.sit/index.patra`, single `entries(path STR, hash_hex STR)` table. `parse_index`/`rewrite_index`/`index_upsert` wrap the SQL. Legacy plaintext `.sit/index` auto-migrates on first access; see [arch 002](docs/architecture/002-loose-objects-until-patra-bytes.md). Upsert-at-write semantics — at most one row per path at rest
- **Read commands**: `cat-file` (plumbing, raw bytes) and `owl-file` (decorated via [owl](https://github.com/MacCracken/owl); falls back to raw when owl isn't on PATH — owl is pre-1.0)
- **Integration**: owl consumes sit for git-marker gutter decorations once both land; owl is the downstream

## Dependencies

- **Cyrius stdlib** — `string`, `fmt`, `alloc`, `io`, `vec`, `str`, `syscalls`, `assert`, `fs`, `args`, `chrono`, `hashmap`, `process`, `tagged`, `fnptr`, `thread`, `freelist`, `bigint`, `ct`, `keccak`
- **sakshi** (2.1.0) — tracing, error handling, structured logging
- **sankoch** (2.0.1) — LZ4/DEFLATE/zlib/gzip for pack-file compression
- **sigil** (2.9.1) — hashing and trust verification for object IDs and signed commits
- **patra** (1.5.5) — B+ tree / WAL-backed object store and index

All four are git-tag pinned in `cyrius.cyml`. No FFI, no C, no libgit2 — see [ADR 0001](docs/adr/0001-no-ffi-first-party-only.md).

Cyrius has no transitive dep resolution as of 5.6.16 (fix targeted for 5.7.x), so every crate a dep touches must be declared explicitly. The `thread`/`freelist`/`bigint`/`ct`/`keccak` stdlib entries above exist because patra and sigil reach into them.

## Docs

- [`docs/development/roadmap.md`](docs/development/roadmap.md) — shipped releases + forward-looking backlog. **Single source of truth for what sit is doing next.** Same path across every MacCracken-verse project.
- [`docs/adr/`](docs/adr/) — architecture decision records. Start here for *why* sit chose X over Y. [0001](docs/adr/0001-no-ffi-first-party-only.md) is the first-party/no-FFI thesis.
- [`docs/architecture/`](docs/architecture/) — non-obvious constraints and quirks a reader can't derive from the code. **Skim this before writing new code** — e.g. [001](docs/architecture/001-args-stack-buffer-lifetime.md) documents a stdlib `args.cyr` lifetime hazard that silently affects any `argv(n)` usage.
- [`docs/guides/`](docs/guides/) — task-oriented how-tos. [Getting started](docs/guides/getting-started.md) covers build + first `sit init` / `sit add`.
- [`docs/examples/`](docs/examples/) — runnable examples; empty until sit's surface area grows past the init/add loop.

New quirks and constraints land in `docs/architecture/` as numbered items. New decisions land in `docs/adr/` using [`template.md`](docs/adr/template.md). Never renumber either series.

**Cross-project feature requests go on the target repo's `docs/development/roadmap.md`, not GitHub issues** (these repos don't use the issue tracker). When sit needs something from a dep, draft a backlog entry for the dep's roadmap rather than opening an ADR on sit's side.

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
