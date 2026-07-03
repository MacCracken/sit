# 0011 — Read-only `.git/` repository support

**Status**: Accepted
**Date**: 2026-07-03

## Context

sit is SHA-256-native and stores its objects in a patra DB under `.sit/` ([ADR 0004](0004-sha256-only.md)). Its consumers, however, live in a world of ordinary git repositories: thoth wants a status bar and tool-call diffs, owl wants gutter markers — both on whatever repo the user actually has open, which is almost always a SHA-1 `.git/` repo, not a sit-native one. Until now the public API ([ADR 0009](0009-public-api-contract.md)) — `sit_repo_open` / `sit_diff_path` and the `ann_*` accessors — was hardcoded to `.sit/`: it gated on `.sit/HEAD`, resolved refs under `.sit/refs/`, and read objects exclusively from the patra store via `read_object`.

So a consumer that wanted branch/status/diff on a real git repo had two bad options: shell out to system `git` (requires git installed, and re-introduces the process/FFI-shaped dependency the whole project exists to avoid), or carry a second, git-specific code path of its own. We want a third option: the *same* API entry points work on a git repo, and the caller never has to know which storage backend answered.

The forcing constraint is [ADR 0001](0001-no-ffi-first-party-only.md): no libgit2, no C, no FFI. Every layer of git's on-disk format — loose objects, packfiles, `.idx`, delta encoding, packed-refs — has to be re-read in first-party Cyrius or not at all.

## Decision

**sit reads an existing git repository read-only, behind the same public API it exposes for `.sit/` repos, via a storage seam.** `sit_repo_open` detects `.git/` vs `.sit/` and sets a process-global backend; the three storage-touching primitives — `read_object`, `read_head_ref`, `resolve_ref_name` — dispatch on it, and every layer above them (tree walk, commit parse, diff, status) stays storage-agnostic. Object-id width is centralised in `_id_hexlen()` / `_id_rawlen()` so the SHA-1 (20-byte / 40-hex) vs SHA-256 (32/64) difference collapses to two helpers instead of ~18 scattered literals.

In scope (read):
- **Objects**: loose (`.git/objects/xx/…`, zlib) and packed (`.idx` v2 lookup + pack v2 decode + a first-party OFS_DELTA/REF_DELTA copy/insert interpreter with recursive base chains). No new dependency — zlib is sankoch, already in hand; the delta interpreter is git-specific and self-written.
- **Refs**: `.git/HEAD` (symref + detached), `.git/refs/`, and `.git/packed-refs`.
- **Hash algorithm**: SHA-1 (git default) and SHA-256 git repos (detected from `.git/config extensions.objectFormat`).
- **Public surface**: existing `sit_repo_open` / `sit_diff_path` start working on git repos; new additive accessors `sit_repo_branch` and `sit_repo_status` (+ `sit_status_path` / `sit_status_kind`) — a SemVer-minor addition under ADR 0009.

Explicitly out of scope:
- **`.git/` write-back.** sit stays `.sit/`-native for its own repos; it never mutates a `.git/`. This is a read bridge for consumers, not a git reimplementation.
- **The git staging index (`.git/index`).** `sit_repo_status` is HEAD-vs-worktree only — no staged/unstaged split. owl/thoth need worktree-vs-HEAD; the binary index is a later add if a consumer asks.
- **SHA-1 computation.** Read-mode looks objects up *by* their id (loose path + `.idx`); it never needs to *compute* SHA-1. Integrity verification (an fsck-equivalent over a git repo) would need a first-party SHA-1 in sigil and is deferred.

**Relationship to [ADR 0004](0004-sha256-only.md).** ADR 0004 rejected, as a downgrade-attack foothold, the alternative of "accept SHA-1-hashed pack files for read-only operations." That rejection was framed around sit's *wire protocol and trust boundary* — a malicious remote forcing SHA-1 into content sit would hash, verify, or ingest. This decision is narrower and stays inside ADR 0004's own escape hatch ("the SHA-1 hash never enters sit's trust boundary"): sit reads the user's *local* `.git/` (the [ADR 0005](0005-local-clone-threat-model.md) threat model, not a remote), never *computes* SHA-1, never verifies or signs with it, and never ingests a git object into its SHA-256 store — the id is an opaque filesystem / `.idx` lookup key for a read-only display. sit's collision immunity for its own objects, wire, and signatures is unchanged; ADR 0004's wire-protocol and object-store prohibition stands unamended.

Module structure: `src/git_read.cyr` (backend detection, width helpers, loose-object read; the git ref readers are co-located in `refs.cyr` next to `read_head_ref_path`), `src/git_pack.cyr` (packfile + delta). Both are in `[lib].modules` so the `dist/sit.cyr` bundle carries them for consumers.

## Consequences

- **Positive** — Consumers get git interop through one API: owl's single `sit_diff_path` call and thoth's branch/status now light up on real git repos with zero consumer-side branching. No new dependency and no FFI — the no-libgit2 thesis holds even for reading git's own format. The width abstraction made the whole refactor green-preserving: `.sit`-mode behaviour is byte-identical because the helpers return the SHA-256 widths by default.
- **Negative** — sit now owns a read implementation of git's on-disk format: packfile v2, `.idx` v2, the delta instruction stream, packed-refs. If git evolves the format, that's sit's maintenance burden. There is no integrity check on git objects (no SHA-1), so a corrupt git object is trusted as read — acceptable for a read-only view of the user's own repo, but not a verification tool. The one-entry pack cache and whole-file pack loads are correctness-first, not tuned for huge packs.
- **Neutral** — Follow-on work this creates but doesn't force: CLI `sit status` / `log` / `diff` on git repos (today only `cat-file` / `owl-file` are git-aware via the shared read path); a durable test for `sit_repo_status` (validated this cycle against `git status --porcelain`, but the integration suite is CLI-based); `@{N}` reflog selectors on git; nested `.gitignore` / `info/exclude` (only the top-level `.gitignore` is honoured); and first-party SHA-1 if verification is ever wanted.

## Alternatives considered

- **Shell out to system `git`.** Rejected: requires git on the host and re-introduces exactly the external-tool dependency sit exists to eliminate; a consumer on a sit-only system would silently lose the feature.
- **Link libgit2.** Rejected outright by [ADR 0001](0001-no-ffi-first-party-only.md) — no C, no FFI.
- **A separate `.git`-only reader that does not share the public API.** Rejected: it pushes a two-backend branch into every consumer. The storage seam keeps callers storage-agnostic — the reason `sit_diff_path` needed no new consumer code at all.
- **Depend on sankoch for a git-delta primitive.** The 1.1.0 roadmap framed the packfile half as blocked on this. Rejected as unnecessary: git's OFS/REF delta is a git-specific copy/insert stream, ~40 lines of interpreter that belong in sit; the only real dependency (zlib inflate for packed streams) was already available. This unblocked the packfile half a full minor early.
- **Compute SHA-1 to verify objects on read.** Deferred, not rejected: sigil has no general-purpose SHA-1 (its `sha1` refs are TPM-only), and read-mode provably never needs it. Wiring a first-party SHA-1 is a separate, verification-only decision.
