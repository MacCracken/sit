# 0010 — Reflog and recovery

**Status**: Accepted
**Date**: 2026-06-25

## Context

Through 1.0.x, sit had no record of where a ref *used* to point. A `sit reset --hard`, a fast-forward, or a clobbering `checkout` moved a branch tip with no way back: the old commit became unreachable immediately, and `fsck --prune` deleted it on sight (documented as `--prune=now` semantics — see the v0.8.14 note). There was no "undo my last reset," and every history-rewrite tool we want to ship later (revert, cherry-pick, rebase) is unsafe to offer without a recovery net underneath it.

git solves this with the **reflog**: an append-only journal, one line per ref movement, under `.git/logs/`. It doubles as the mechanism that makes `gc` safe — reflog entries are extra reachability roots, so recently-discarded commits survive until their reflog entry expires. We want the same capability, sit-native but git-compatible where that costs nothing (consistent with [ADR 0004](0004-sha256-only.md) and the on-disk-compat principle in CLAUDE.md).

The decisions in play: where to store the log (a new patra table vs flat files), what the line format is, how `@{N}` is selected and parsed, and how the prune path consumes the log to gain a grace period.

## Decision

Ship a **file-based, git-compatible reflog** under `.sit/logs/`, plus `@{N}` resolution, a `sit reflog` command, and a reflog-aware `fsck --prune` grace period.

- **Storage**: plain-text files mirroring the ref tree — `.sit/logs/HEAD`, `.sit/logs/refs/heads/<b>`, `.sit/logs/refs/remotes/<r>/<b>`. Not a patra table. Created lazily on first write (`ensure_parent_dirs`), appended under an exclusive lock (`file_append_locked`).
- **Line format** (byte-compatible with git's SHA-256-mode reflog):
  `<old64> SP <new64> SP <name> " <" <email> "> " <unixts> " +0000" TAB <message> LF`.
  Creation uses 64 ASCII `0` for `<old64>`. Identity, timestamp, and `+0000` are resolved by the same chain as `build_commit_signed`, so a reflog line's author matches the commits it records. The message's control bytes are sanitized to spaces so an entry can never forge a second line.
- **Ordering / selection**: append-only, newest **last**. `<ref>@{0}` is the last line (current value); `<ref>@{N}` is the new-oid recorded `N` moves ago = line `count-1-N`. Only the **integer ordinal** form ships in 1.1.0 — the `@{<date>}` time form is rejected.
- **What is logged**: every local ref movement (commit, reset `--hard`, merge FF + merge commit, checkout switch, branch / `-b` create) and remote-tracking updates (fetch / clone / pull, client-side). A HEAD-on-branch move writes **two** lines — the branch log and `logs/HEAD`. **Tags are not logged** (git parity).
- **`fsck --prune` grace** (replaces unconditional `--prune=now`):
  1. **Reflog reachability** — every `.sit/logs/**` entry's old+new oid is a reachability root, so a reset-discarded tip is protected while its reflog entry exists.
  2. **Age window** — a still-dangling object is kept unless older than the window (default **90 days**, git's `gc.reflogExpire`). Commits are dated by author timestamp; trees/blobs are undatable and kept under any positive window. `--prune-now` sets the window to 0 (the legacy immediate behaviour).

Out of scope for 1.1.0: `reflog expire`/`delete` (so reflog entries are currently unbounded — objects stay protected indefinitely until an entry is manually removed), the `@{<date>}` selector, and a programmatic `sit_reflog_*` library export (reflog is command-only — see [ADR 0009](0009-public-api-contract.md)).

## Consequences

- **Positive** — "undo my reset" works (`sit reset --hard HEAD@{1}`); `fsck --prune` no longer destroys recoverable history; the recovery net unblocks the safe-rewrite tools on the roadmap (revert/cherry-pick/stash, later rebase). The git-compatible format means a `.git/`-mode reader (1.2.0) and external git tooling can read sit's logs.
- **Negative** — every ref-moving command now has a second write path to keep correct; the "two lines per HEAD move" invariant is easy to violate in a new command (documented in [architecture 005](../architecture/005-reflog-two-line-invariant.md)). Reflog writes are best-effort (logged *after* the ref moves) — a failed append loses a log entry but never corrupts the ref. Without entry expiry, `--prune` reclaims little until logs are manually cleared; this is acceptable for 1.1.0 and motivates a future `reflog expire`.
- **Neutral** — `src/reflog.cyr` joins `[lib].modules` and is ordered **before** `object_db.cyr` (so `fsck` can treat reflog oids as roots), which constrains it to depend only on util/validate/config. The 90-day window is a constant, not yet config-driven (`gc.reflogExpire` parsing is deferred).

## Alternatives considered

- **patra table for the log** — queryable and indexable, but a new schema/DDL, no git-format interop, and overkill for an append-only journal whose only random access is "Nth from the end." Flat files are simpler and free interop. Rejected for 1.1.0; revisit only if a consumer needs to query reflog history.
- **Centralize logging inside `write_head_ref`** — would catch every HEAD move in one place, but `write_head_ref` knows neither the old value nor the action verb, so it would mean plumbing a message parameter through every caller. Appending at each call site is lower-coupling — each site already read the old tip and knows its verb. Accepted the missed-site risk and pinned it with the architecture note + e2e smoke instead.
- **Keep `--prune=now` and add a separate grace flag** — rejected: the safe behaviour should be the default. `--prune` now means "grace," and the old immediate behaviour is the explicit `--prune-now`.
- **Add a `created_at` column to the objects table for prune dating** — a cleaner age source for trees/blobs, but a breaking schema migration for a secondary mechanism (reflog-reachability already protects the recoverable set). Deferred; commit author-ts + conservative keep-undatable is enough for 1.1.0.
