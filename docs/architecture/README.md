# Architecture notes

Non-obvious constraints, quirks, and invariants that a reader cannot derive from the code alone. Numbered chronologically — never renumber.

Not decisions (those live in [`../adr/`](../adr/)) and not guides (those live in [`../guides/`](../guides/)). An item here describes *how the world is*, not *what we chose* or *how to do something*.

## Items

- [001 — `args.cyr` relies on post-return stack memory](001-args-stack-buffer-lifetime.md) — Cyrius stdlib quirk; affects any `argv(n)` usage in `src/main.cyr`.
- [002 — Loose-file object store until patra grows a `COL_BYTES` type](002-loose-objects-until-patra-bytes.md) — why sit objects live on disk today rather than in patra, and when that flips.
- [003 — `sit commit` currently requires flat paths](003-flat-paths-in-commits.md) — **resolved in v0.1.6**; kept for history.
- [004 — Cyrius string literals are program-lifetime](004-cyrius-string-literal-lifetime.md) — why stashing a raw `"..."` pointer into a struct slot (e.g. tree mode codes) is safe, and the 256 KB string-data ceiling that bounds it.
- [005 — Reflog: two lines per HEAD move, and the module-order constraint](005-reflog-two-line-invariant.md) — a HEAD-on-branch move logs both `logs/HEAD` and the branch log; `reflog.cyr` must sit before `object_db.cyr` in the single-pass bundle.
- [006 — Bundle closure: nothing reachable in `[lib]` may call outside it](006-bundle-closure.md) — an address-taken fn (`&serve_handle_request`) is a root in every consumer, and cyrius ≥ 6.6.9 refuses a reachable undefined call; why `_wire_io_send` / `_wire_io_recv` live in `wire_http.cyr`.
