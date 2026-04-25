# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.7.1] — 2026-04-25 — URL scheme detection + transport dispatch stubs

**First feature-bearing patch in the v0.7.x line. Pure plumbing — no transport yet.** Sets up scheme classification and per-command dispatch so `sit remote add origin http://...` succeeds today, while `sit fetch origin` and `sit clone https://...` fail with a clean per-scheme message naming the v0.7.x patch that lights each transport up.

### Added

- **`url_scheme(url)`** in `src/validate.cyr` — classifies a URL as one of `URL_SCHEME_FILE` (covers `file://`, absolute, and relative paths), `URL_SCHEME_HTTP`, `URL_SCHEME_HTTPS`, `URL_SCHEME_SSH`, or `URL_SCHEME_INVALID`. Pure prefix match, no body validation; pair with `remote_url_valid` for the full check.
- **`url_authority_path_valid(s, len)`** — whitelist body validator for the authority+path of a network URL. Accepts `[a-zA-Z0-9.-_/:@%~]`, rejects empty body and leading `-` (second-layer CVE-2017-1000117 defense). v0.7.3 (HTTP fetch) and v0.7.8 (SSH transport) will tighten further.
- **`wire_transport_check(url)`** in `src/wire.cyr` — caller-pattern helper: `if (wire_transport_check(url) != 0) { return 1; }`. Lights up per-scheme errors naming the upcoming v0.7.x patch (HTTP→0.7.2, HTTPS→0.7.6, SSH→0.7.8).
- **Tests** — 26 new assertions in `tests/sit.tcyr` covering positive http/https/ssh acceptance, port + userinfo shapes, empty-authority rejection, shell-metachar rejection in authority body, and the full `url_scheme` truth table including prefix-collision cases (`http` without `://` → INVALID).
- **Fuzz** — `fuzz_url_validators` in `tests/sit.fcyr` (10000 rounds) feeds random NUL-terminated bytes through `url_scheme` + `remote_url_valid`. Caught a missing-include footgun during dev (Cyrius compiles undefined refs to null pointers and SIGILLs at call site rather than erroring at link); fuzz file now `include "src/validate.cyr"` explicitly.

### Changed

- **`remote_url_valid(url)`** now accepts `http://`, `https://`, `ssh://` URLs that pass the universal control-char + leading-dash gates AND have a body matching `url_authority_path_valid`. Local-path acceptance unchanged. URLs validate at remote-add time so users can wire config in advance — transport itself ships in later v0.7.x patches.
- **`cmd_remote_add`** error message simplified ("invalid or unsupported remote URL"); the `(file:// or absolute/relative path only in v0.6)` qualifier was stale.
- **`cmd_clone`** + **`do_fetch`** + **`cmd_push`** dispatch on URL scheme after validation. Network schemes return rc 1 with the appropriate "transport requires sit 0.7.X+" message; file/path schemes proceed exactly as v0.7.0.

### Sandhi posture

Adding `"sandhi"` to `[deps].stdlib` was attempted and reverted in this release — sandhi requires `SYS_SETSOCKOPT` and friends from `lib/net.cyr`, which would mean cascading `net`/`tls`/`ws`/`http`/`json` into the stdlib list. Per CLAUDE.md "ONE change at a time," that whole block lands in v0.7.2 alongside the actual `sit serve` skeleton — the first release where sandhi has a real caller. v0.7.1 ships pure URL plumbing.

### Sit-side impact

- Build: clean. Tests: **127/127 pass** (101 + 26 new). Fuzz: 10,000 rounds clean on `url_scheme` + `remote_url_valid`. DCE binary: **709 KB** (+2 KB vs 0.7.0; new validators + dispatch helper).
- E2E verified: `sit remote add origin http://example.com` succeeds; `sit fetch origin` → `sit: http transport requires sit 0.7.2+ (this is 0.7.1)` rc 1; `sit clone https://...` → equivalent message; CVE-2017-1000117 inputs (`-oProxyCommand=...`) still rejected at validation.
- Wire protocol shape, server design (`sit serve`), URL routes (`/sit/v1/...`), and bearer-token auth model settled per the v0.7.x plan; no code yet.

## [0.7.0] — 2026-04-25 — sandhi-fold unlock, v0.7.x line opens

**Minor-line opener. Toolchain-only — no sit source changes yet.** This release marks the v0.6.x perf arc closed and the v0.7.x network-transport line open. The release content is just the cyrius 5.7.0 ("the sandhi fold") pickup; the actual HTTP/SSH transport work lands in subsequent v0.7.x releases now that sandhi is reachable from stdlib.

### Why 0.7.0 now (not 0.6.13)

The v0.7.0 ship target on the roadmap was **network transport (HTTP/SSH)**, gated on sandhi being reachable from a sit consumer. Cyrius 5.7.0 vendored `sandhi` v1.0.0 into the stdlib as `lib/sandhi.cyr` (per [sandhi ADR 0002](https://github.com/MacCracken/sandhi/blob/main/docs/adr/0002-clean-break-fold-at-cyrius-v5-7-0.md)), which removes that gate. From here, opting sit into sandhi is a one-line addition (`"sandhi"` in the inline `[deps].stdlib`), not a new git-pinned `[deps.sandhi]` crate — sandhi entered maintenance mode at the fold; future surface patches ship via cyrius releases.

### Changed

- **cyrius 5.6.43 → 5.7.0**: pin bumped in `cyrius.cyml`. Self-host fixpoint stable at 531,888 B upstream; cyrius `check.sh` 26/26 green.

### Removed

- **`lib/http_server.cyr` orphan**: a stale 15,579-byte regular-file copy of the pre-fold stdlib snapshot left over from a prior `cyrius deps` run. Sit had **zero callers** (`grep` clean across `src/` + `tests/`); deletion is the action cyrius 5.7.0's downstream worklist names for sit. `cyrius deps` under 5.7.0 does not re-resolve the file.

### Sit-side impact

- Build: clean. Test: 101/101 pass. DCE binary: **707 KB** (down from 710 KB — small drop from 5.7.0's stdlib reshape; not a perf claim, just an observation).
- No runtime behavior change. No public-surface change. No dep-pin change beyond cyrius itself.

### Up next (v0.7.x line)

Network transport: HTTP fetch/push first (sandhi `sandhi_http_get` / `_post`); SSH transport second. The v0.7.0 release itself is intentionally hollow on transport — it's the unlock marker — so v0.7.1 is the first feature-bearing patch in the line.

## [0.6.12] — 2026-04-25 — sigil SHA-NI + sankoch 2.1 throughput release

**Pure dep-bump release with the biggest single-release wins of the v0.6.x arc.** No sit source changes. cyrius 5.6.40 → 5.6.43, sigil 2.9.1 → 2.9.3 (SHA-NI hardware path landed), sankoch 2.0.3 → 2.1.0 (DEFLATE micro-tuning). Headline:

- **`sit add` of a 64 KB file: −41%** (16.40 ms → 9.62 ms; sit/git ratio 4.5× → **2.55×**)
- **`sit add` of a 1 MB file: −48%** (211.52 ms → 112.39 ms; sit/git ratio 12.5× → **6.50×**)
- **`status-100files`: −8%** (7.01 ms → 6.45 ms; sit/git ratio 1.87× → 1.80×)

### Performance

- **sigil 2.9.1 → 2.9.3**: the SHA-256 throughput investigation filed on sigil's roadmap during sit's v0.6.4 perf review landed. SHA-NI hardware path on x86_64 hits ~400 MB/s on 64 KB inputs (was ~12 MB/s software-only). Per-primitive deltas:
  - `sha256-64B`: 10 µs → **802 ns** (12.5×)
  - `sha256-1024B`: 87 µs → **3 µs** (29×)
  - `sha256-65536B`: 5.153 ms → **161 µs** (32×)
- **sankoch 2.0.3 → 2.1.0**: incremental DEFLATE wins from the throughput investigation filed on sankoch's roadmap. Pre-reversed dynamic Huffman codes + others. Standard zlib path moves modestly at small/medium sizes (~5-7% on compress, within noise on decompress); larger 2.x match-finder / ring-buffer / SIMD work queued for follow-up sankoch releases.
- **cyrius 5.6.40 → 5.6.43**: toolchain hygiene. Three patches.

### How the wins cascade

The sigil SHA-256 speedup directly hits `sit add`'s hot path (`hash_blob_of_content` over the file content):
- `add-64KB`: ~5 ms saved out of 16 ms total = sigil accounts for ~99% of the saving.
- `add-1MB`: ~77 ms saved out of 121 ms total = sigil ~85%; sankoch 2.1 the remaining ~10 ms.

The `status-100files` case picks up only 8% because it was already file-I/O-bound (100× open+read at ~3-4 ms total) — sigil hashing was ~1 ms of the 7 ms budget; saving 900 µs of that lifts the 8%.

`log`, `clone`, and `diff` within run-to-run noise — those workloads are bound by sankoch's small-input decompress path or patra's per-insert overhead, neither of which 2.1 / 1.8 moved meaningfully.

### Cumulative scoreboard (0.6.0 → 0.6.12)

| operation | v0.6.0 (min ms) | v0.6.12 (min ms) | cumulative delta |
|---|---:|---:|---:|
| `init` | 1.94 | 2.09 | ~0% |
| `commit` | 3.09 | 2.93 | ~0% (-5%) |
| **`log-100commits`** | 33.67 | 27.91 | **−17%** |
| **`status-100files`** | 7.10 | 6.45 | **−9%** |
| **`clone-100commits`** | 247.59 | 173.87 | **−30%** |
| `fetch-1commit` | 3.13 | 2.95 | ~0% (-6%) |
| **`add-64KB`** | 16.74 | 9.62 | **−43%** ✨ NEW |
| **`add-1MB`** | 216.01 | 112.39 | **−48%** ✨ NEW |
| `diff-edit` | 14.09 | 13.53 | ~0% (-4%) |

`add-64KB` and `add-1MB` join `log` and `clone` as headline-mover workloads. The `add-1MB` ratio drop from 12.5× to 6.5× is the largest user-visible improvement of the v0.6.x arc.

### Documentation

- New bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.12.md`](docs/benchmarks/2026-04-25-v0.6.12.md). Per-primitive table, cascade math (how much of each win is sigil vs sankoch), cumulative scoreboard, and the updated "where the next wins live" map.

### What's still slow — and what owns the gap now

With sigil's SHA-256 ceiling lifted, the remaining sit-slower-than-git rows shift to:

- `clone` 11.4×: patra's per-insert overhead (~150 µs × 300 = ~45 ms of 174 ms) + sankoch's small-input decompress (per object). Next mover: patra programmatic `INSERT OR IGNORE` (filed) + sankoch 2.x decompress.
- `add-1MB` 6.5×: sankoch `zlib_compress(1 MB)` ~140 ms is now the dominant cost. Next mover: sankoch's queued match-finder + ring-buffer + SIMD work.
- `log` 5.78×: sankoch decompress per commit. Next mover: sankoch small-input decompress.
- `diff-edit` 4.39×: LCS algorithm (sit-side, P-14 Myers' diff deferred to v0.8.0) + sankoch decompress.
- `add-64KB` 2.55×: sankoch `zlib_compress(64KB)` ~1.2 ms + small constant. Next mover: sankoch DEFLATE work.

All filed on the relevant lib roadmaps.

## [0.6.11] — 2026-04-25 — P-20 + multi-insert-transaction investigation

Small algorithmic improvement (P-20: push sort to patra's `ORDER BY`) plus a documented negative-result investigation (multi-insert transactions in `cmd_commit` and `rewrite_index` regress on modern SSDs and were reverted before shipping). **No bench movement** at the 100-entry fixture; P-20's win is real at monorepo scale (~500ms saved per `parse_index` at 10K entries).

### Performance

- **P-20** — `parse_index` (`src/index.cyr`) now uses `SELECT path, hash_hex FROM entries ORDER BY path` instead of an unordered SELECT. Patra has supported ORDER BY since at least 1.6.0; sit just wasn't using it. Downstream callers run `sort_entries` after `parse_index` — an insertion sort that was O(N²) on unsorted input. With pre-sorted entries, insertion sort runs O(N) (one pass that finds each element already in place). Concrete saving per call: ~50µs at 100 entries (under bench noise), ~5ms at 1K, ~500ms at 10K.

### Investigated and reverted

- **Multi-insert transactions in `cmd_commit` (2-3 inserts) and `rewrite_index` (1–50 inserts).** The open question after v0.6.10's BATCH-mode revert: would wrapping these short batches in explicit `patra_begin` / `patra_commit` amortize fsync the way `copy_objects` does (v0.6.5 P-03, the change that gave clone its biggest single-release win)? Implemented both. **A/B measured on a 50 `sit add` + `sit commit` cycle workload: 5-10% regression** (pre 230ms / post 248ms median across 3 runs each). Reverted before shipping.

  Root cause: on modern SSDs the per-insert fsync cost is small enough (kernel batches dirty-page flushes) that patra's per-transaction setup/teardown (lock + header read + WAL start + commit + header write + unlock, ~30µs) exceeds the savings unless the batch is large. `copy_objects` (~300 inserts) clears the bar; `cmd_commit` (2-3) and `rewrite_index` at small N don't. The pattern would likely flip on rotating disks or busy SSDs — but optimizing for the slow case via a regression on the fast case isn't defensible without per-host benchmarking and a configuration knob, neither justified yet.

  Investigation captured in [`docs/benchmarks/2026-04-25-v0.6.11.md`](docs/benchmarks/2026-04-25-v0.6.11.md) so future work doesn't waste time relearning it.

### Documentation

- New bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.11.md`](docs/benchmarks/2026-04-25-v0.6.11.md). Includes the multi-insert-txn investigation table (insert count vs setup overhead vs net) and a "what remains" section enumerating the legitimately-on-the-table sit-side items vs the dep-blocked ones.

### Cumulative scoreboard (0.6.0 → 0.6.11)

Same shape as v0.6.10. Headline cumulative wins: `log -12 to -18%`, `clone -25 to -32%` (the range reflects run-to-run noise across snapshots, not regression). Other ops within noise but trending favorable across releases (`commit -12%`, `fetch -9%`).

## [0.6.10] — 2026-04-25 — dep bumps + S-31 closeout

Small dep-bump release. Picks up the patra and cyrius patches that shipped while sit was working on the v0.6.x perf arc. **No bench movement** (honest — the dep changes don't target the workloads the harness covers; the patra group-commit feature was investigated and explicitly reverted as a durability regression with no perf gain).

### Changed

- **cyrius 5.6.35 → 5.6.40.** Five toolchain patches. None target sit's bottlenecks; picked up for general hygiene.
- **patra 1.6.0 → 1.8.3.** Picks up:
  - **1.6.1 — `patra_result_get_str_len(rs, row, col)`** sized accessor (consumed: see Fixed below).
  - **1.7.0 — `INSERT OR IGNORE INTO` SQL syntax.** **Not consumed yet.** Sit's object-store inserts go through `patra_insert_row` (the only path that handles BYTES columns), not through SQL strings. patra's `INSERT OR IGNORE` is SQL-level only; sit will pick this up when patra grows an `or_ignore` flag on the programmatic insert path.
  - **1.8.x — WAL group commit (`PATRA_SYNC_BATCH`).** **Investigated and NOT consumed.** See "BATCH mode investigation" below.

### Fixed

- **S-31** — `parse_index` (`src/index.cyr`) now uses `patra_result_get_str_len(rs, i, 0)` directly instead of the v0.6.3 `strnlen(path_str, 256)` workaround. Same safety property at the read site (bound-walked within `COL_STR_SZ`), but now asked of patra's API directly. `strnlen` helper removed from `src/util.cyr` (no other consumers).

### Investigated and reverted

- **patra `PATRA_SYNC_BATCH` mode.** Initially set on both cached DB handles in v0.6.10's branch. Re-benched: `clone-100commits` 170.92 ms vs v0.6.9's 172.64 — within run-to-run noise. **No measurable improvement** because (a) `copy_objects` already wraps its hot loop in `patra_begin`/`patra_commit` (v0.6.5 P-03) which provides the same fsync amortization on the only batch-shaped write path, (b) the `cmd_commit` 3-insert sequence is below the every-64-writes auto-flush threshold so coalescing doesn't trigger inside a single command, (c) sit's cached handle never `patra_close`s — so BATCH-pending writes between auto-flushes would sit in the kernel writeback window with no fdatasync, lost on power loss within the window. **Net: no perf gain, real durability cost.** Reverted before shipping; the call sites are documented with the reasoning so a future release can revisit when sit grows explicit `patra_flush()` at command exit.

### Documentation

- New bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.10.md`](docs/benchmarks/2026-04-25-v0.6.10.md) (includes the BATCH-mode investigation writeup and the two "what we didn't do — and how to do it later" follow-up paths).

### Cumulative scoreboard (0.6.0 → 0.6.10)

Identical to v0.6.9's — no headline movement this release. `log -18%`, `clone -31%`. Next sit-side mover is either (a) explicit transactions + flush at exit on multi-insert commands like `cmd_commit` (small effort, optional follow-up release), or (b) wait for sigil 2.9.x SHA-256 throughput / sankoch DEFLATE throughput / patra programmatic `INSERT OR IGNORE` to ship and pick up the corresponding consumer-side improvements.

## [0.6.9] — 2026-04-25 — sit-side v0.6.x perf arc closed

P-06 + P-15 hygiene release. Two small items that close out the audit's perf-arc backlog. **No measurable bench movement** at the 100-file fixture (both changes are memory hygiene / edge-case, not hot-path), but they're correct and worth shipping for completeness.

### Performance

- **P-06 — smarter decompression sizing.** Three call sites updated (`src/object_db.cyr:read_object`, the loose-migration path, `src/wire.cyr:db_object_read_both`):
  - Initial multiplier dropped from 16× to 4×. Most sit objects (commits, trees, source-shape blobs) decompress at ratio ~2-3× and fit; legitimately high-ratio outliers retry at the 16 MiB ceiling.
  - Retry only on confirmed `0 - ERR_BUFFER_TOO_SMALL` (= -2 from sankoch) — other negative codes mean the stream is corrupt and more memory won't help. Fail fast on real corruption.
  - Memory: 75% reduction in decompression-buffer alloc on objects with `blen > 1024` (real source files); the 4096-byte floor still dominates for the bench's tiny fixture objects.
- **P-15 — LCS DP table to `fl_alloc`.** `src/diff.cyr:lcs_diff` now allocates the DP table via `fl_alloc` (mmap-direct for large allocations) and `fl_free`s before returning. Previously the table sat on the bump heap permanently for the life of the process — up to 128 MB of permanent RSS for diff-heavy commands. Now the memory goes back to the kernel after the LCS computation completes.

Both changes are memory hygiene — no wall-clock signal on the synthetic bench (expected and called out in advance). Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.9.md`](docs/benchmarks/2026-04-25-v0.6.9.md).

### Final v0.6.x cumulative scoreboard

`log` **-18%**, `clone` **-30%** from a half-dozen small targeted changes. Other ops within run-to-run noise (their bottlenecks are dep-side: sankoch zlib throughput, sigil SHA-256 throughput, patra WAL fsync — all filed on those repos' roadmaps).

### Sit-side v0.6.x perf arc closed

Every audit P-NN item that targets sit-side code is now either shipped (P-01, P-02, P-03, P-04, P-05, P-06, P-08, P-10, P-12, P-15, P-17, P-18, P-25 — and S-24 which folded into P-01) or explicitly moved out of scope to v0.7.x / v0.8.0 (P-07 bump-arena reset, P-11 sit add upsert — needs patra UPSERT, P-13 glob bucket, P-14 Myers diff algorithm, P-16 fsck --fast, P-19/P-21/P-23 micro-wins). Next ship target: **v0.7.0 network transport (HTTP/SSH)**, queued since v0.5.0 shipped local-path transport — or wait on patra 1.7.0 / 1.8.x / sigil throughput / sankoch throughput shipping and revisit perf with a fresh upstream baseline.

## [0.6.8] — 2026-04-25

P-17 perf release: buffered stdout. 200+ direct `syscall(SYS_WRITE, STDOUT, ...)` call sites across nine source files swapped to a single buffered `stdout_write(data, len)` helper. **No measurable bench movement on current fixtures** — the synthetic `diff-edit` is too small to show the win — but the change is structural and right. Caught and fixed a real output-ordering bug in `write_sanitized` along the way.

### Performance

- **P-17** — added `stdout_write(data, len)` and `stdout_flush()` helpers in `src/util.cyr` backed by a 64KB lazy-allocated heap buffer. Auto-flushes on buffer-full; large writes (≥ buffer size) flush pending bytes and go straight to the kernel without buffering. `src/main.cyr` trailer flushes before `SYS_EXIT`. STDERR (`eprintln`) stays direct so error output is immediate.
- Bulk-replaced `syscall(SYS_WRITE, STDOUT, ` → `stdout_write(` across `diff.cyr` (54), `wire.cyr` (37), `commit.cyr` (34), `refs.cyr` (24), `sign.cyr` (22), `index.cyr` (14), `merge.cyr` (11), `object_db.cyr` (6), `config.cyr` (4). 206 sites total.
- **`write_sanitized` rewrite**: was emitting one byte per `syscall(SYS_WRITE, fd, &single, 1)` — a buffer-bypass AND a perf footgun. Now builds the sanitized bytes into a heap buffer in one pass and emits via a single write (through `stdout_write` when fd == STDOUT, direct otherwise). Caught an output-ordering bug introduced by the bulk swap: `print_commit_header` was calling `stdout_write("Author: ", 8)` (buffered) then `write_sanitized(STDOUT, ident, ...)` (direct, unbuffered) — the unbuffered author bytes hit stdout before the buffered "Author: " prefix did. Fix in the same change.

**Why the bench didn't move**: audit's "3000+ writes for a 500-line diff" estimate was for diffs with many hunks. The bench fixture is a 500-line file with ONE changed line → actual output is one hunk ≈ 30 writes ≈ 30µs at the syscall level — already under the noise floor of `diff-edit`'s 13ms total. Ad-hoc test on a 2000-line file with 1000 changes (45KB output) lands ~185ms; without buffering would be ~1000 syscalls = a few ms saved. Visible at scale, not in the synthetic bench.

Structural benefit beyond wall-clock: lower system-wide syscall pressure, reduced context-switch cost, and the buffer guarantees in-order writes (which is what surfaced the `write_sanitized` ordering bug — a problem the unbuffered version had been hiding by virtue of small per-call writes mostly coalescing in the terminal).

Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.8.md`](docs/benchmarks/2026-04-25-v0.6.8.md).

### Cumulative scoreboard (0.6.0 → 0.6.8)

`log` **-17%**, `clone` **-32%**. Other ops within noise but trending slightly favorable across releases.

## [0.6.7] — 2026-04-25

P-04 perf release: walk-reachable now caches the compressed bytes it pulled and shares them with `copy_objects`, so commits + trees aren't re-read from the source DB. **`sit clone-100commits`: −21.7%** (215.27 → 168.53 ms min, 13.64x git → 11.08x git).

### Performance

- **P-04** — `walk_reachable_*` was decompressing every commit + tree, which internally pulled the compressed bytes from `src_db` via `db_object_read_raw`. Then `copy_objects` re-read the same bytes for the insert into `dst_db` — every commit + tree was paying for two source-DB reads instead of one. Fix lands in three pieces in `src/wire.cyr`:
  1. New `db_object_read_both(db, hex, raw_out, deco_out)` returns BOTH the compressed bytes (formerly thrown away after the internal call) AND the decompressed view. `db_object_read_decompressed` becomes a thin wrapper.
  2. `walk_reachable_tree` and `walk_reachable_from_commit` gain a `raw_cache` parameter; they call `db_object_read_both` and stuff the raw bytes into the cache keyed by hex.
  3. `copy_objects` gains a matching `raw_cache` parameter; checks the cache first per object and skips the source-DB read on hit. Cache misses (blobs only — walk doesn't visit them) fall back to `db_object_read_raw` as before.
- **Concrete savings on the 100-commit / 100-file fixture**: 500 source SQL ops → 300 (−40%). Wall-clock goes from 215ms to 169ms (−21.7%). Bigger than the naive "saved page fetch only" projection because each cache hit also avoids SQL parse + B+ tree walk + result-set setup (~150µs per saved op × 200 saved ops).
- Other ops within run-to-run noise as expected: `log` doesn't use walk_reachable (uses commit-chain `read_object` walk, already cached at the patra-handle level since v0.6.4); `status` / `add` are dep-side bound (sigil + sankoch).

Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.7.md`](docs/benchmarks/2026-04-25-v0.6.7.md).

### Cumulative scoreboard (0.6.0 → 0.6.7)

`log` **-16%**, `clone` **-32%**, everything else within noise (dep-side bound or already past sit's ceiling).

## [0.6.6] — 2026-04-25

P-10 + P-18 perf release. Two hot-path lookups moved from O(N²) to O(N). **No measurable improvement on the 100-file synthetic bench** — the fixture is too small to show the win — but the change is real and substantial at repo scale (1000+ tracked files).

### Performance

- **P-10** — `tree_find` in `src/tree.cyr` now lazily builds a name → entry hashmap on first call per entries vec, cached by vec pointer for the process lifetime. Hot callers (`cmd_status` iterating index entries against `head_entries`; `cmd_diff` against tree_a/tree_b; `materialize_target`; the merge three-way loops in `merge.cyr`) drop from O(N²) total to O(N). Single tree_find calls are unchanged in cost (one map build + one lookup = same complexity as the old linear scan); multi-call hot paths see the structural improvement.
- **P-18** — `three_way_path_set` (also `src/tree.cyr`) now dedups via `map_has` instead of a nested `streq` scan over the growing paths vec. For three trees of N entries each: was ~4.5N² streqs, now 3N inserts + 3N membership checks. Used by `cmd_merge`'s three-way path enumeration.

**Why the bench didn't move**: the fixture is 100 files. At that scale, the old O(N²) cost is ~10000 streqs per status — already under the noise floor compared to the dominant costs (per-file sigil hashing for `status`, per-object zlib for `clone`). The hashmap-build adds a small constant overhead (one map per command) that's also under the noise floor. Concrete projection: a 1000-file `cmd_status` drops from ~5ms of pure scan to ~0.3ms; a 10000-file repo sees ~50× improvement on that piece. The 100-file synthetic bench can't see it, and a larger-N bench fixture is queued for whenever we have a real consumer pushing those scales.

Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.6.md`](docs/benchmarks/2026-04-25-v0.6.6.md).

### Documentation

- Bench snapshot adds a "Cumulative scoreboard" section showing 0.6.0 → 0.6.6 deltas: `log` -12%, `clone` -13%, everything else noise.

## [0.6.5] — 2026-04-25

P-03 perf release: `copy_objects` batched into a single patra transaction, redundant outer has-check dropped. **`sit clone` of a 100-commit / 100-file repo: −15%** (245.19 → 208.44 ms min, 16.13x git → 13.82x git). All other operations within run-to-run noise — their bottlenecks remain dep-side (sigil SHA-256 throughput, sankoch zlib throughput) and are filed on those repos' roadmaps.

### Performance

- **`sit clone` (100-commit / 100-file fixture): −15%** at `RUNS_LIGHT=20 RUNS_HEAVY=10`. Three changes in `src/wire.cyr:copy_objects`:
  1. Wrap the insert loop in `patra_begin` / `patra_commit`. Collapses ~300 individual WAL fsyncs into one commit. Patra exposes these primitives as stdlib functions; they were dead code in every sit build prior to v0.6.5.
  2. Drop the outer `db_object_has` check. `db_object_insert_raw` already does its own has-check internally — every object was paying for two SELECTs instead of one. Halves the SQL round-trips on the dedup path.
  3. Side-effect counting fix: `db_object_insert_raw` now returns `1` for already-existed (vs. `0` for actually-inserted; negative for error), so `copy_objects` counts only genuine new inserts. Caught by the wire-protocol smoke test — without the fix, `sit push` on a clone reported all reachable objects as "new" instead of just the locally-added ones.

The bigger wins on `clone` are gated on patra-side work — `WAL group commit / batched fsync` and `INSERT OR IGNORE` / `UPSERT` are filed on patra's roadmap (entries cite this release's bench snapshot). Once those land, a follow-on sit release can drop the manual transaction wrapping and the inner has-check; expected combined improvement is another ~30-50% on top of v0.6.5's gain.

### Documentation

- New bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.5.md`](docs/benchmarks/2026-04-25-v0.6.5.md).
- `docs/development/roadmap.md` v0.6.5+ section gained a "Waiting on dep updates" subsection that lists the patra / sigil / sankoch items now tracked on each lib's own roadmap. When any of those ship, sit can drop the corresponding workaround / pick up the matching improvement without further sit-side code changes.

## [0.6.4] — 2026-04-25

First v0.6.x perf release. Process-wide patra-handle caching collapses six audit findings (P-01, P-02, P-05, P-08, P-12, P-25) plus the deferred S-24 into one refactor. `sit log` on a 100-commit history is **~17% faster** (33.67 → 27.84 ms min, RUNS_LIGHT=20). Other commands (status, clone, fetch, add) unchanged in this release — their bottlenecks (sigil throughput, per-object zlib_decompress, file_write_all) are downstream of patra open/close cost. Real status / clone wins need separate work in subsequent releases.

### Changed

- **`src/object_db.cyr`** — added `get_object_db()` process-wide cached handle for `.sit/objects.patra`. Lazy-open + lazy `object_db_migrate_from_loose` on first call. fd dies with the process (`patra_close` is just buffer-free + close — no WAL flush — so skipping it at exit is safe). `read_object`, `write_typed_object`, `resolve_hash`, `cmd_fsck` migrated to the cache; their previous `var db = open(); ... patra_close(db);` pattern is gone.
- **`src/index.cyr`** — added `get_index_db()` cached handle for `.sit/index.patra` (same shape). `parse_index` and `rewrite_index` migrated.
- **`src/wire.cyr`** — `do_fetch` and `do_push` use the cached local DB; the remote DB end (different file each call) stays per-operation.

### Fixed

- **S-24** (Patra-handle + SQL-string leaks; `read_object` single-exit refactor) — landed as part of the cache refactor, as planned in v0.6.2's deferral note. The single-exit shape fell out naturally once the open/close pattern was gone. SQL-string buffers in `read_object` / `resolve_hash` / `write_typed_object` switched from `alloc_or_die` (bump-heap, lives forever) to `fl_alloc` + `fl_free` (mmap'd, freed after each query). Trims per-query bump-heap pressure on long-running ops like `sit log` / `sit fsck` over thousands of objects.

### Performance

- **`sit log`** (100-commit walk): **−17%** (33.67 ms → 27.84 ms min, `RUNS_LIGHT=20` against git 2.53.0). Higher commit counts amortize the same fixed-cost win — expect proportionally larger savings on 1K- or 10K-commit histories.
- **`sit fsck`** (100-commit / 100-file fixture): not in the bench harness yet, but exercises the same pattern (one query → N read_object calls). Wins should match or exceed `log`.
- **`sit status`**, **`sit clone`**, **`sit add`**, **`sit commit`**, **`sit fetch`**: within run-to-run noise. Their bottlenecks are sigil hash throughput (status / add) or per-object zlib_decompress + file_write_all (clone) — both downstream of patra open/close. Queued for separate releases:
  - **P-03** batch `copy_objects` in a single transaction → clone speedup
  - **P-06 + P-15** smarter decompression sizing + LCS DP table via fl_alloc → diff / clone speedup
  - **P-04** denormalize tree/parent hashes so `walk_reachable_from_commit` doesn't decompress every commit/tree just to read headers
  - sigil SHA-256 throughput → upstream sigil's roadmap

Full snapshot: [`docs/benchmarks/2026-04-25-v0.6.4.md`](docs/benchmarks/2026-04-25-v0.6.4.md).

## [0.6.3] — 2026-04-25

LOW-severity batch from the 2026-04-24 P(-1) audit. All audit findings (CRITICAL, HIGH, MEDIUM, LOW) are now closed or explicitly deferred to the v0.6.x perf arc. Two of the three v0.6.3 items resolved via documentation rather than code change, since the underlying invariants were already in place.

### Security

- **S-28** — `exec_vec` envp scrubbing: **already addressed via stdlib**. Cyrius's `lib/process.cyr:exec_vec` passes an empty envp to the child process (`var envp = alloc(8); store64(envp, 0);`), which is strictly more aggressive than the audit's "minimal envp" prescription — `LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, and every other env var is dropped on owl exec by construction. No sit-side change required. Recorded in audit so future readers don't re-investigate; documented in `docs/development/state.md` so any future curated-envp shape (e.g. preserving PATH/HOME/TERM/LANG for owl UX) is a deliberate widening, not a tightening.
- **S-31** — added `strnlen(s, max)` to `src/util.cyr`. Swapped `parse_index`'s `strlen(path_str)` over a `patra_result_get_str` result to `strnlen(path_str, 256)` (patra's `COL_STR_SZ` width). The other three `patra_result_get_str` callers in sit memcpy a fixed 64 bytes (hash columns) and are safe by construction. Defense-in-depth against any future patra writer that skips the slot zero-fill — today patra always memsets the 256-byte slot before writing, so `strlen` would terminate inside the slot, but the bound makes the safety property explicit at the read side rather than implicit at the write side.
- **S-32** — Cyrius string-literal lifetime invariant **confirmed and documented** in [`docs/architecture/004-cyrius-string-literal-lifetime.md`](docs/architecture/004-cyrius-string-literal-lifetime.md). Cyrius compiles `"..."` literals into a fixed compile-time string-data region (cyrius's own 2026-04-13 audit pins the size at 256 KB) that is mapped for the lifetime of the process — the same model as C's `.rodata`. `src/tree.cyr`'s `store64(le, "100644")` pattern is safe because the literal pointer never goes stale. The audit's alternative fix (switch to integer mode codes with a format table) was rejected: it would trade a free invariant for runtime indirection on the hottest tree-build path. ADR-style note also explains why `argv(n)` and `patra_result_get_str` pointers do NOT have the same lifetime properties.

### Added

- `src/util.cyr:strnlen(s, max)` — bounded-walk replacement for `strlen` when the source has a known max length.
- `docs/architecture/004-cyrius-string-literal-lifetime.md` — invariant note covering the program-lifetime guarantee, the 256 KB ceiling, and the don't-confuse-this-with cases (`argv`, `patra_result_get_str`).

### Audit closeout

With v0.6.3 the 2026-04-24 P(-1) audit is fully resolved at every severity level except the one explicit deferral:

- **CRITICAL** (S-01 through S-08): closed in v0.6.0.
- **HIGH** (S-09 through S-15): closed in v0.6.0.
- **MEDIUM** (S-16, S-17, S-18, S-19, S-20, S-22, S-23, S-25, S-27): closed in v0.6.2.
- **MEDIUM** (S-24): deferred to v0.6.x — folds into the patra-handle-caching refactor's `read_object` rewrite to avoid touching the same function twice.
- **MEDIUM** (S-26): closed in v0.6.0 (`refname_valid` shipped with the validator suite).
- **LOW** (S-28, S-29, S-30, S-31, S-32): closed in v0.6.3 (S-29 + S-30 closed in v0.6.0 via ADRs 0003/0004; the rest in this release).
- **CRITICAL** (S-33, post-audit benchmark finding): closed in v0.6.1 via dep bumps (cyrius 5.6.35 + sankoch 2.0.3).

Next release scope shifts to the v0.6.x performance arc: cache the patra object-DB handle, fold in S-24, ship measurable wins on `sit log` / `sit fsck` / `sit clone` against the v0.6.1 baseline.

## [0.6.2] — 2026-04-25

Security-hygiene MEDIUM batch from the 2026-04-24 P(-1) audit. Defense-in-depth — closes silent-failure / underflow / overflow / partial-state cliffs across the validator, signing, materialize, clone, commit, and merge paths. Behavioral change: `sit clone <url> <abs-path>` now requires `--force-absolute` (S-23); see migration note below.

### Security

- **S-16** — Filesystem-mutation return values now checked at every audit-flagged site. `sys_unlink(".sit/MERGE_HEAD")` failure during `cmd_commit` (post-merge) and `cmd_merge --abort` aborts cleanly with a clear error instead of silently leaving a stale MERGE_HEAD that turns the next commit into an unintended 2-parent merge. `write_remote_tracking` failure during `do_fetch` aborts the fetch instead of declaring success on a partial state. `materialize_target`'s `sys_unlink` and `file_write_all` failures now stop the materialize and report the offending path. Owl tempfile cleanup failures emit a stderr warning (best-effort, leak-only).
- **S-17** — New `alloc_or_die(size)` helper in `src/util.cyr` that prints `sit: out of memory` and exits 1 on alloc failure. 52 `alloc()` call sites across `src/object_db.cyr`, `src/tree.cyr`, `src/commit.cyr`, `src/merge.cyr` swapped from bare `alloc()` to `alloc_or_die()`. The few existing propagation-path callers (`read_file_heap`, `read_object`'s `dec_cap` path, `lcs_diff` DP table) keep their explicit null-checks; everywhere else, OOM is now loud-fatal instead of a `memcpy(0 + offset, …)` segfault.
- **S-18** — `parse_author_line` timestamp parser caps digit count at 19 and detects per-multiply overflow (`new < old` after `ts * 10 + (c - 48)`). A crafted commit with a 20+ digit timestamp, or a 19-digit timestamp that wraps i64, now returns `0 - 1` cleanly instead of silently storing a wrapped value.
- **S-19** — `extract_sitsig` adds an explicit `if (body_len < 201) return 0;` guard at function entry. The inner `body_len - 201` underflow was previously not reachable on real commit bodies but the guard locks in the invariant against future changes.
- **S-20** — sitsig hex parse now gates on `hex_is_valid(...)` BEFORE calling `hex_decode(...)` for both the signature (128 hex chars → 64 bytes) and pubkey (64 → 32). Belt-and-suspenders against any future loosening of `hex_decode`'s "all-or-fail" contract.
- **S-22** — `index_migrate_from_plaintext` caps per-line path length at 4096 bytes. A malformed legacy index with a multi-megabyte single-line `plen` is now rejected at parse instead of forcing a single huge `alloc()` on migration.
- **S-23** — `cmd_clone` refuses absolute target paths unless `--force-absolute` is passed. `sit clone <url> /etc/passwd` no longer silently `mkdir`s + `chdir`s into a system path the invoking user has perms for. Relative targets and URL-derived basenames continue to work unchanged.
- **S-25** — Deleted `src/util.cyr:ensure_dirs_for` (latent `mkdir("")` bug for absolute paths); both call sites in `src/merge.cyr` (`write_conflict_file` + the merged-files writer) now use `ensure_parent_dirs`. Behavior identical for relative paths; absolute paths no longer trip the latent bug.
- **S-27** — `materialize_target` aborts with a clear stderr error on the first `read_blob_content` failure instead of silently producing a partial working tree. The error names both the unreadable hash and the path it would have landed at.

### Changed

- `sit clone <url> <abs-path>` now requires `--force-absolute`. **Migration**: any script that clones into an absolute path needs the flag added (e.g. `sit clone "$URL" "$DIR"` → `sit clone --force-absolute "$URL" "$DIR"` when `$DIR` starts with `/`). The flag can appear anywhere in the argv. CI smoke (`.github/workflows/ci.yml`) and `scripts/benchmark.sh` updated; `docs/guides/getting-started.md` documents the new shape.

### Deferred

- **S-24** (Patra-handle + SQL-string leaks; `read_object` single-exit refactor) deferred to v0.6.x along with the patra-handle-caching refactor. Doing the single-exit refactor now would mean rewriting `read_object` twice in two consecutive releases — the v0.6.x arc adds a `read_object_with_db(db, hex, out)` variant and threads the cached handle through every caller, which subsumes the single-exit cleanup. Bump-allocator pressure from un-freed SQL strings is bounded by process lifetime and not a real exposure today.

## [0.6.1] — 2026-04-25

S-33 fix release. Pure dep-pin bumps — no sit source changes. Status, fsck, and clone now run cleanly on the 100-commit / 100-file fixture; the previously-disabled `bench_status` and `bench_clone` rows are re-enabled in `scripts/benchmark.sh`.

### Fixed

- **S-33** — `sit status` SIGSEGV on a 100-commit / 100-file repo. Triage surfaced two stacked upstream bugs: a cyrius stdlib `alloc` grow-by-1MB undersize that crashed any single allocation > 1 MiB (caused the SIGSEGV via `read_object`'s 16 MiB retry buffer), and a sankoch `zlib_compress` / `zlib_decompress` asymmetry that lost ~20% of objects on the same fixture (caused `read_object` to fall into the retry path in the first place). Independence proven by re-running the fixture across the cyrius bump alone — bit-for-bit identical bad-object set. Fixed by:
  - **sankoch 2.0.1 → 2.0.3** — write/read symmetry restored. After the bump, fsck reports 300/300 objects readable on the fixture (was 247/300 with 53 unreadable). The sankoch fix alone removes the trigger for the cyrius bug in sit's hot path.
  - **cyrius 5.6.25 → 5.6.35** — picks up the upstream allocator grow fix that landed in 5.6.34. Defense-in-depth for any future sit code that allocates > 1 MiB in a single call.
  - Full triage and resolution narrative in [`docs/development/issues/archived/2026-04-24-cyrius-stdlib-alloc-grow-undersize.md`](docs/development/issues/archived/2026-04-24-cyrius-stdlib-alloc-grow-undersize.md) and [`docs/development/issues/archived/2026-04-24-read-object-unreadable-at-scale.md`](docs/development/issues/archived/2026-04-24-read-object-unreadable-at-scale.md).

### Changed

- `cyrius.cyml` — cyrius `5.6.25` → `5.6.35`, sankoch `2.0.1` → `2.0.3`. No other dep movement.
- `scripts/benchmark.sh` — `bench_status` and `bench_clone` rows re-enabled and producing real numbers.

### Added

- `docs/development/issues/` — new directory for upstream-bug writeups against deps. README sets the `YYYY-MM-DD-{dep}-{slug}.md` filename convention and the lifecycle (resolved issues move to `archived/` with a `— RESOLVED` suffix; filename stable across the move). Two issues filed and immediately archived as RESOLVED in this release: the cyrius alloc-grow bug and the sankoch object-roundtrip bug.
- `docs/benchmarks/2026-04-25-v0.6.1.md` — first benchmark snapshot that includes `status-100files` and `clone-100commits` rows alongside the post-audit baseline.

### Inherited from late v0.6.0 / v0.6.1 dev cycle

(Items added between the v0.6.0 release and v0.6.1, previously listed under `[Unreleased]`.)

- `scripts/benchmark.sh` — reproducible git-vs-sit bench harness. Produces a markdown table of min + median wall-clock times over 10–15 runs per operation. Updates `docs/development/benchmarks-git-v-sit.md`.
- Five new benches in `tests/sit.bcyr`: `patra-open-close`, `copy-objects-100`, `commit-parse+iso8601`, `ed25519-sign` / `ed25519-verify`, validator throughput (`refname_valid`, `tree_entry_name_valid`, `tree_flat_path_valid`, `hex_prefix_valid`). All land in the single bench binary.
- `docs/benchmarks/2026-04-24-v0.6.0.md` — snapshot of post-audit numbers for comparison against future work.

## [0.6.0] — 2026-04-24

Security hardening release. All CRITICAL + HIGH findings from the 2026-04-24 P(-1) audit ([`docs/audit/2026-04-24-audit.md`](docs/audit/2026-04-24-audit.md)) are fixed. Network transport work (originally planned for 0.6.0) moves to v0.7.0.

### Security

- **S-01** — `hex_prefix_valid` gate in `resolve_hash` rejects any non-hex character before interpolation into `LIKE '<prefix>%'`. Closes SQL-injection via `sit cat-file "abc' OR 1=1 --"`.
- **S-02 / S-26** — `refname_valid` enforces the full [`git check-ref-format`](https://git-scm.com/docs/git-check-ref-format) grammar. Wired into `cmd_branch`, `cmd_tag` create, `cmd_checkout -b`, `cmd_remote_add`, and `write_remote_tracking` (fetch-receive side). A malicious remote advertising a branch named `../../../etc/cron.d/x` can no longer poison `.sit/refs/remotes/`.
- **S-03** — `tree_entry_name_valid` + `tree_flat_path_valid` + `tree_entry_mode_valid` gate tree objects at two boundaries. `parse_tree` drops invalid entries inline; `materialize_target` second-gates flattened paths before `file_write_all` / `sys_unlink` / `ensure_parent_dirs`. Mode allowlist accepts only `100644` and `40000`. Closes the CVE-2018-11235 / CVE-2019-1352 / CVE-2024-32002 shape for `sit clone` of a malicious repo.
- **S-04** — Local-clone symlink guards via `path_is_symlink` (newfstatat with `AT_SYMLINK_NOFOLLOW`). `remote_objects_open` refuses if `<repo>/.sit` or `<repo>/.sit/objects.patra` is a symlink. `read_remote_ref` refuses symlinked ref files. `cmd_clone` refuses to clone into an existing symlink target. Closes the CVE-2023-22490 shape.
- **S-05** — `config_value_valid` + `config_key_valid` reject `\n`, `\r`, `\0`, control chars, and oversized values in `config_file_set`. Closes the CVE-2023-29007 / CVE-2025-48384 config-line-injection primitive.
- **S-06** — File-size caps: `sit add` refuses files >1 GiB (prevents `sit add /dev/zero` OOM); `read_file_heap` refuses >64 MiB (config/ref files stay sane).
- **S-07** — LCS dimensions pre-checked against `sqrt(cap)` before multiplying, preventing `cells = (n1+1) * (n2+1)` integer overflow that would bypass the existing 16M-cell cap and under-allocate the DP table.
- **S-08** — Decompression caps tightened from 256× to 16× with a single retry at the 16 MiB ceiling. Applies to `read_object`, `db_object_read_decompressed`, and the loose-file migration path. Reduces the per-object memory footprint of attacker-controlled decompression by 16×.
- **S-09** — Owl path resolution honors `$SIT_OWL` env var before the hard-coded fallbacks (`/usr/local/bin/owl` → `/usr/bin/owl` → `/opt/owl/bin/owl`).
- **S-10** — `sit owl-file` tempfiles land in `$XDG_RUNTIME_DIR` (or `$HOME/.cache/sit/` fallback), opened with `O_CREAT | O_EXCL | O_WRONLY` + mode 0600. Closes the /tmp symlink-plant TOCTOU and the world-readable info-leak.
- **S-11** — Every ref-file reader (`resolve_ref_name` tag/head/remote paths, `read_head_ref`, `read_remote_ref`) validates the first 64 bytes are hex before returning. Corrupt or hostile ref files are treated as "no such ref" instead of flowing garbage downstream.
- **S-12** — `cmd_key_generate` opens `~/.sit/signing_key` with `O_EXCL` and pre-checks `path_is_symlink`. Closes the TOCTOU where another local user could symlink-plant between the `file_exists` check and the open.
- **S-13** — `write_remote_tracking` sizes staging buffers from actual remote/branch name lengths instead of a fixed 128 bytes. Closes a long-remote-name heap overflow.
- **S-14** — Recursion depth capped at 256 for both `flatten_tree` (local) and `walk_reachable_tree` (remote). Closes stack-overflow DoS on crafted object sets with deep subtree nesting.
- **S-15** — `glob_match` pattern length capped at 256 bytes. Closes the O(2^N) recursion DoS via crafted `.sitignore` patterns.
- **S-21** — Author identity bytes sanitized before writing to stdout via a new `write_sanitized` helper in util.cyr. Control chars (`< 0x20` except tab) and `\x7f` replaced with `?`. Closes the terminal-escape / log-line-forgery vector.

### Added

- **`src/validate.cyr`** — new module housing all input validators. Pure functions, no side effects. Callers decide error messages and disposition.
  - `hex_prefix_valid`, `refname_valid`, `tree_entry_name_valid`, `tree_flat_path_valid`, `tree_entry_mode_valid`, `config_value_valid`, `config_key_valid`, `remote_url_valid`
  - `path_is_symlink`, `path_lstat_kind` — `newfstatat`-based primitives for symlink / file-type checks without follow.
- **`src/util.cyr`** grew `write_sanitized(fd, bytes, len)` for the S-21 output escape filter.
- **Test coverage**: `tests/sit.tcyr` grew 70 new assertions across six `test_validate_*` functions — positive + negative cases for every validator. **101 total assertions**, up from 31.
- **ADR 0003** — sit does not search upward for `.sit/` (locks in correct behavior against CVE-2022-24765 class).
- **ADR 0004** — sit is SHA-256 only (no SHA-1 interop, even for legacy-repo imports).
- **ADR 0005** — Local-clone threat model (what sit trusts and doesn't, and which validator enforces which boundary).

### Changed

- `src/commit.cyr` lint cleanup (consecutive blank-line warnings from the v0.5.1 refactor).
- `config_file_set` return code `-2` now means "invalid input" (`cmd_config` surfaces this as a specific error message instead of the generic "failed to write config").

### Removed / deprecated

- Nothing user-facing. Implementation detail: the `write_remote_tracking` fixed-size `alloc(128)` is gone.

### Deferred to future releases

- **MEDIUM findings S-16–S-27** (filesystem mutation return checks, alloc null-checks everywhere, author-timestamp overflow guards, cleanup sweep) — v0.6.1 patch.
- **LOW findings S-28–S-32** (env scrubbing, patra cstring defense-in-depth, mode-literal lifetime audit) — v0.6.x as convenient.
- **Performance findings P-01 through P-25** — separate perf-focused minor after the security baseline bakes. The DB-handle caching refactor alone collapses 5 of the top-10 findings.

## [0.5.1] — 2026-04-24

File-split refactor. No feature changes, no bug fixes beyond what the split itself surfaced.

### Changed

- Split the monolithic `src/main.cyr` (~5700 lines) into 11 topical Cyrius modules chained through `src/lib.cyr`. `main.cyr` is now 112 lines — purely `print_usage`, `main()`, dispatch, and the exit trailer. Follows the yukti / patra include-chain pattern.
- New layout:
  - `src/util.cyr` (172) — `SEEK_SET/END`, `eprintln`, `ensure_dir`, `ensure_parent_dirs`, `ensure_dirs_for`, `write_decimal`, `argv_heap`, `skip_ws`, `strcmp_cstr`, `sort_cstrings`, `read_file_heap`
  - `src/config.cyr` (332) — `config_parse_value`, `config_file_get` / `set` / `list` / `unset`, `config_get`, `cmd_config`
  - `src/object_db.cyr` (488) — `object_path`, `resolve_hash`, `read_object`, `write_typed_object`, `write_blob_object`, `type_code_of`, `object_db_open`, `object_db_migrate_from_loose`, `resolve_and_read`, `find_owl`, `hash_blob_of_content`, `hash_file_as_blob`, `cmd_cat_file`, `cmd_owl_file`, `cmd_fsck`
  - `src/index.cyr` (594) — `index_db_open`, `index_migrate_from_plaintext`, `parse_index`, `rewrite_index`, `index_upsert`, entry accessors, `sort_entries`, `dedupe_entries`, `glob_match`, `is_ignored`, `load_sitignore`, `index_find`, `cmd_add`, `cmd_rm`, `cmd_reset`
  - `src/refs.cyr` (550) — `resolve_ref_name`, `read_head_ref_path`, `read_head_ref`, `write_head_ref`, `set_head_ref`, `current_branch_name`, `cmd_branch`, `cmd_checkout`, `cmd_tag`
  - `src/tree.cyr` (310) — `tlvl_*`, `build_tree`, `tree_entry_*`, `parse_tree`, `flatten_tree`, `read_head_tree_entries`, `tree_find`, `tree_find_hash`, `three_way_path_set`
  - `src/diff.cyr` (1060) — `is_dirty`, `split_lines`, `lines_equal`, `lcs_diff`, `annotate_ops`, `group_hunks`, `hunk_ranges`, `print_hunk_header`, `print_file_diff`, `print_file_stat`, `read_blob_content`, working-tree walker, status helpers, `cmd_diff`, `cmd_show`, `cmd_status`
  - `src/commit.cyr` (595) — `build_commit*`, `is_ancestor`, `materialize_target`, `parse_author_line`, `print_indented_message`, `parse_commit_body`, `print_commit_header` / `oneline`, `commit_tree_entries`, `cmd_commit`, `cmd_log`
  - `src/merge.cyr` (682) — `extract_hunks`, overlap detection, `three_way_line_merge`, MERGE_HEAD IO, `write_conflict_file`, `find_merge_base`, `build_merge_commit*`, `cmd_merge`
  - `src/sign.cyr` (310) — key path helpers, `load_signing_seed` / `pubkey`, `sign_commit_body`, `extract_sitsig`, `verify_commit_body`, `cmd_key` / `cmd_verify_commit`
  - `src/wire.cyr` (749) — remote config, `db_*` parameterized readers, reachability walkers, `copy_objects`, remote-ref IO, `is_ancestor_in_db`, `do_fetch`, all wire commands (`remote`, `fetch`, `pull`, `push`, `clone`)
- `src/lib.cyr` is the include chain. Cyrius does two-pass compilation, so include order is just logical grouping (primitives → storage → refs → objects → commands).

### Notes

- `cyrius.cyml [build].entry` stays pointed at `src/main.cyr`.
- Stdlib continues to auto-resolve via `cyrius.cyml [deps].stdlib` — no explicit `include "lib/*.cyr"` in the module files.
- Function names unchanged; no rename drift in this cut.
- 31 tests pass; local-vcs-loop walkthrough clean; full clone → push → re-clone round-trip clean.

## [0.5.0] — 2026-04-24

Wire protocol cut — local-path transport. Remotes, fetch, and push ship against other sit working-tree directories; HTTP / SSH transports and pack bundles remain v0.6.x+ work.

### Added

- **`sit remote add <name> <url>` / `list` / `remove <name>`** — named remotes recorded as `remote.<name>.url = <path>` entries in `.sit/config`. URLs accept bare paths (`/abs/path`) and `file://` scheme; any other scheme is treated as a path for v0.5.0. No validation that the remote is a real sit repo at config-write time — the error surfaces at fetch/push.
- **`sit fetch <remote> [<branch>]`** — opens the remote's `.sit/objects.patra` directly via patra; BFS-walks reachability from the remote's ref (commits → trees → subtrees → blobs); copies any object missing from the local DB as raw compressed bytes (no decompress/recompress); writes `.sit/refs/remotes/<remote>/<branch>` with the fetched tip. Defaults `<branch>` to `main`.
- **`sit push <remote> [<ref>]`** — symmetric direction: local → remote. Includes a fast-forward check (walks parent chain from local tip in the local DB looking for the remote's current tip; rejects if not found). Updates the remote's `.sit/refs/heads/<branch>` on success. Defaults `<ref>` to the current branch.
- **`sit pull <remote> [<branch>]`** — fetch + fast-forward merge. On divergence, prints an explicit message pointing at `sit merge <remote>/<branch>` rather than attempting an automatic 3-way; keeps the semantics narrow and predictable.
- **`sit clone <url> [<dir>]`** — `mkdir` + `chdir` + inline `init` + `remote add origin` + `fetch` + `write_head_ref` + `materialize`. Derives target directory from the URL's last path segment when `<dir>` is omitted; refuses to clone into a non-empty directory.
- **`sit merge -S <branch>`** — signed merge commits. Routes through the existing `build_merge_commit_signed` with the local signing seed (same ed25519 / sitsig format as `sit commit -S`).
- **Nested branch / tag refs** — `sit branch feature/foo`, `sit checkout -b feature/foo`, and `sit tag rel/v1` now auto-create the nested `.sit/refs/heads/feature/` (and tag) parent directories. Driven by a new `ensure_parent_dirs(path)` helper called from `write_head_ref`, `cmd_branch` create, `cmd_checkout -b`, and `cmd_tag` create paths.
- **`origin/main` ref resolution** — `resolve_ref_name` now consults `.sit/refs/remotes/<path>` in addition to heads and tags, so `sit merge origin/main`, `sit show origin/main`, `sit log origin/main` etc. work against remote-tracking refs directly.
- **New helpers**: `remote_url`, `remote_normalize`, `remote_objects_open`, `db_object_has` / `db_object_read_raw` / `db_object_read_decompressed` / `db_object_insert_raw` (parameterized-by-db variants of the existing object functions so the same walker runs against any sit repo), `walk_reachable_from_commit` / `walk_reachable_tree` (BFS reachability), `copy_objects` (dedup-on-write), `read_remote_ref` / `write_remote_ref` / `write_remote_tracking` (filesystem ref IO against another repo's `.sit/refs/heads/`), `is_ancestor_in_db` (ff-check primitive), `do_fetch(name, branch)` (shared core of fetch/pull/clone), `ensure_parent_dirs` (nested-ref mkdir).
- **Dispatch**: five new top-level commands — `remote`, `fetch`, `pull`, `push`, `clone`. Command count: **24**.

### Fixed

- CHANGELOG and roadmap for 0.4.0 over-claimed wire protocol support — all five commands are now actually implemented in 0.5.0.
- `sit branch feature/foo` / `sit checkout -b feature/foo` / `sit tag rel/v1` previously failed with "failed to write ref" because nested directories weren't created. Now work correctly.

### Notes

- **Local-path only.** `file://` and bare absolute paths. No TCP, no HTTP, no SSH in this cut; those are the motivating v0.6.x work items.
- **Naive object-at-a-time copy.** No pack bundles, no delta compression. Fine for small-to-medium repos; pack format will land alongside HTTP transport so the network round-trips aren't dominated by per-object chatter.
- **Fast-forward-only pull.** Divergence bails with an explicit pointer at `sit merge`. This matches `git pull --ff-only`, which most people use anyway, and avoids surprising auto-merges.

## [0.4.0] — 2026-04-24

First official release. Rolls up the entire pre-release development arc (scaffold → full local VCS loop → signed commits → wire protocol) into a single tagged artifact.

### Added

- **Core loop** — `sit init`, `sit add`, `sit commit`, `sit log`, `sit status`, `sit diff`, `sit show`, `sit cat-file`, `sit owl-file`. Commit objects are git-SHA-256-compatible; the `"blob <len>\0<content>"`, `tree`, and `commit` framings hash byte-for-byte against git's SHA-256 format for identical content.
- **Recursive trees** — `build_tree` walks sorted index entries, groups by path segment, and emits subtree objects. Root tree carries `40000` dir entries and `100644` file entries. `flatten_tree` + `read_head_tree_entries` produce full-path views for `status` / `diff`.
- **Staging index** — patra-backed at `.sit/index.patra`, single `entries(path STR, hash_hex STR)` table. Upsert-at-write semantics via `index_upsert`. Legacy plaintext `.sit/index` auto-migrates.
- **Object store** — patra-backed at `.sit/objects.patra`, `objects(hash STR, ty INT, content BYTES)`. SHA-256 via sigil, zlib via sankoch. Prefix lookup uses `WHERE hash LIKE 'abcd%'`. Legacy loose-file `.sit/objects/<xx>/<yy...>` layout auto-migrates on first access.
- **Branches and tags** — `sit branch [-d] [<name>]`, `sit checkout [-b] <branch>`, `sit tag [-d] [<name> [<commit>]]`. HEAD-aware so `log` / `status` / `diff` follow whatever branch is currently checked out. Tag reads resolve via `ref_resolve` alongside branch refs and hex prefixes.
- **Config** — `sit config [--global] <key> [<value>]`, `--list`, `--unset`. Flat `key = value` format at `.sit/config` (local) or `~/.sitconfig` (global). Author identity chain: `SIT_AUTHOR_NAME` env → local config → global config → `"sit user"` fallback (matches git's env precedence).
- **Integrity** — `sit fsck` decompresses every stored object and re-hashes it against the filename/key; reports bad / unreadable objects with exit 1 on any mismatch.
- **`.sitignore`** — gitignore-style pattern file at the repo root. Segment-matched `*` / `?` globs (no `**` / negation / char-classes yet). `sit add <ignored>` errors out without `-f`.
- **Remove / reset** — `sit rm [--cached] <path>` (working tree + index or just index), `sit reset <path>` (unstage: rewrite index entry to HEAD's hash), `sit reset --hard <ref>` (move current branch ref + materialize).
- **Merge** — `sit merge <branch>`. Fast-forward when possible; otherwise 3-way with line-level diff3. Non-overlapping hunks auto-merge; overlapping edits fall back to `<<<<<<<` / `=======` / `>>>>>>>` markers + `.sit/MERGE_HEAD` for manual resolution. `sit merge --abort` cancels and restores HEAD. Follow-on `sit commit` emits a 2-parent commit.
- **Signed commits** — ed25519 via sigil. `sit key generate` writes `~/.sit/signing_key` (32B seed hex, 0600) + `~/.sit/signing_key.pub` (32B pubkey, 0644). `sit commit -S` injects a `sitsig <sig-hex> <pub-hex>\n` line between `committer` and the blank separator; signed payload is the body *without* the sitsig line (self-consistent like git's `gpgsig`). `sit verify-commit [<hash>]` is the explicit check; `sit show` / `sit log` auto-decorate with `Signature: good|BAD (key <hex12>)`. No GPG, no OpenPGP armor.
- **Diffstat** — `sit show --stat`: per-file `path | +N -M` with git-style singular/plural summary.
- **Wire protocol** — `sit remote add/list/remove`, `sit fetch <remote>`, `sit push <remote> [<ref>]` across local-path remotes (file:// and bare paths). Reachability walk + naive object-at-a-time copy; pack bundles and network transports (HTTP, SSH) deferred to v0.5.x.
- **Reads with polish** — `sit cat-file` (plumbing, raw bytes) and `sit owl-file` (decorated via [owl](https://github.com/MacCracken/owl), falling back to raw content when owl isn't on PATH). Both accept 4-char-minimum hash prefixes.
- **Tests** — 31 assertions across sigil SHA-256 known-answers, git-SHA-256 blob framing, hex encode/decode, sankoch zlib roundtrip, patra COL_BYTES small + 16KB overflow, and ed25519 sign/verify roundtrip (including bit-flip negative cases for both message and signature).

### Dependencies

- Cyrius toolchain 5.6.25 (pinned in `cyrius.cyml`; scalar-clobber fix landed in 5.6.24, ed25519 primitives confirmed stable in 5.6.25)
- sakshi 2.1.0, sankoch 2.0.1, sigil 2.9.1, patra 1.6.0 (all git-tag pinned)

### Notes

- **First-party only** — no libgit2, no C, no FFI. See [ADR 0001](docs/adr/0001-no-ffi-first-party-only.md).
- **Git format compatibility** — object framing + tree format are byte-compatible with git's SHA-256 mode, but sit is *not* a drop-in for a git repo (the wire protocol is sit-native, signed commits use sit's `sitsig` header rather than git's `gpgsig`).
- **Not on the AGNOS critical path** — post-boot, when-there's-time project.

[Unreleased]: https://github.com/MacCracken/sit/compare/0.6.0...HEAD
[0.6.0]: https://github.com/MacCracken/sit/releases/tag/0.6.0
[0.5.1]: https://github.com/MacCracken/sit/releases/tag/0.5.1
[0.5.0]: https://github.com/MacCracken/sit/releases/tag/0.5.0
[0.4.0]: https://github.com/MacCracken/sit/releases/tag/0.4.0
