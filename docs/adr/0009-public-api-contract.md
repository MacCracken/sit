# 0009 — Public API contract: `sit_*` / `ann_*` are stable, everything else is internal

**Status**: Accepted
**Date**: 2026-05-13

## Context

v0.8.1 ships `dist/sit.cyr` (the library export) so downstream Cyrius projects can consume sit as a dep:

```toml
[deps.sit]
git = "https://github.com/MacCracken/sit.git"
tag = "0.8.1"
modules = ["dist/sit.cyr"]
```

First consumer is owl, whose `src/vcs.cyr` shells out to `git diff --no-color -U0` today and wants to swap that for a sit library call (`sit_diff_path(repo, path)` walking the returned annotated-ops vec for gutter markers). Future consumers will be agnoshi / cyrius-doom and any other AGNOS project that needs VCS introspection without a `execve` boundary.

A library has surface. Without a written contract, every internal helper looks consumable, and every internal change risks a SemVer-violating break for downstream. Sit is pre-1.0 today (so technically anything goes between minor bumps), but if v1.0.0 ships without this contract on the books, every post-v1 release will have to weigh "is this fn one a consumer might depend on" against "do we want to keep our own freedom to refactor." That weighing belongs in the consumer's lap, not ours — and the only way to put it there is to draw the line explicitly.

The contract also affects sit's own development: the surface decision tells maintainers when a refactor is free (rename a `_`-prefixed internal) and when it's a major version bump (rename a `sit_*` public). Without that signal, every refactor becomes a judgment call.

## Decision

**Public, stable, semver-governed surface is exactly the set of identifiers prefixed `sit_` or `ann_` defined in `src/api.cyr` and `src/diff.cyr` (the `ann_*` accessors).** Anything else in `dist/sit.cyr` is internal — its existence in the bundle is a build artifact of single-file concatenation, not a promise.

v0.8.1's public surface:

| identifier | location | shape |
|---|---|---|
| `sit_repo_open(cwd)` | api.cyr | open a sit repo; returns 1 / 0 |
| `sit_repo_close(repo)` | api.cyr | release handle; no-op in v0.8.1, reserved |
| `sit_diff_path(repo, path)` | api.cyr | HEAD blob vs working tree → annotated-ops vec |
| `ann_kind(op)` | diff.cyr | op kind: 0 keep / 1 del / 2 add |
| `ann_line(op)` | diff.cyr | line struct pointer (ptr + len via `line_ptr` / `line_len` — TBD whether those are stable; see below) |
| `ann_old(op)` | diff.cyr | 1-based line number in old buffer (0 for add) |
| `ann_new(op)` | diff.cyr | 1-based line number in new buffer (0 for del) |

**Naming convention is the contract:**

- `sit_*` — public, namespaced (callable, stable).
- `ann_*` — public, namespaced (callable, stable; accessors on opaque annotated-op records).
- `cmd_*` — internal (entry points for sit's CLI dispatch; not for library consumers, even though they appear in the bundle).
- `_`-prefixed — internal helper; explicitly not stable; consumers depending on these invalidate their warranty.
- everything else (vec_*, map_*, alloc, syscall, …) is **stdlib**, not sit; its stability is governed by cyrius, not by this ADR.

**Semver rules:**

- Renaming, removing, or changing the argument arity of any `sit_*` / `ann_*` function is a **major** version bump.
- Changing the **return-value semantics** of a `sit_*` function (e.g. switching `sit_diff_path` from "annotated-ops vec or 0" to "result struct") is a major bump.
- Adding new `sit_*` / `ann_*` functions, new argument-trailing flag values, or new fields beyond the documented accessors is a **minor** bump.
- Internal refactors that don't touch the public surface are a **patch** bump.
- Bug fixes that don't change documented behavior are a **patch** bump even if they change observable behavior of code that was relying on the bug.

**Pre-1.0 caveat:** Sit is 0.8.x as of this ADR. Pre-1.0 SemVer permits breaking changes on minor bumps. We're committing to the contract **as if** sit were post-1.0 — breaking changes to `sit_*` / `ann_*` between 0.x.0 minor bumps will be called out explicitly in CHANGELOG's **Breaking** section, and consumers can rely on patch bumps being non-breaking. Owl is pinning sit at minor granularity (`tag = "0.8.x"`); we owe them at least that much stability.

## Consequences

- **Positive**: downstream consumers (owl first) get a stable surface to pin and a written rule for when their pin can drift safely. Sit maintainers get a clear signal — refactoring `_`-prefixed identifiers is free, renaming `sit_*` is a major bump. Future ambiguity reduces.
- **Positive**: bundle review at release time has a concrete checklist — diff `dist/sit.cyr` against the prior release, flag any change to a `sit_*` or `ann_*` line as a release-blocker until the version bump is matched.
- **Negative**: the `ann_*` shape is loose — `ann_line(op)` returns a pointer to a line struct whose accessors (`line_ptr`, `line_len`) live in diff.cyr and aren't `ann_`-prefixed. We're committing those to stability via this ADR but the naming convention doesn't surface them. Followup: rename `line_ptr` / `line_len` to `ann_line_ptr` / `ann_line_len` (next sit_* surface change) OR document the binding explicitly. Picking the latter for now; a future cleanup release can do the rename if surface clarity becomes load-bearing.
- **Negative**: adds a checklist gate to every minor / major release (review the public surface for breaks). Worth the cost — the alternative is "we'll know when a consumer files an issue," which is too late.
- **Neutral**: opens the door for sit-specific docs at `docs/api/` (consumer-facing API reference) once the surface grows beyond what fits in api.cyr's docstrings. Not earned at v0.8.1's 3-function surface; revisit when surface > 10 fns.

## Alternatives considered

1. **No formal contract; "best effort" stability.** Path of least resistance for sit maintainers, worst for consumers — they'd have to read every CHANGELOG and inspect every `dist/sit.cyr` diff to know whether their integration still works. Rejected because owl is already pinning sit and the lack of contract would mean every sit release is a manual review pass on owl's side.

2. **Lock the entire `dist/sit.cyr` surface as public.** Internally tempting — no judgment calls about what's "internal" — but practically untenable. Sit has ~80 functions across the bundle today; locking all of them means every refactor that renames a private helper is a major bump. The refactor pass scheduled for the v0.8.x closeout would consume an entire release line in major bumps. Rejected — the cost-of-stability gradient is wrong.

3. **Module-level public/private via a `pub fn` keyword.** Cyrius doesn't have one (single-pass compilation; everything in the bundle is callable from everywhere). Even if it did, the naming-convention approach is more durable across language evolution. Rejected for the same reason `_`-prefix is the convention in Rust's bundle / Python's `__all__` shape: it's a contract the language doesn't have to enforce, the maintainer signals intent, and the reviewer enforces.

4. **Public-API stub file (`dist/sit-public.cyr`) separate from the implementation bundle.** Forces maintainers to mirror every public signature, with both files re-reviewable at release. Plausible but doubles the maintenance surface for a 3-function release. Revisit at v1.0 if the public surface grows past ~20 functions.

## Operational notes

- The public surface is verified at release time by running `git diff dist/sit.cyr` against the prior tag and checking every change to a `sit_*` / `ann_*` line against the SemVer rules above.
- Bundle review steps:
  1. `cyrius distlib` regenerates `dist/sit.cyr` from `[lib].modules`.
  2. `git diff dist/sit.cyr` against the prior tag.
  3. Filter the diff for lines matching `^[+-]fn (sit_|ann_)` — these are public surface changes.
  4. Cross-reference against CHANGELOG. Each public-surface line should map to an Added / Changed / Removed entry with the SemVer impact called out.
- `_`-prefixed helpers can move freely between modules (e.g. extract `_compute_hunks` into a new file) as long as the bundle still compiles for consumers.
- New public functions land in `src/api.cyr` (the conventional location) unless they're already-published accessors (the `ann_*` family lives in `src/diff.cyr` for proximity to its data shape).

## Future surface candidates

Not committing to these in v0.8.1, but flagging for v0.8.2+:

- `sit_log(repo, ref_name, limit) → commit_vec` — programmatic log walk.
- `sit_status(repo) → entry_vec` — staged / modified / untracked classification.
- `sit_object_read(repo, hex) → bytes` — raw object access for tooling.
- `sit_remote_ping(url) → caps` — query a remote's capabilities without a full clone.

Each of those adds its own surface and goes through this ADR's review gate at the release that lands it.
