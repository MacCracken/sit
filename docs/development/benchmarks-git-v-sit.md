# Benchmarks: git vs sit

Head-to-head comparison on a real workstation. sit is a first-party Cyrius implementation — every layer (SHA-256, zlib, object store, signing, wire protocol) is written from scratch with no FFI to C libraries.

The point of this document is to be **honest about where sit currently wins, loses, and breaks even against git**, and to track that over time as sigil/sankoch/patra mature. The slow numbers are kept in plain sight; that's how we know which dep needs the next push.

> **Snapshot note**: refreshed at **v1.4.3 (2026-08-18)**; the v0.6.12 tables are kept below as the historical arc. This head-to-head is not re-run every release. For current version, command inventory, dep versions, and binary metrics see [`state.md`](state.md); per-release micro-benchmark snapshots are under [`../benchmarks/`](../benchmarks/).
>
> ⚠ **Read the ratios, not the absolute deltas, when comparing across snapshots.** The v0.6.12 run and this one are ~4 months apart on a different kernel (6.18 → 7.1) and a different git (2.53.0 → 2.55.0), so absolute millisecond changes are *not* a controlled measurement. The **ratio** column is — git and sit are timed back-to-back on the same box in the same run.

## Setup

- **Host**: Linux 7.1.8-arch1-3 x86_64, 16 cores *(v0.6.12 run: Linux 6.18.22-1-lts)*
- **git**: 2.55.0 (system install, libpcre2 + libz-ng + libc dynamic deps) *(v0.6.12 run: 2.53.0)*
- **sit**: 1.4.3 built from source at `src/main.cyr` via `cyrius build` — cyrius 6.5.28, and since v1.3.6 the toolchain pin is the single lever for every dependency: sankoch 2.7.8, sigil 3.12.9, patra 1.13.8, sakshi 2.4.10 (all stdlib-folded, no git deps)
- **Timing**: `date +%s%N` around the command (~nanosecond resolution). Each operation runs with a fresh scratch repo and is measured 10–20 times; we report **min** (closest to true operation cost, minus noise) and **median** (typical case) in milliseconds.
- **Bench config for the table below**: `RUNS_LIGHT=20 RUNS_HEAVY=10`.

Reproduce with:

```sh
cyrius build src/main.cyr build/sit
SIT=$PWD/build/sit RUNS_LIGHT=20 RUNS_HEAVY=10 ./scripts/benchmark.sh
```

## Binary footprint

| | size | dynamic deps |
|---|---:|---|
| `git` (primary dispatch binary) | **4,899,632 bytes** (~4.67 MB) | libpcre2, libz-ng, libc |
| `/usr/lib/git-core/*` (all 186 sub-binaries) | **8,104,785 bytes** (~7.73 MB) | same |
| `build/sit` (one statically-linked binary, DCE) | **2,990,568 bytes** (~2.85 MB) | **none** |

sit grew from 694 KB at v0.6.12 to 2.85 MB at v1.4.0 — the whole first-party stack
(TLS 1.3, zstd/xz/bzip2, the git packfile reader, ed25519) landed in between. It is
still a single static binary against git's dispatch binary **plus** 186 sub-binaries
and three shared libraries.

**sit ships one ~694 KB statically-linked binary with zero dynamic dependencies.** The primary git binary is ~6.4× larger; the full git install footprint is ~10.4× larger. sit bundles SHA-256, zlib-compatible compression, ed25519 signing, its own object store, and its own wire protocol directly into the executable — no libpcre, no libz, no dispatch subcommand binaries.

(Caveat: git ships rebase, gc, merge-base, hundreds of plumbing commands sit doesn't have. The footprint comparison is "sit covers the core VCS loop in 10× less disk", not "sit does the same work in 10× the bytes". Sit has 24 commands so far.)

## Large-tier fixture (v1.4.4) — what the default hides

Every table on this page below this section uses a **100-commit / 100-file**
repository. `scripts/benchmark.sh` now takes `FIXTURE_COMMITS` (default 100):

```sh
FIXTURE_COMMITS=1000 ./scripts/benchmark.sh
FIXTURE_COMMITS=5000 ./scripts/benchmark.sh
```

At 10× the repository, two rows change character completely:

| operation | ratio @100 | ratio @1000 | sit growth | git growth |
|---|---:|---:|---:|---:|
| `log` | 2.54× | 6.59× | 8.0× | 3.1× |
| `status` (v1.4.4) | **1.78×** | **26.64×** | **24×** | 1.6× |
| `status` (v1.4.5) | 1.59× | **21.35×** | 21× | 1.6× |
| `clone` | **5.17×** | **60.80×** | **34×** | 2.9× |

v1.4.5 hashmap-backed `index_find` (an O(N) scan called from O(N) loops), worth
**−20%** at N=1000. ⚠ `status` is **still superlinear** — 10× the files costs ~19×
the time — so that was not the dominant term at this size. Second cause
unidentified; tracked as 1.4.6, to be profiled rather than guessed.

⚠ **Read the default tier accordingly.** `status` at 1.78× and `clone` at 5.17×
are *not* the whole story — both are superlinear and the small fixture cannot see
it. This is the same blind spot that let `objects.hash` ship unindexed from 1.0
through 1.4.0 with every benchmark green.

`status`'s cause is identified: `index_find` (`src/index.cyr:515`) is a linear
scan called once per working file and once per HEAD tree entry — O(N²). The same
defect was fixed for `tree_find` in v0.6.6; this one was missed. `clone`'s growth
is tracked but **not yet diagnosed** — profile before assuming.

---

## Operation latency (v1.4.3, 2026-08-18)

Measured on cyrius **6.5.28** (patra 1.13.8). **5 of 10 ops are slower than git,
4 faster, 1 even.**

| operation | git (min / med) | sit (min / med) | ratio | vs v1.4.0 |
|---|---:|---:|---:|---:|
| `fetch-1commit` | 11.04 / 11.40 | **2.75 / 2.94** | **0.25×** | 0.25× |
| `commit` | 4.15 / 4.46 | **2.41 / 2.72** | **0.58×** | 0.58× |
| `init` | 2.75 / 2.99 | **1.70 / 1.89** | **0.62×** | 0.65× ✅ |
| `add-1KB` | 2.26 / 2.51 | 2.44 / 2.66 | 1.08× | 1.02× |
| `status-100files` | 3.19 / 3.34 | 5.62 / 5.88 | 1.76× | 1.88× ✅ |
| `log-100commits` | 4.12 / 4.36 | **8.98 / 9.33** | **2.18×** | 6.48× ✅✅ |
| `add-64KB` | 3.18 / 3.43 | 8.58 / 8.85 | 2.70× | 2.59× |
| `diff-edit` | 2.65 / 2.81 | 12.14 / 12.64 | 4.57× | 4.47× |
| `clone-100commits` | 13.93 / 14.36 | **69.39 / 70.03** | **4.98×** | 12.13× ✅✅ |
| `add-1MB` | 16.12 / 16.66 | 100.70 / 101.89 | **6.25×** | 6.17× |

### The read path stopped being quadratic

`log` **−64%** and `clone` **−43%** in absolute terms, both from a single upstream
fix: patra was allocating *and zeroing* a result buffer sized for the **whole
table** on every query, including a one-row indexed hit. sit filed and profiled
it; the fix landed in patra 1.13.1 and folded into cyrius 6.5.28.

Same fixture, same command, only the store growing:

| objects in store | v1.4.1 | v1.4.3 |
|---|---:|---:|
| ~300 | 13 ms | **5 ms** |
| ~1200 | 35 ms | **5 ms** |
| ~3100 (30 MB store) | ~125 ms | **5 ms** |

**Flat across a 10× store growth.** Object reads no longer care how big the
repository is — which is what the index was supposed to buy all along, and what
the missing index (fixed in 1.4.1) plus the oversized buffer (fixed upstream) had
been hiding between them.

### What bounds sit now

**`add-1MB` (6.25×) is the worst row** — `clone` held that spot from v0.6.12
through v1.4.2 and no longer does.

| slow op | dominant cost | where the fix lives |
|---|---|---|
| `add-1MB` 6.25× / `add-64KB` 2.70× | sankoch `zlib_compress` (~140 ms at 1 MB) | sankoch match-finder / SIMD (on sankoch's roadmap) |
| `clone` 4.98× | per-object round trip + compress on ingest | pack bundles + delta transfer (sit roadmap, § Structural) |
| `diff-edit` 4.57× | sankoch decompress + LCS | Myers fallback shipped v1.0.1; the DP path still dominates at this size |
| `log` 2.18× | sankoch decompress per commit | sankoch small-input decompress throughput |
| `status` 1.76× | 100× file open+read | not really a bottleneck; needs a larger fixture to say anything |

**Every remaining gap is now a dependency's throughput or a sit feature that does
not exist yet.** The two "sit hasn't wired the available call" items that topped
this table at v1.4.0 both shipped in 1.4.1.

---

## Operation latency (v1.4.0, 2026-08-18) — historical

All times in milliseconds, lower is better. **6 of 10 ops are slower than git, 4 are faster.**
`RUNS_LIGHT=20 RUNS_HEAVY=10`, fresh scratch repo per run.

| operation | git (min / med) | sit (min / med) | ratio (min) | vs v0.6.12 ratio | who's faster |
|---|---:|---:|---:|---:|---|
| `fetch-1commit` | 11.26 / 11.43 | **2.79 / 2.92** | **0.25×** | 0.22× | sit (~4×) |
| `commit` | 4.19 / 4.51 | **2.43 / 2.67** | **0.58×** | 0.63× ✅ | sit (~1.7×) |
| `init` | 2.76 / 3.00 | **1.80 / 1.91** | **0.65×** | 0.67× ✅ | sit (~1.5×) |
| `add-1KB` | 2.40 / 2.57 | 2.44 / 2.60 | **1.02×** | 1.06× ✅ | even |
| `status-100files` | 3.18 / 3.41 | 5.99 / 6.31 | 1.88× | 1.80× | git |
| `add-64KB` | 3.23 / 3.40 | 8.36 / 8.70 | 2.59× | 2.55× | git |
| `diff-edit` | 2.72 / 2.85 | 12.18 / 12.58 | 4.47× | 4.39× | git |
| `add-1MB` | 16.30 / 16.56 | 100.49 / 101.45 | 6.17× | 6.50× ✅ | git |
| `log-100commits` | 4.38 / 4.50 | 28.34 / 29.18 | 6.48× | 5.78× | git |
| `clone-100commits` | 13.80 / 14.28 | 167.32 / 168.81 | 12.13× | 11.44× | git |

### What actually moved since v0.6.12

**sit got faster on 9 of 10 ops in absolute terms** — `init` −14%, `add-1KB` −20%,
`commit` −17%, `add-64KB` −13%, `add-1MB` −11%, `diff` −10%, `status` −7%,
`clone` −4%, `fetch` −5%; `log` flat (+1.5%). That is despite the v1.3.6–v1.4.0
audit arc adding ~1,150 lines of bounds checks and guards.

**The `log` and `clone` ratios widened anyway, and that is git getting faster, not
sit getting slower.** git's `log` went 4.83 → 4.38 ms (−9%) and its `clone`
15.20 → 13.80 ms (−9%) across 2.53.0 → 2.55.0 plus the kernel change.

⚠ **This was checked rather than assumed**, because those two ops do the most
per-object reads and v1.3.8 added a `hex_prefix_valid` gate to `read_object` — a
plausible culprit. Building v1.3.7's sources against the *same* toolchain and timing
`log` on the same 100-commit fixture:

```
v1.3.7 sources (no read_object gate, no commit-walk counter) : 28, 30, 29, 29, 28 ms
v1.4.0 sources (both guards present)                          : 28, 28, 28, 29, 29 ms
```

Indistinguishable. **The audit guards cost nothing measurable on the hot read path.**

### What bounds sit now

Unchanged in shape from v0.6.12 — the remaining gaps are all in dependencies, not
in sit's own code:

| slow op | dominant cost | where the fix lives |
|---|---|---|
| `clone` 12.13× | patra per-insert overhead + sankoch decompress per object | patra `patra_insert_row_or_ignore` (available, **unwired** — on sit's roadmap) |
| `log` 6.48× | sankoch `zlib_decompress` per commit + per-commit parse | sankoch small-input decompress throughput |
| `add-1MB` 6.17× | sankoch `zlib_compress` (~140 ms at 1 MB) | sankoch match-finder / SIMD (on sankoch's roadmap) |
| `diff` 4.47× | sankoch decompress + LCS | Myers fallback shipped v1.0.1; the DP path still dominates at this size |
| `status` 1.88× | 100× file open+read | not really a bottleneck; needs a larger fixture to say anything |

**Two of these are wiring, not research**: `patra_insert_row_or_ignore` and
`zlib_decompress_with_ratio_cap` both ship in the current folded dependency versions
and sit simply does not call them yet. `clone` is the op that would move.

---

## Operation latency (v0.6.12, 2026-04-25) — historical

All times in milliseconds, lower is better. Honest reporting. **5 of 10 ops are still slower than git**, but the `add-*` rows just dropped dramatically thanks to sigil 2.9.3's SHA-NI hardware path.

| operation | git (min / med) | sit (min / med) | sit/git ratio (min) | who's faster | what bounds sit |
|---|---:|---:|---:|---|---|
| `fetch-1commit` | 13.19 / 14.58 | **2.95 / 3.13** | **0.22×** | sit (~4.5×) | nothing here — sit's local-path wire is genuinely lean |
| `commit` | 4.69 / 5.62 | **2.93 / 3.24** | **0.63×** | sit (~1.6×) | nothing here |
| `init` | 3.14 / 3.65 | **2.09 / 2.39** | **0.67×** | sit (~1.5×) | nothing here |
| `add-1KB` | 2.89 / 3.24 | 3.06 / 3.54 | **1.06×** | even | sankoch zlib (small enough to disappear) |
| `status-100files` | 3.58 / 4.09 | 6.45 / 7.28 | 1.80× | git | 100× file open+read (sigil now fast enough that crypto isn't the bottleneck) |
| **`add-64KB`** | 3.77 / 4.05 | **9.62 / 10.41** | **2.55×** ↓ from 4.47× | git | sankoch zlib_compress(64KB) ~1.2ms + small constant |
| `diff-edit` | 3.08 / 3.55 | 13.53 / 14.45 | 4.39× | git | sankoch zlib_decompress + LCS (algorithmic — needs Myers') |
| `log-100commits` | 4.83 / 5.25 | 27.91 / 29.31 | 5.78× | git | sankoch zlib_decompress per commit + per-commit parse |
| **`add-1MB`** | 17.28 / 18.24 | **112.39 / 116.84** | **6.50×** ↓ from 12.48× | git | sankoch zlib_compress(1MB) ~140ms |
| `clone-100commits` | 15.20 / 15.90 | 173.87 / 177.66 | 11.44× | git | patra per-insert overhead + sankoch decompress per object |

## Evolution: how sit got here (v0.6.0 → v0.6.10)

Every release that moved any number, with the change responsible. Honest about which releases moved which ops and which ones missed.

| operation | v0.6.0 | v0.6.4 | v0.6.5 | v0.6.6 | v0.6.7 | v0.6.8 | v0.6.9 | v0.6.10 | v0.6.11 | v0.6.12 | total Δ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `init` | 1.77 | 2.31 | 1.88 | 2.06 | 2.00 | 2.00 | 2.07 | 1.97 | 2.00 | 2.09 | ~0% |
| `commit` | 2.79 | 2.99 | 2.90 | 2.91 | 3.03 | 2.92 | 2.83 | 2.77 | 2.72 | 2.93 | ~0% (-5%) |
| `add-1KB` | 2.93 | 3.41 | 2.83 | 3.14 | 2.98 | 2.95 | 2.89 | 3.04 | 3.13 | 3.06 | ~0% |
| **`add-64KB`** | 16.74 | 16.97 | 15.57 | 16.22 | 16.46 | 15.70 | 16.40 | 16.72 | 17.01 | **9.62** | **−43%** ✨ |
| **`add-1MB`** | 216.01 | 210.86 | 202.97 | 207.32 | 208.62 | 206.73 | 208.25 | 211.52 | 233.12 | **112.39** | **−48%** ✨ |
| `fetch-1commit` | 2.58 | 2.92 | 2.94 | 2.95 | 2.91 | 2.75 | 2.83 | 2.77 | 2.85 | 2.95 | ~0% |
| `diff-edit` | 14.09 | 13.67 | 13.32 | 13.55 | 13.67 | 13.27 | 13.86 | 13.72 | 14.59 | 13.53 | ~0% (-4%) |
| **`log-100commits`** | 33.44 | **29.32** | 27.68 | 29.61 | 28.21 | 27.83 | 27.67 | 27.73 | 29.79 | 27.91 | **−17%** |
| **`clone-100commits`** | (crash) | 251.64 | **208.44** | 215.27 | **168.53** | 168.61 | 172.64 | 170.84 | 183.64 | 173.87 | **−31%** vs v0.6.4 baseline |
| `status-100files` | (crash) | 7.44 | 6.98 | 6.77 | 7.08 | 6.64 | 7.00 | 7.01 | 7.01 | **6.45** | **−9%** across post-fix releases |

Notes on the table:
- v0.6.0 `clone` and `status` show "(crash)" because S-33 (the cyrius stdlib `alloc` grow-undersize bug + sankoch zlib symmetry bug, both surfaced in the same triage) made `sit status` SIGSEGV on the 100-commit fixture and `sit clone` died in the materialize step. v0.6.1 fixed those via dep bumps; the bench rows came back at v0.6.4.
- `clone` is reported as "−31% vs v0.6.4 baseline" because that's the first version where the row was bench-able. Against the projected pre-S-33-bug baseline (would have been ~245 ms in v0.6.0), the cumulative win is similar shape.
- All ratios in the "total Δ" column are vs v0.6.0 except where called out. "~0%" means within run-to-run noise across the whole arc.

**Where the wins came from:**
- `log` -17% from v0.6.4 — process-wide patra DB handle caching (P-01/02/05/08/12/25 collapse + S-24 fold-in). One open per process instead of one per `read_object` call.
- `clone` -31% from v0.6.5 + v0.6.7 combined — v0.6.5 wrapped `copy_objects` in a single `patra_begin`/`patra_commit` transaction (P-03, collapsed ~300 fsyncs into 1) and dropped the redundant outer `db_object_has` (the inner one inside `db_object_insert_raw` already does the check); v0.6.7 cached the compressed bytes during `walk_reachable_*` so `copy_objects` doesn't re-read commits + trees from the source DB (P-04).
- **`add-64KB` -43% and `add-1MB` -48% from v0.6.12** — sigil 2.9.3's SHA-NI hardware path. SHA-256 throughput went from ~12 MB/s software-only to ~400 MB/s on 64 KB inputs (32× factor). All-cap arrival on the `sit add` workload because hashing was the dominant cost. Filed on sigil's roadmap during the v0.6.4 review; landed two months later via dep bump only (no sit source change).
- **`status` -9% from v0.6.12** — small piece of the same sigil win (status hashes 100 small files; sigil portion was ~1ms of the 7ms budget pre-v0.6.12).

**Where intentional structural changes shipped without bench movement** (honest — these are real improvements that the 100-file synthetic bench is too small to show):
- v0.6.6 (P-10 + P-18): hashmap-backed `tree_find` and `three_way_path_set` (O(N²) → O(N)). Visible at 1000+ files; invisible at 100.
- v0.6.8 (P-17): buffered stdout (200+ direct stdout writes routed through a 64 KB buffer; fixes an output-ordering bug in `write_sanitized` along the way). Visible on large diffs (1000+ syscalls collapsed); invisible on the bench's one-hunk fixture.
- v0.6.9 (P-06 + P-15): tighter decompression sizing (16× → 4× initial multiplier; retry only on confirmed `-ERR_BUFFER_TOO_SMALL`); LCS DP table moved to `fl_alloc`/`fl_free` (mmap-backed, returns to kernel post-diff). Memory hygiene; no wall-clock signal.
- v0.6.10 (dep bumps): cyrius 5.6.35 → 5.6.40, patra 1.6.0 → 1.8.3. Closes S-31 (`patra_result_get_str_len` swap drops sit's `strnlen` workaround). patra `INSERT OR IGNORE` filed but not consumed (SQL-level only). patra `PATRA_SYNC_BATCH` group commit investigated and reverted (durability regression with no perf gain — `copy_objects` already uses explicit transactions; sit's cached handle never closes so BATCH-pending writes would sit in the kernel writeback window).
- v0.6.11 (P-20 + investigation): `parse_index` query gains `ORDER BY path`; insertion sort downstream falls through O(N). Multi-insert transaction wraps on `cmd_commit` + `rewrite_index` investigated and reverted (5-10% regression on modern SSDs — patra's per-txn setup exceeds saved fsyncs at small batch sizes; the pattern that won on `copy_objects` doesn't generalize to 2-50 inserts).
- **v0.6.12 (sigil SHA-NI + sankoch 2.1)**: pure dep-bump release. cyrius 5.6.40 → 5.6.43, **sigil 2.9.1 → 2.9.3**, sankoch 2.0.3 → 2.1.0. Sigil SHA-NI gives `add-*` the headline wins; sankoch's incremental DEFLATE work moves the standard zlib path modestly. No sit source changes shipped.

## Where the next big movements live — and who has to land them (v0.6.12 — historical)

> Superseded by the **What bounds sit now** table in the v1.4.0 section above. Kept
> because the projections are worth scoring against: the sigil SHA-256 ask it names
> did land, and `add-*` moved exactly as predicted.

Updated for v0.6.12: sigil's SHA-256 ask landed and shipped. The remaining gaps:

| sit op currently slow | dominant cost | where the next fix lives | projected after fix |
|---|---|---|---|
| **`status` 1.80×** | 100× file open+read (~3-4ms total); sigil now ~80µs (was ~1ms) | sit-side micro-opt OR larger-fixture validation; not really a bottleneck anymore | ~git parity at scale |
| **`add-1MB` 6.50× / `add-64KB` 2.55×** | sankoch `zlib_compress` (~140ms at 1MB; ~1.2ms at 64KB). Sigil portion solved | sankoch 2.x match-finder + ring-buffer + SIMD | ~2× git |
| **`log` 5.78×** | sankoch zlib_decompress per commit (~50KB total); per-commit parse | sankoch 2.x decompress throughput on small inputs | ~2× git |
| **`diff` 4.39×** | sankoch zlib_decompress + LCS algorithm | sankoch 2.x decompress + algorithmic Myers' diff (audit P-14, deferred to v0.8.0) | ~git parity |
| **`clone` 11.44×** | patra per-insert overhead (~150µs × 300 = ~45ms) + sankoch decompress per object | patra programmatic `INSERT OR IGNORE` flag on `patra_insert_row` (filed); sankoch 2.x decompress | ~3-4× git |

The picture has shifted: the dep ecosystem has paid down ~half the v0.6.0 sit-vs-git gap. Remaining wall-clock is split between patra's per-insert path and sankoch's compress/decompress on the relevant input sizes. Both are filed on those repos' roadmaps for further work.

## Per-primitive numbers from `tests/sit.bcyr` (v1.4.0, 2026-08-18)

Lower bound on what any sit command touching the primitive can achieve. Full run in
[`../benchmarks/2026-08-18-v1.4.0.md`](../benchmarks/2026-08-18-v1.4.0.md).

| Bench | v1.4.0 | v0.6.12 | Direct sit consumer |
|-------|-------:|--------:|---------------------|
| `sha256-64B` | **696 ns** | 802 ns | every content hash |
| `sha256-1024B` | **3.44 µs** | 3 µs | typical small-file `sit add` |
| `sha256-65536B` | **185 µs** | 161 µs | the SHA-256 slice of `add-1MB` |
| `zlib-compress-1024B` | 121 µs | 131 µs | every blob/tree/commit on `commit` |
| `zlib-compress-65536B` | **1.06 ms** | 1.158 ms | **dominates `add-1MB`** (~140 ms of the 100 ms total at 1 MB) |
| `zlib-decompress-1024B` | 44 µs | 36 µs | every `read_object` in `log`/`status`/`clone` |
| `zlib-decompress-65536B` | 331 µs | 346 µs | larger-blob decompress on `clone` |
| `patra-open-close` | 19 µs | 18 µs | avoided per-call via the v0.6.4 handle cache |
| `copy-objects-100` | **138 µs** (~1.4 µs/row) | 132 µs | the per-insert path inside `clone`/`push` |
| `commit-parse+iso8601` | 1.2 µs | 1 µs | per-commit CPU during `sit log` |
| `ed25519-sign` | **902 µs** | 1.166 ms | `sit commit -S` |
| `ed25519-verify` | **5.13 ms** | 6.811 ms | `sit verify-commit`; dominates signed-history `log` |
| `lcs-diff-1000x1000` | 35.2 ms | — | `sit diff` DP path (Myers fallback past the cap) |
| `is_ignored-200pat` | 142 µs | — | `.sitignore` matching per file |

⚠ The sigil/sankoch primitive numbers are **within noise of v0.6.12** in both
directions. The dependency stack has moved enormously since April (sigil 2.9.3 →
3.12.9, sankoch 2.1.0 → 2.7.7) but almost all of that was correctness, security and
new codecs — not throughput on these two shapes. `ed25519` is the exception, ~20-25%
faster in both directions.

### v0.6.12 table (historical)

These numbers are the lower bound on what any sit command involving the primitive can achieve. **Sigil SHA-256 just shipped its hardware path — note the 30× factor improvement on 64KB.**

| Bench | Time/op | Throughput / scale | Direct sit consumer | Δ vs v0.6.11 |
|-------|--------:|--------------------|---------------------|---:|
| `sha256-64B`   | **802 ns** | ~80 MB/s | every hash_blob_of_content | **12.5×** |
| `sha256-1024B` | **3 µs**   | ~341 MB/s | typical small-source-file `sit add` | **29×** |
| `sha256-65536B`| **161 µs** | ~407 MB/s | `add-1MB` SHA-256 portion (~3 ms of the 112 ms total now) | **32×** |
| `zlib-compress-1024B`   | 131 µs   | ~7.8 MB/s | every blob/tree/commit on `commit` | within noise |
| `zlib-compress-65536B`  | 1.158 ms | ~57 MB/s | `add-1MB` compress portion (~140 ms of 112 ms total — dominant) | 1.07× |
| `zlib-decompress-1024B` | 36 µs    | ~28 MB/s | every `read_object` in `log`/`status`/`clone` | within noise |
| `zlib-decompress-65536B`| 346 µs   | ~190 MB/s | larger-blob decompress on `clone`/`materialize` | within noise |
| `patra-open-close` | **18 µs** | per-call cost (sit avoids it via the v0.6.4 cache) | was the dominant `log` cost pre-v0.6.4 | unchanged |
| `copy-objects-100` | **132 µs total** (~1.3 µs/row) | per-row cost during `fetch`/`push`/`clone` | the per-insert path inside the v0.6.5 batched transaction | unchanged |
| `commit-parse+iso8601` | 1 µs | per-commit CPU cost during `sit log` | dwarfed by sankoch decompress | unchanged |
| `ed25519-sign`   | 1.166 ms | `sit commit -S` overhead | ~40% of signed-commit wall-clock | unchanged |
| `ed25519-verify` | 6.811 ms | `sit verify-commit` cost | dominates `sit log` decoration on signed histories | unchanged |
| `refname_valid-good`         | 322 ns | every ref write | negligible | unchanged |
| `tree_entry_name_valid-good` |  89 ns | every tree entry parsed/materialized | negligible | unchanged |
| `tree_flat_path_valid-good`  | 717 ns | every entry during materialize | negligible | unchanged |
| `hex_prefix_valid-64char`    | 213 ns | every ref-file read + `resolve_hash` | negligible | unchanged |

From these: **sigil SHA-256 is now ~400 MB/s** (was 12 MB/s — paid down via the sigil 2.9.3 SHA-NI hardware path). **sankoch zlib ≈ 50 MB/s compress / 190 MB/s decompress** is now the dominant remaining ceiling for the lagging ops. Sankoch's roadmap has follow-up DEFLATE work queued.

## Honest caveats

- **One machine, one run.** These numbers are a snapshot, not a study. Re-run on your own hardware before quoting. The bench script is at `scripts/benchmark.sh`.
- **The 100-file fixture is small.** Several v0.6.x changes are correct algorithmic improvements (P-10, P-18, P-17, P-15) that the synthetic bench can't see. They're real at scale (1000+ files / large diffs) but the table doesn't show that. If you need confidence at scale, build a larger fixture and re-run.
- **`fetch-1commit` is measured over a local path.** Both git and sit go through the
  filesystem there, which is why sit wins 4×. HTTP / HTTPS / SSH all shipped in the
  v0.7.x–v0.8.x line and are *not* in this table; a network comparison is a separate
  axis and would look different.
- **git is doing more.** git's install bundles rebase, gc, hundreds of plumbing
  commands. sit has 27. The footprint row means "sit covers the core VCS loop in
  ~3× less disk with no shared libraries", not "sit does the same work in ~3× the
  bytes".
- **`clone` at 12.13× is now the worst row**, not `add-1MB` (6.17×). If you are
  weighing sit for a workflow dominated by fresh clones, that is the gating number.
  It is also the one with the clearest path: `patra_insert_row_or_ignore` ships in
  the current patra and sit does not call it yet.
- **Two of the five slow rows are sit-side wiring, not upstream research.** That is a
  change from v0.6.12, when every remaining gap genuinely waited on a dep release.
  `patra_insert_row_or_ignore` and `zlib_decompress_with_ratio_cap` are both
  available today.
- **The v1.3.6–v1.4.0 audit guards are not visible here.** ~1,150 lines of bounds
  checks landed across that arc and sit still got faster on 9 of 10 ops. The one
  guard with a plausible hot-path cost (the `read_object` hex gate) was A/B'd against
  the same-toolchain v1.3.7 build and is indistinguishable — see the v1.4.0 section.

## Methodology

1. For each operation, build a **fresh** scratch repo every run — no warm-cache advantages either way.
2. Run the operation N times (`RUNS_HEAVY=10` for heavy ops, `RUNS_LIGHT=20` for light ones). Record each wall-clock time with `date +%s%N`.
3. Report **min** (approaches the true CPU cost, filtering out scheduler noise) and **median** (typical case).
4. Author identity is pre-configured on both sides (`Bench <b@e>`); no credential fetching in the hot path.
5. Benchmarks run serially on a quiet workstation; no background load beyond the normal desktop session.
6. `RUNS_LIGHT` and `RUNS_HEAVY` environment variables override the default iteration counts.

## Per-release bench snapshots

Releases with a measurable change ship a snapshot doc with full before/after tables and a "what didn't move and why" section. Most recent first:

- [`docs/benchmarks/2026-08-18-v1.4.0.md`](../benchmarks/2026-08-18-v1.4.0.md) — **current**; includes the `is_ignored` toolchain-vs-source isolation
- [`docs/benchmarks/2026-08-17-v1.3.7.md`](../benchmarks/2026-08-17-v1.3.7.md) — post-audit, no regression
- [`docs/benchmarks/2026-06-13-v0.9.0.md`](../benchmarks/2026-06-13-v0.9.0.md) · [`v0.8.12`](../benchmarks/2026-06-13-v0.8.12.md)

The v0.6.x arc:

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
- [`docs/benchmarks/2026-04-25-v0.6.11.md`](../benchmarks/2026-04-25-v0.6.11.md) — P-20 ORDER BY + multi-insert-txn investigation/revert
- [`docs/benchmarks/2026-04-25-v0.6.12.md`](../benchmarks/2026-04-25-v0.6.12.md) — **sigil SHA-NI + sankoch 2.1 throughput release; biggest single-release win of v0.6.x arc**

---

_v0.6.12 table generated by `scripts/benchmark.sh` at 2026-04-25T10:00:59Z (Linux 6.18.22-1-lts, git 2.53.0). v1.4.0 table generated 2026-08-17T19:11:25Z (Linux 7.1.8-arch1-3, git 2.55.0, cyrius 6.5.26)._
