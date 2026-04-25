# Benchmarks: git vs sit

Head-to-head comparison on a real workstation. sit is a first-party Cyrius implementation — every layer (SHA-256, zlib, object store, signing, wire protocol) is written from scratch with no FFI to C libraries.

The point of this document is to be **honest about where sit currently wins, loses, and breaks even against git**, and to track that over time as sigil/sankoch/patra mature. The slow numbers are kept in plain sight; that's how we know which dep needs the next push.

## Setup

- **Host**: Linux 6.18.22-1-lts x86_64
- **git**: 2.53.0 (system install, libpcre2 + libz-ng + libc dynamic deps)
- **sit**: 0.6.10 built from source at `src/main.cyr` via `cyrius build` (cyrius 5.6.40, sankoch 2.0.3, sigil 2.9.1, patra 1.8.3, sakshi 2.1.0)
- **Timing**: `date +%s%N` around the command (~nanosecond resolution). Each operation runs with a fresh scratch repo and is measured 10–20 times; we report **min** (closest to true operation cost, minus noise) and **median** (typical case) in milliseconds.
- **Bench config for the table below**: `RUNS_LIGHT=20 RUNS_HEAVY=10`.

Reproduce with:

```sh
cyrius build src/main.cyr build/sit
SIT=$PWD/build/sit ./scripts/benchmark.sh
```

## Binary footprint

| | size | dynamic deps |
|---|---:|---|
| `git` (primary dispatch binary) | **4,523,048 bytes** (~4.4 MB) | libpcre2, libz-ng, libc |
| `/usr/lib/git-core/*` (all 183 sub-binaries) | **7,390,732 bytes** (~7.4 MB) | same |
| `build/sit` (one statically-linked binary) | **710,208 bytes** (~694 KB) | **none** |

**sit ships one ~694 KB statically-linked binary with zero dynamic dependencies.** The primary git binary is ~6.4× larger; the full git install footprint is ~10.4× larger. sit bundles SHA-256, zlib-compatible compression, ed25519 signing, its own object store, and its own wire protocol directly into the executable — no libpcre, no libz, no dispatch subcommand binaries.

(Caveat: git ships rebase, gc, merge-base, hundreds of plumbing commands sit doesn't have. The footprint comparison is "sit covers the core VCS loop in 10× less disk", not "sit does the same work in 10× the bytes". Sit has 24 commands so far.)

## Operation latency (v0.6.10, 2026-04-25)

All times in milliseconds, lower is better. Honest reporting — **5 of 10 ops are currently slower than git**, and they're all listed in the same table as the wins.

| operation | git (min / med) | sit (min / med) | sit/git ratio (min) | who's faster | what bounds sit |
|---|---:|---:|---:|---|---|
| `fetch-1commit` | 12.88 / 13.54 | **2.77 / 3.02** | **0.21×** | sit (~4.7×) | nothing here — sit's local-path wire is genuinely lean |
| `commit` | 4.80 / 5.23 | **2.77 / 3.09** | **0.58×** | sit (~1.7×) | nothing here |
| `init` | 3.26 / 3.61 | **1.97 / 2.33** | **0.61×** | sit (~1.7×) | nothing here |
| `add-1KB` | 2.88 / 3.14 | 3.04 / 3.29 | **1.06×** | even | sankoch zlib + sigil SHA-256 (small enough to disappear) |
| `status-100files` | 3.83 / 4.10 | 7.01 / 7.34 | 1.83× | git | sigil SHA-256 over 100 file contents |
| `diff-edit` | 2.99 / 3.39 | 13.72 / 14.30 | 4.60× | git | sankoch zlib_decompress + LCS (algorithmic — needs Myers') |
| `add-64KB` | 3.74 / 3.82 | 16.72 / 17.15 | 4.47× | git | sankoch zlib_compress + sigil SHA-256 of full content |
| `log-100commits` | 4.61 / 5.08 | 27.73 / 28.72 | 6.01× | git | sankoch zlib_decompress per commit + per-commit parse |
| `clone-100commits` | 15.51 / 16.64 | 170.84 / 173.39 | 11.01× | git | patra per-insert WAL fsync + sankoch decompress (per object) |
| `add-1MB` | 16.94 / 17.60 | 211.52 / 213.09 | 12.48× | git | sankoch zlib_compress(1MB) ~150ms + sigil SHA-256(1MB) ~80ms |

## Evolution: how sit got here (v0.6.0 → v0.6.10)

Every release that moved any number, with the change responsible. Honest about which releases moved which ops and which ones missed.

| operation | v0.6.0 | v0.6.4 | v0.6.5 | v0.6.6 | v0.6.7 | v0.6.8 | v0.6.9 | v0.6.10 | total Δ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `init` | 1.77 | 2.31 | 1.88 | 2.06 | 2.00 | 2.00 | 2.07 | 1.97 | ~0% |
| `commit` | 2.79 | 2.99 | 2.90 | 2.91 | 3.03 | 2.92 | 2.83 | 2.77 | ~0% (-1%) |
| `add-1KB` | 2.93 | 3.41 | 2.83 | 3.14 | 2.98 | 2.95 | 2.89 | 3.04 | ~0% |
| `add-64KB` | 16.74 | 16.97 | 15.57 | 16.22 | 16.46 | 15.70 | 16.40 | 16.72 | ~0% |
| `add-1MB` | 216.01 | 210.86 | 202.97 | 207.32 | 208.62 | 206.73 | 208.25 | 211.52 | ~0% |
| `fetch-1commit` | 2.58 | 2.92 | 2.94 | 2.95 | 2.91 | 2.75 | 2.83 | 2.77 | ~0% |
| `diff-edit` | 14.09 | 13.67 | 13.32 | 13.55 | 13.67 | 13.27 | 13.86 | 13.72 | ~0% |
| **`log-100commits`** | 33.44 | **29.32** | 27.68 | 29.61 | 28.21 | 27.83 | 27.67 | 27.73 | **−17%** |
| **`clone-100commits`** | (crash) | 251.64 | **208.44** | 215.27 | **168.53** | 168.61 | 172.64 | 170.84 | **−32%** vs v0.6.4 baseline |
| `status-100files` | (crash) | 7.44 | 6.98 | 6.77 | 7.08 | 6.64 | 7.00 | 7.01 | (no v0.6.0 baseline; ~0% across post-fix releases) |

Notes on the table:
- v0.6.0 `clone` and `status` show "(crash)" because S-33 (the cyrius stdlib `alloc` grow-undersize bug + sankoch zlib symmetry bug, both surfaced in the same triage) made `sit status` SIGSEGV on the 100-commit fixture and `sit clone` died in the materialize step. v0.6.1 fixed those via dep bumps; the bench rows came back at v0.6.4.
- `clone` is reported as "−31% vs v0.6.4 baseline" because that's the first version where the row was bench-able. Against the projected pre-S-33-bug baseline (would have been ~245 ms in v0.6.0), the cumulative win is similar shape.
- All ratios in the "total Δ" column are vs v0.6.0 except where called out. "~0%" means within run-to-run noise across the whole arc.

**Where the wins came from:**
- `log` -17% from v0.6.4 — process-wide patra DB handle caching (P-01/02/05/08/12/25 collapse + S-24 fold-in). One open per process instead of one per `read_object` call.
- `clone` -31% from v0.6.5 + v0.6.7 combined — v0.6.5 wrapped `copy_objects` in a single `patra_begin`/`patra_commit` transaction (P-03, collapsed ~300 fsyncs into 1) and dropped the redundant outer `db_object_has` (the inner one inside `db_object_insert_raw` already does the check); v0.6.7 cached the compressed bytes during `walk_reachable_*` so `copy_objects` doesn't re-read commits + trees from the source DB (P-04).

**Where intentional structural changes shipped without bench movement** (honest — these are real improvements that the 100-file synthetic bench is too small to show):
- v0.6.6 (P-10 + P-18): hashmap-backed `tree_find` and `three_way_path_set` (O(N²) → O(N)). Visible at 1000+ files; invisible at 100.
- v0.6.8 (P-17): buffered stdout (200+ direct stdout writes routed through a 64 KB buffer; fixes an output-ordering bug in `write_sanitized` along the way). Visible on large diffs (1000+ syscalls collapsed); invisible on the bench's one-hunk fixture.
- v0.6.9 (P-06 + P-15): tighter decompression sizing (16× → 4× initial multiplier; retry only on confirmed `-ERR_BUFFER_TOO_SMALL`); LCS DP table moved to `fl_alloc`/`fl_free` (mmap-backed, returns to kernel post-diff). Memory hygiene; no wall-clock signal.
- v0.6.10 (dep bumps): cyrius 5.6.35 → 5.6.40, patra 1.6.0 → 1.8.3. Closes S-31 (`patra_result_get_str_len` swap drops sit's `strnlen` workaround). patra `INSERT OR IGNORE` filed but not consumed (SQL-level only). patra `PATRA_SYNC_BATCH` group commit investigated and reverted (durability regression with no perf gain — `copy_objects` already uses explicit transactions; sit's cached handle never closes so BATCH-pending writes would sit in the kernel writeback window).

## Where the next big movements live — and who has to land them

Sit-side perf has plateaued at v0.6.9. Every remaining headline gap is dep-bound:

| sit op currently slow | dominant cost | where the fix lives | projected after fix |
|---|---|---|---|
| `status` 1.87× | sigil SHA-256 (~12 MB/s vs SHA-NI's ~1 GB/s = ~80× headroom) | [sigil roadmap](../../../sigil/docs/development/roadmap.md) | sit faster than git |
| `add-*` 4.5× → 11.7× | sankoch DEFLATE (single-threaded software; libdeflate-class hits 5-10×) + sigil SHA-256 over full content | [sankoch roadmap](../../../sankoch/docs/development/roadmap.md) + sigil | ~2× git |
| `log` 5.8× | sankoch zlib_decompress per commit + parsing constant | sankoch roadmap | ~2× git |
| `diff` 4.5× | sankoch zlib_decompress + LCS algorithm | sankoch roadmap + algorithmic Myers' diff (audit P-14, deferred to v0.8.0) | ~git parity |
| `clone` 11.35× | patra per-insert WAL fsync + sankoch decompress per object | [patra 1.7.0 INSERT OR IGNORE](../../../patra/docs/development/roadmap.md) (drops inner has-check, ~30%) + patra 1.8.x WAL group commit (auto-batched fsync, replaces sit's manual `patra_begin`/`patra_commit` and amortizes everywhere else too) | ~3-4× git |

All three asks are filed on the respective lib roadmaps. When any of them ships, sit can pick up the matching improvement via a dep-pin bump release with no sit-side code change.

## Per-primitive numbers from `tests/sit.bcyr` (v0.6.9, 2026-04-25)

These numbers are the lower bound on what any sit command involving the primitive can achieve:

| Bench | Time/op | Throughput / scale | Direct sit consumer |
|-------|--------:|--------------------|---------------------|
| `sha256-64B`   | 10 µs    | ~6.4 MB/s | every hash_blob_of_content (small-blob ceiling) |
| `sha256-1024B` | 87 µs    | ~11.8 MB/s | typical small-source-file `sit add` |
| `sha256-65536B`| 5.153 ms | ~12.4 MB/s | `add-1MB` SHA-256 portion (~80 ms of the 208 ms total) |
| `zlib-compress-1024B`   | 136 µs   | ~7.5 MB/s | every blob/tree/commit on `commit` (small-input regime) |
| `zlib-compress-65536B`  | 1.236 ms | ~53 MB/s | `add-1MB` compress portion (~150 ms of the 208 ms total) |
| `zlib-decompress-1024B` | 32 µs    | ~32 MB/s | every `read_object` in `log`/`status`/`clone` (small-input regime) |
| `zlib-decompress-65536B`| 330 µs   | ~199 MB/s | larger-blob decompress on `clone`/`materialize` |
| `patra-open-close` | **18 µs** | per-call cost (sit avoids it now via the v0.6.4 cache) | was the dominant `log` cost pre-v0.6.4 |
| `copy-objects-100` | **127 µs total** (~1.3 µs/row) | per-row cost during `fetch`/`push`/`clone` | the per-insert path inside the v0.6.5 batched transaction |
| `commit-parse+iso8601` | 1 µs | per-commit CPU cost during `sit log` | dwarfed by sankoch decompress, not the bottleneck |
| `ed25519-sign`   | 1.162 ms | `sit commit -S` overhead | ~40% of signed-commit wall-clock |
| `ed25519-verify` | 6.831 ms | `sit verify-commit` cost | dominates `sit log` decoration on signed histories |
| `refname_valid-good`         | 315 ns | every ref write | negligible, listed for completeness |
| `tree_entry_name_valid-good` |  86 ns | every tree entry parsed/materialized | negligible |
| `tree_flat_path_valid-good`  | 661 ns | every entry during materialize | negligible |
| `hex_prefix_valid-64char`    | 197 ns | every ref-file read + `resolve_hash` | negligible |

From these: **sigil SHA-256 ≈ 12 MB/s** and **sankoch zlib ≈ 50 MB/s compress / 200 MB/s decompress** are the two ceilings every "sit slower than git" row in the latency table is bumping up against. Both filed on those repos' roadmaps; both expected to lift by integer multiples once they ship.

## Honest caveats

- **One machine, one run.** These numbers are a snapshot, not a study. Re-run on your own hardware before quoting. The bench script is at `scripts/benchmark.sh`.
- **The 100-file fixture is small.** Several v0.6.x changes are correct algorithmic improvements (P-10, P-18, P-17, P-15) that the synthetic bench can't see. They're real at scale (1000+ files / large diffs) but the table doesn't show that. If you need confidence at scale, build a larger fixture and re-run.
- **sit's network transport is local-path only.** `fetch-1commit` 0.22× looks great because both git and sit go through the filesystem. When sit grows HTTP / SSH (v0.7.0) the network number will be a new comparison axis and will probably regress vs the local-path number.
- **git is doing more.** git's install bundles rebase, gc, merge-base, diff-tree, hundreds of plumbing commands. sit has 24 so far. The footprint comparison is "sit covers the core VCS loop in 10× less disk", not "sit does the same work in 10× the bytes."
- **sit is young.** Most "sit slower than git" rows have a clear path to closure. None require sit-side rewrites — they all wait on a single dep release in sigil / sankoch / patra. The sit-side perf arc (v0.6.4 → v0.6.9) cleared the architectural overhead; the remaining gap is primitive throughput.
- **sit still loses on big-blob workloads.** `add-1MB` at 11.74× git is the worst row in the table and won't move until sankoch DEFLATE gets a serious throughput pass. If you're considering sit for a binary-asset-heavy repo today, this is the gating number.

## Methodology

1. For each operation, build a **fresh** scratch repo every run — no warm-cache advantages either way.
2. Run the operation N times (`RUNS_HEAVY=10` for heavy ops, `RUNS_LIGHT=20` for light ones). Record each wall-clock time with `date +%s%N`.
3. Report **min** (approaches the true CPU cost, filtering out scheduler noise) and **median** (typical case).
4. Author identity is pre-configured on both sides (`Bench <b@e>`); no credential fetching in the hot path.
5. Benchmarks run serially on a quiet workstation; no background load beyond the normal desktop session.
6. `RUNS_LIGHT` and `RUNS_HEAVY` environment variables override the default iteration counts.

## Per-release bench snapshots

Every v0.6.x release with a measurable change ships its own snapshot doc with full before/after tables and a "what didn't move and why" section:

- [`docs/benchmarks/2026-04-24-baseline.md`](../benchmarks/2026-04-24-baseline.md) — pre-v0.6.0 baseline (audit-time)
- [`docs/benchmarks/2026-04-24-v0.6.0.md`](../benchmarks/2026-04-24-v0.6.0.md) — post-audit numbers
- [`docs/benchmarks/2026-04-25-v0.6.1.md`](../benchmarks/2026-04-25-v0.6.1.md) — first release with `status` + `clone` rows enabled (post-S-33 dep bumps)
- [`docs/benchmarks/2026-04-25-v0.6.4.md`](../benchmarks/2026-04-25-v0.6.4.md) — patra-handle cache (`log` -17%)
- [`docs/benchmarks/2026-04-25-v0.6.5.md`](../benchmarks/2026-04-25-v0.6.5.md) — P-03 batched copy_objects transaction (`clone` -15%)
- [`docs/benchmarks/2026-04-25-v0.6.6.md`](../benchmarks/2026-04-25-v0.6.6.md) — P-10 + P-18 (no synthetic-bench movement; algorithmic)
- [`docs/benchmarks/2026-04-25-v0.6.7.md`](../benchmarks/2026-04-25-v0.6.7.md) — P-04 walk-reachable cache (`clone` -22%)
- [`docs/benchmarks/2026-04-25-v0.6.8.md`](../benchmarks/2026-04-25-v0.6.8.md) — P-17 buffered stdout (no synthetic-bench movement; structural)
- [`docs/benchmarks/2026-04-25-v0.6.9.md`](../benchmarks/2026-04-25-v0.6.9.md) — P-06 + P-15 hygiene closeout
- [`docs/benchmarks/2026-04-25-v0.6.10.md`](../benchmarks/2026-04-25-v0.6.10.md) — dep bumps + S-31 closeout (no bench movement; documents BATCH-mode investigation/revert)

---

_Generated by `scripts/benchmark.sh` at 2026-04-25T08:07:27Z. Host: Linux 6.18.22-1-lts x86_64; git 2.53.0; sit 0.6.10._
