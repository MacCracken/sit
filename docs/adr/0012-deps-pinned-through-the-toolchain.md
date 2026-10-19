# 0012 — First-party dependencies are pinned through the toolchain, not as git deps

**Status**: Accepted
**Date**: 2026-10-19 (decided in 1.3.6, 2026-08-17; recorded here when the rationale moved out of `cyrius.cyml`)

## Context

sit's four first-party layers — **sankoch** (zlib / DEFLATE, git's pack compression), **sigil** (SHA-256 + ed25519), **patra** (B+ tree / WAL object store) and **sakshi** (structured logging, reached transitively) — were `[deps.<name>]` git blocks through 1.3.5, each pinned to its own tag.

The cyrius stdlib snapshot now ships all four as folded modules (`lib/<name>.cyr`), alongside `sandhi`. That left two ways to consume them: keep the git pins, or declare them as `[deps].stdlib` leaves and let the toolchain pin choose their versions. Two measured failures settled it.

1. **A git pin overrides the fold for everything downstream.** `cyrius deps` lays a git dep's resolution on top of the snapshot on every build and recurses through sibling manifests. A stale pin therefore pushes the older file onto any consumer that reaches sit transitively. The only signal is an unnamed "N bundled lib(s) differ" shadow warning. `deps --verify` cannot catch it, because the lock is written from disk and so records the hash of the downgraded file. patra hit this four levels deep (patra 1.13.0) and sigil independently (sigil 3.12.7); both dropped their own pins for this reason.
2. **A git dep drops the module from the bundle sidecar.** On a bundle-publishing project, `cyrius distlib` reclassifies a git dep out of the stdlib leaves, so `dist/sit.deps` no longer lists it. At 1.3.5's shape, `dist/sit.cyr` referenced 27 symbols across sigil / sankoch / patra while the sidecar listed none of the three modules that define them. A consumer building from bundle + sidecar could not resolve them. kavach hit the same reclassification.

## Decision

**The `cyrius` pin in `cyrius.cyml [package]` is the single version lever for every dependency sit has.** sakshi / sankoch / sigil / patra / sandhi are `[deps].stdlib` leaves. sit carries **no** `[deps.<name>]` git blocks, and `cyrius.lock` holds no commit pins.

- **Do not re-add a `[deps.<name>]` block for a folded module**, not even to "just pin" a version. Pinning a dependency version means bumping the toolchain.
- **Declare every stdlib module that sit or a folded layer reaches, explicitly**, even when the resolver currently finds it transitively. `thread`, `thread_local`, `sync`, `bayan`, `random`, `tls_native` and the like stay listed. An undeclared module of this kind can fail at **runtime** rather than at build time. That is how the missing `random` module made `sit key generate` SIGILL at 1.0.2. Transitive resolution has also historically missed enum and constant references, which reach sandhi's TLS shim and sigil's crypto primitives.

The folded versions behind a given pin are volatile; they are recorded per release in [`docs/development/state.md`](../development/state.md#dependencies-current-versions), not here.

## Consequences

- **Positive** — consumers of `dist/sit.cyr` get the same dependency versions sit was built and tested against, and nothing downstream is silently downgraded. The bundle sidecar lists every leaf the bundle needs.
- **Positive** — "update deps to latest" is one edit: bump the pin, wipe `lib/`, `cyrius deps`, build.
- **Negative** — sit cannot take a dependency fix ahead of the toolchain folding it. A fix released in a dependency's own repo arrives only when a cyrius release folds it.
- **Negative** — every toolchain bump is also a dependency bump across the compression, hashing and storage layers at once. A routine pin bump can carry data-integrity or security changes; the sankoch >1 MiB corruption fix rode in on one. Each bump gets verified, not skimmed: diff the folded modules, A/B the on-disk format across the old and new builds, and re-run the benchmarks.
- **Neutral** — the explicit `[deps].stdlib` list is longer than the resolver strictly needs today. That is deliberate (see the runtime-failure point above).

## Alternatives considered

- **Keep per-dependency git pins.** Rejected: both failures in Context are structural, not one-off. The override is invisible to `deps --verify`, and the sidecar loss breaks every bundle consumer.
- **Pin some layers by git and take the rest from the fold.** Rejected for the same reasons, applied per module. A partial pin is still an override for every downstream consumer.
