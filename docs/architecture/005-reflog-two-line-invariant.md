# 005 — Reflog: two lines per HEAD move, and the module-order constraint

**Status**: invariant of the 1.1.0 reflog implementation ([ADR 0010](../adr/0010-reflog-and-recovery.md)).
**Affects**: every command that moves a ref (`src/commit.cyr`, `src/index.cyr` reset, `src/merge.cyr`, `src/refs.cyr` checkout/branch, `src/wire.cyr` fetch/clone/pull), plus `src/reflog.cyr`'s placement in `[lib].modules`.

## Invariant 1 — a HEAD-on-branch move writes TWO reflog lines

When HEAD symbolically points at a branch (the normal case), moving that branch tip must append **two** entries:

- one to the branch log, `.sit/logs/refs/heads/<b>`, and
- one to `.sit/logs/HEAD`,

because HEAD *is* that branch. This is git's behaviour, and `HEAD@{N}` / `<branch>@{N}` both depend on it: drop the `logs/HEAD` write and `HEAD@{N}` silently skips moves; drop the branch write and `<branch>@{N}` does. The helper `reflog_head_move(old, new, msg)` (in `src/refs.cyr`) encapsulates this — it always appends to `HEAD`, and *additionally* to the branch log when `read_head_ref_path()` resolves to a `refs/heads/...` ref. A **detached** HEAD (`read_head_ref_path()` → 0) correctly logs only `logs/HEAD`.

Which sites use which path:

| Site | Helper | Logs |
|---|---|---|
| commit / reset --hard / merge FF / merge commit / clone / pull | `reflog_head_move` | `logs/HEAD` **+** branch log |
| checkout (switch) | `reflog_append("HEAD", …)` | `logs/HEAD` only (no tip moved) |
| branch / checkout -b (create) | `reflog_append("refs/heads/<n>", …)` | branch log only (HEAD didn't move) |
| fetch (remote-tracking) | inside `write_remote_tracking` | `logs/refs/remotes/<r>/<b>` only |

**The trap**: the old tip must be captured *before* the ref write (`read_head_ref()` returns the new tip afterward). Every site reads the old value first — when adding a new ref-moving command, capture old → write ref → `reflog_head_move(old, new, msg)`, in that order. Creation entries pass `old == 0`, which `reflog_format_line` renders as 64 zeros.

**Single timestamp per move**: `reflog_head_move` resolves identity + timestamp *once* and passes them into both `_reflog_append_full` calls, so the `logs/HEAD` and branch-log entries for one move carry an identical `(ts, name, email)` (git's single-transaction-timestamp behaviour). Do **not** rewrite it to call `reflog_append` twice — that re-samples `clock_epoch_secs()` and re-resolves identity per call, so a second-boundary crossing between the two writes would stamp the paired entries 1 second apart.

**Identity is sanitized like the message**: `reflog_format_line` runs `name` and `email` through `_reflog_san_into` (control bytes → space), not just the message. An LF in `SIT_AUTHOR_NAME` / a hand-edited config would otherwise forge a second, attacker-shaped reflog line whose new-oid `@{N}` resolution would honour. Keep identity on the sanitized path.

## Invariant 2 — `reflog.cyr` is ordered before `object_db.cyr`

The `dist/sit.cyr` bundle is compiled **single-pass**: a `[lib].modules` entry may only reference symbols defined in an *earlier* entry (the main build via `src/lib.cyr` is two-pass and wouldn't catch a violation — but CI's `Verify dist/sit.cyr is in sync` step builds the bundle). `fsck` (in `object_db.cyr`) treats reflog entry oids as reachability roots, so it calls `_reflog_collect_oids`. That forces the order:

```
util → validate → config → reflog → object_db → index → refs → …
```

Consequences for anyone editing `src/reflog.cyr`:

- It may call **only** util / validate / config (and stdlib). It must **not** call anything in `refs.cyr`, `object_db.cyr`, `commit.cyr`, etc. — they come later in the bundle.
- That is why the HEAD-aware helpers (`reflog_head_move`, `resolve_reflog_spec`) live in `refs.cyr`, not `reflog.cyr`: they read `read_head_ref_path` / `read_head_ref`, which are defined later. `reflog.cyr` stays a pure primitives + I/O-wrapper layer; the ref-graph-aware glue sits in `refs.cyr` (which is free to call back into the earlier `reflog.cyr`).

If you move a reflog primitive that `fsck` needs into a later module, the main build will still pass and the failure only surfaces at `cyrius distlib` / the CI dist-sync step. Keep fsck-reachable reflog helpers in `reflog.cyr`.
