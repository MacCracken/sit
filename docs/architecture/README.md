# Architecture notes

Non-obvious constraints, quirks, and invariants that a reader cannot derive from the code alone. Numbered chronologically — never renumber.

Not decisions (those live in [`../adr/`](../adr/)) and not guides (those live in [`../guides/`](../guides/)). An item here describes *how the world is*, not *what we chose* or *how to do something*.

## Items

- [001 — `args.cyr` relies on post-return stack memory](001-args-stack-buffer-lifetime.md) — Cyrius stdlib quirk; affects any `argv(n)` usage in `src/main.cyr`.
- [002 — Loose-file object store until patra grows a `COL_BYTES` type](002-loose-objects-until-patra-bytes.md) — why sit objects live on disk today rather than in patra, and when that flips.
- [003 — `sit commit` currently requires flat paths](003-flat-paths-in-commits.md) — **resolved in v0.1.6**; kept for history.
