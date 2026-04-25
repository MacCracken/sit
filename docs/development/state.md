# sit — Live State Snapshot

> Volatile state for this project. Refreshed every release. Do not inline this content into `CLAUDE.md` or `README.md` — they're durable rules only.
>
> Historical release narrative lives in [`CHANGELOG.md`](../../CHANGELOG.md). This file is a point-in-time snapshot.

## Current

- **Version**: 0.6.12 (read `VERSION` for the authoritative number)
- **Cyrius toolchain**: 5.6.43 (pinned in `cyrius.cyml [package].cyrius`)
- **Binary**: 710 KB statically-linked, no dynamic dependencies
- **Status**: v0.6.x perf arc shipped 13 releases (v0.6.0 through v0.6.12). Cumulative wall-clock vs v0.6.0 baseline: `add-1MB -48%`, `add-64KB -43%`, `clone -30%`, `log -17%`, `status -9%`; other ops within run-to-run noise. Sit-side perf has plateaued; remaining headline-mover bottlenecks are dep-side (sankoch zlib throughput on small/large inputs, patra per-insert overhead) and filed on those repos' roadmaps. Two negative-result investigations during the arc (v0.6.10 BATCH mode, v0.6.11 multi-insert txn wraps) confirmed where sit-side perf hits diminishing returns. Next ship target: **v0.7.0 network transport (HTTP/SSH)**
- **Primary target**: Linux x86_64. aarch64 cross-build is best-effort in CI

### Architecture call-outs (carried across v0.6.x)

- **Patra handle caching**: `get_object_db()` (object_db.cyr) and `get_index_db()` (index.cyr) memoize per-process. `object_db_open()` / `index_db_open()` still exported for the wire-protocol callers that need an explicit fresh handle for the remote-side DB (every fetch/push targets a different file)
- **Wire transactions**: `copy_objects` (src/wire.cyr) wraps the insert loop in `patra_begin` / `patra_commit` since v0.6.5. `db_object_insert_raw` returns `1` for already-existed and `0` for actually-inserted (caller increments `copied` only on `== 0`)
- **Walk-reachable cache**: `walk_reachable_*` (src/wire.cyr) populates a `raw_cache` map of compressed bytes since v0.6.7; `copy_objects` reads from cache to skip the second source-DB read for commits + trees
- **Buffered stdout**: 206 sites in src/*.cyr route through `stdout_write(data, len)` in src/util.cyr since v0.6.8; flushed in main.cyr trailer before `SYS_EXIT`. STDERR (`eprintln`) stays direct
- **exec_vec envp**: empty (cyrius stdlib `lib/process.cyr` passes a NULL-only envp; no env-var inheritance in `cmd_owl_file`). Any future curated-envp shape would be a deliberate widening
- **patra BATCH mode (NOT enabled)**: investigated in v0.6.10 and reverted — durability regression with no perf gain on sit's bench shape (cached handle never closes, so pending writes would sit in the kernel writeback window). Reasoning at the `get_object_db` / `get_index_db` call sites; revisit when sit grows explicit `patra_flush()` at command exit

## Source layout

14 files total, 7013 lines (up from 13 files / 5972 lines in 0.5.1 — v0.6.0 added `validate.cyr`; v0.6.x perf + security work grew most modules).

| File | Lines | Responsibility |
|------|------:|----------------|
| `src/lib.cyr` | 19 | include chain (domain modules; stdlib auto-includes via `cyrius.cyml`) |
| `src/main.cyr` | 115 | `print_usage`, `main()`, dispatch, trailer (with `stdout_flush()` since v0.6.8) |
| `src/util.cyr` | 238 | `eprintln`, `ensure_dir`, `ensure_parent_dirs`, `alloc_or_die` (S-17, v0.6.2), `stdout_write`/`stdout_flush` (P-17, v0.6.8), `write_decimal`, `argv_heap`, `skip_ws`, `strcmp_cstr`, `sort_cstrings`, `read_file_heap`, `write_sanitized` (S-21) |
| `src/sign.cyr` | 331 | ed25519 signing + `cmd_key/verify-commit` (O_EXCL in 0.6.0; sitsig hex validation in v0.6.2) |
| `src/config.cyr` | 347 | `config_*` helpers + `cmd_config` |
| `src/tree.cyr` | 367 | `parse_tree`, `build_tree`, `flatten_tree` (depth-capped); hashmap-backed `tree_find` + `three_way_path_set` (P-10/P-18 since v0.6.6) |
| `src/validate.cyr` | 429 | **NEW in 0.6.0.** Pure validators: `hex_prefix_valid`, `refname_valid`, `tree_entry_name_valid`, `tree_flat_path_valid`, `tree_entry_mode_valid`, `config_value_valid`, `config_key_valid`, `remote_url_valid`, `path_is_symlink`, `path_lstat_kind` |
| `src/refs.cyr` | 578 | HEAD/branch/tag/resolve + `cmd_branch/checkout/tag` (ref-name + hex validation in 0.6.0) |
| `src/object_db.cyr` | 602 | patra object store with `_object_db_cached` handle (v0.6.4); `resolve_hash`, `read_object`, framing + compression with v0.6.9 4× initial multiplier; `cat-file` / `owl-file` / `fsck` |
| `src/index.cyr` | 634 | staging index + `.sitignore` + `cmd_add/rm/reset`; `_index_db_cached` (v0.6.4); `parse_index` `ORDER BY path` (P-20, v0.6.11) |
| `src/commit.cyr` | 658 | builders, parsers, `cmd_commit/log` (author sanitization + integer-overflow guards in v0.6.0/0.6.2) |
| `src/merge.cyr` | 694 | 3-way merge, conflict markers, `cmd_merge` (FS-mutation return checks in v0.6.2) |
| `src/wire.cyr` | 931 | remote config, reachability (depth-capped); `cmd_remote/fetch/pull/push/clone` with `--force-absolute` gate (S-23) + walk-cache (P-04, v0.6.7) + batched transactions (P-03, v0.6.5) |
| `src/diff.cyr` | 1070 | LCS (DP table via fl_alloc since v0.6.9), hunks, working walker + `cmd_diff/show/status` |

## Commands shipped

**24 total.** `init`, `add`, `rm`, `branch`, `checkout`, `tag`, `merge` (`-S`), `reset`, `commit` (`-S`), `config`, `fsck`, `key`, `verify-commit`, `remote`, `fetch`, `pull`, `push`, `clone`, `log`, `status`, `diff`, `show` (`--stat`), `cat-file`, `owl-file`.

## Tests

- **Unit**: `tests/sit.tcyr` — **101 assertions** (up from 31 in 0.5.x). Covers sigil SHA-256 known-answers, git-SHA-256 blob framing, hex encode/decode, sankoch zlib roundtrip, patra COL_BYTES small + 16KB overflow, ed25519 sign/verify roundtrip with bit-flip negatives, and the v0.6.0 validator suite: refname / tree-entry-name / tree-flat-path / hex-prefix / config-value / remote-URL positive + negative cases.
- **Integration**: shell-level via `docs/examples/local-vcs-loop/walkthrough.sh` and CI smoke steps (init → add → commit → log → fsck, signed commit + verify, clone → push → re-clone round trip; CI clone uses `--force-absolute` per S-23).
- **Benchmarks / fuzz**: `tests/sit.bcyr` (sigil + sankoch primitives), `tests/sit.fcyr` (random inputs through hash / zlib / hex_decode). Per-release `docs/benchmarks/2026-04-25-v0.6.X.md` snapshots capture before/after numbers and the "what didn't move and why" decomposition.

## Dependencies (current pins)

All git-tag pinned in `cyrius.cyml`. No FFI, no C, no libgit2 — see [ADR 0001](../adr/0001-no-ffi-first-party-only.md).

- **sakshi** 2.1.0 — tracing, error handling
- **sankoch** 2.1.0 — LZ4/DEFLATE/zlib/gzip. Bumped from 2.0.3 in v0.6.12 to pick up the DEFLATE micro-tuning down-payments from the throughput investigation filed during sit's v0.6.4 review. Standard zlib path moves modestly (~5-7% on compress, within noise on decompress); larger sankoch 2.x match-finder / ring-buffer / SIMD work queued
- **sigil** 2.9.3 — SHA-256 + ed25519 signing. Bumped from 2.9.1 in v0.6.12. **Picks up the SHA-NI hardware path** filed on sigil's roadmap during the v0.6.4 review. SHA-256 throughput went from ~12 MB/s software-only to ~400 MB/s on 64 KB inputs (32× factor). Drives the `sit add` headline wins
- **patra** 1.8.3 — B+ tree / WAL object store. Bumped from 1.6.0 in v0.6.10 to pick up `patra_result_get_str_len` (1.6.1 — closes S-31). 1.7.0 `INSERT OR IGNORE` is SQL-level only (filed informally for programmatic `patra_insert_row` flag). 1.8.x WAL group commit (`PATRA_SYNC_BATCH`) investigated; not enabled — durability regression for no perf gain on sit's bench shape

**Cyrius stdlib declared explicitly** in `cyrius.cyml [deps].stdlib` because 5.6.x has no transitive resolution (fix targeted for 5.7.0's `sandhi` stdlib crate). Current list: `string`, `fmt`, `alloc`, `io`, `vec`, `str`, `syscalls`, `assert`, `fs`, `args`, `chrono`, `hashmap`, `process`, `tagged`, `fnptr`, `thread`, `freelist`, `bigint`, `ct`, `keccak`, `bench`. Entries past `hashmap` exist for patra / sigil's transitive reach.

## Storage layout (sit repos on disk)

- **`.sit/HEAD`** — symbolic ref (`ref: refs/heads/main\n`)
- **`.sit/refs/heads/<name>`** — branch ref, 64-char hex + `\n`
- **`.sit/refs/tags/<name>`** — tag ref, same format
- **`.sit/refs/remotes/<remote>/<branch>`** — remote-tracking ref
- **`.sit/objects.patra`** — patra DB, schema `objects(hash STR, ty INT, content BYTES)`
- **`.sit/index.patra`** — staging index, schema `entries(path STR, hash_hex STR)`
- **`.sit/config`** — local config (`user.name`, `user.email`, `remote.<name>.url`)
- **`~/.sitconfig`** — global config (same format)
- **`~/.sit/signing_key`** (0600) / `~/.sit/signing_key.pub` (0644) — ed25519 seed + pubkey hex
- **`.sit/MERGE_HEAD`** — in-progress merge marker (cleared on commit or `--abort`)
- **Legacy**: `.sit/objects/<xx>/<yy...>` loose files and plaintext `.sit/index` auto-migrate on first access — see [arch 002](../architecture/002-loose-objects-until-patra-bytes.md)

## Recent shipped releases

| Version | Date | Summary |
|---------|------|---------|
| 0.6.12 | 2026-04-25 | **Biggest single-release win of the v0.6.x arc.** Pure dep bumps: cyrius 5.6.40 → 5.6.43, **sigil 2.9.1 → 2.9.3 (SHA-NI hardware path)**, sankoch 2.0.3 → 2.1.0. Sigil SHA-256 throughput 32× on 64 KB inputs (12 MB/s → ~400 MB/s). Cascades to **`add-64KB` -41%** (16.40 → 9.62 ms) and **`add-1MB` -48%** (211.52 → 112.39 ms). `status` -8%. No sit source changes. Bench snapshot at `docs/benchmarks/2026-04-25-v0.6.12.md`. |
| 0.6.11 | 2026-04-25 | P-20: `parse_index` query gains `ORDER BY path` so downstream `sort_entries` falls through O(N) on already-sorted input (was O(N²) insertion sort). ~50µs saved per call at 100 entries; scales to ~500ms at 10K. No 100-fixture bench movement. Multi-insert transaction wraps in `cmd_commit` and `rewrite_index` investigated and reverted — 5-10% regression on modern SSDs (per-txn setup overhead exceeds saved fsyncs at small batch sizes). Bench snapshot at `docs/benchmarks/2026-04-25-v0.6.11.md`. |
| 0.6.10 | 2026-04-25 | Dep bumps: cyrius 5.6.35 → 5.6.40, patra 1.6.0 → 1.8.3. Closes S-31 by adopting `patra_result_get_str_len` natively (removes sit's `strnlen(s, 256)` workaround). patra `PATRA_SYNC_BATCH` investigated and reverted (durability regression w/o perf gain; reasoning documented at the call sites). No bench movement. Bench snapshot at `docs/benchmarks/2026-04-25-v0.6.10.md`. |
| 0.6.9 | 2026-04-25 | P-06 + P-15. Decompression: initial multiplier 16× → 4× across read_object / migrate / db_object_read_both; retry only on confirmed `-ERR_BUFFER_TOO_SMALL`. LCS: DP table via `fl_alloc` + `fl_free` (mmap-backed, returns to kernel post-diff instead of squatting on bump heap). Both hygiene; no synthetic-bench movement. **Closes the sit-side v0.6.x perf arc.** Final cumulative 0.6.0 → 0.6.9: `log` -18%, `clone` -30%. Bench snapshot at `docs/benchmarks/2026-04-25-v0.6.9.md`. |
| 0.6.8 | 2026-04-25 | P-17: buffered stdout. 206 direct `syscall(SYS_WRITE, STDOUT, ...)` sites across 9 src files swapped to a single buffered `stdout_write(data, len)` helper backed by a 64KB heap buffer. `main.cyr` trailer flushes before `SYS_EXIT`. STDERR stays direct. `write_sanitized` rewritten to batch a sanitized copy through `stdout_write` (was 1 syscall/char + buffer bypass). Caught and fixed an output-ordering bug along the way (`print_commit_header` was emitting author bytes before the "Author: " prefix). No 100-file bench movement (fixture too small); structural benefit + visible win at scale (1000+ line diffs). Bench snapshot at `docs/benchmarks/2026-04-25-v0.6.8.md`. |
| 0.6.7 | 2026-04-25 | P-04: walk-reachable now captures the compressed bytes it pulled (via new `db_object_read_both` helper) and shares them with `copy_objects` via a `raw_cache` map. Commits + trees no longer re-read from source — 500 SQL ops on the 100-commit fixture drop to 300. **`sit clone-100commits` −21.7%** (215.27 → 168.53 ms; 13.64x git → 11.08x git). Bench snapshot at `docs/benchmarks/2026-04-25-v0.6.7.md`. |
| 0.6.6 | 2026-04-25 | P-10 + P-18: `tree_find` lazily builds a name → entry hashmap (cached by entries-vec pointer) instead of O(N) linear scan; `three_way_path_set` uses `map_has` for dedup instead of nested O(N²) streqs. No measurable improvement on the 100-file synthetic bench — too small to show — but algorithmic complexity dropped from O(N²) to O(N) on the hot paths. Real win at 1000+ files (cmd_status projected ~5ms → ~0.3ms at 1000 files). Bench snapshot at `docs/benchmarks/2026-04-25-v0.6.6.md`. |
| 0.6.5 | 2026-04-25 | P-03: `copy_objects` batched into a single `patra_begin`/`patra_commit` transaction; redundant outer `db_object_has` dropped (was paying for 2 SELECTs per object, now 1); `db_object_insert_raw` return convention extended to distinguish "newly inserted" from "already present" so the wire-side `copied` counter is accurate. **`sit clone` -15%** (245 → 208 ms; 16.13x git → 13.82x git). Bench snapshot at `docs/benchmarks/2026-04-25-v0.6.5.md`. Bigger clone wins still gated on patra-side group-commit + UPSERT (filed on patra's roadmap). |
| 0.6.4 | 2026-04-25 | First v0.6.x perf release. Process-wide patra-handle caching for `.sit/objects.patra` + `.sit/index.patra` (P-01/02/05/08/12/25). S-24 fold-in: SQL-string allocs in object_db swapped to `fl_alloc`/`fl_free`; read_object's single-exit shape fell out for free. `sit log` -17% on a 100-commit walk; status / clone unchanged (bottlenecks are downstream). Bench snapshot at `docs/benchmarks/2026-04-25-v0.6.4.md`. |
| 0.6.3 | 2026-04-25 | LOW-severity batch + audit closeout. `strnlen` added to util.cyr; `parse_index`'s `patra_result_get_str` walk now bounded at 256 (S-31). S-28 confirmed already addressed by stdlib's empty-envp `exec_vec`. S-32 documented as a Cyrius compile-time invariant in `docs/architecture/004-*.md` (Cyrius string literals are program-lifetime; tree.cyr's mode-pointer pattern is safe). 2026-04-24 P(-1) audit fully closed; only S-24 deferred (folds into v0.6.x patra-cache refactor). |
| 0.6.2 | 2026-04-25 | Security hygiene MEDIUM batch from the 2026-04-24 audit. `alloc_or_die` helper + 52-site swap (S-17). Materialize / merge / commit / clone now fail loudly on FS-mutation errors instead of silently producing partial state (S-16, S-27). Author-line + sitsig parsers hardened against integer overflow + partial hex decode (S-18, S-19, S-20). `cmd_clone` requires `--force-absolute` for absolute targets (S-23). Index-migrate caps per-line path length at 4096 (S-22). Latent `ensure_dirs_for` mkdir("") bug removed (S-25). |
| 0.6.1 | 2026-04-25 | S-33 fix release. Pure dep-pin bumps — sankoch 2.0.1 → 2.0.3 (zlib symmetry) + cyrius 5.6.25 → 5.6.35 (allocator grow defense-in-depth). Status / fsck / clone clean on 100-commit / 100-file fixture. `bench_status` + `bench_clone` re-enabled. New `docs/development/issues/` for upstream-bug writeups. |
| 0.6.0 | 2026-04-24 | Security hardening: all CRITICAL + HIGH findings from the 2026-04-24 P(-1) audit fixed. `validate.cyr` with every input validator. Tree-entry / refname / hex / config / URL gating. Symlink guards on clone paths. Output escape filter. 101 assertions (from 31). 3 new ADRs. |
| 0.5.1 | 2026-04-24 | File-split refactor: `src/main.cyr` → 11 topical modules via `src/lib.cyr`. Zero feature changes. |
| 0.5.0 | 2026-04-24 | Wire protocol (local-path): `remote`, `fetch`, `pull`, `push`, `clone` + nested branch names + `sit merge -S` + `resolve_ref_name` sees `refs/remotes/*`. |
| 0.4.0 | 2026-04-24 | First official release. Rolls up the entire pre-release development arc (scaffold → local VCS → signed commits) into a single tagged artifact. |

Full history in [`CHANGELOG.md`](../../CHANGELOG.md). Forward-looking items in [`roadmap.md`](roadmap.md).

## Consumers / integration

- **owl** (pre-1.0, downstream) — consumes sit for git-marker gutter decorations once both ship. sit's `owl-file` command falls back to raw content when owl isn't on PATH.

## Known footguns (tracked)

See [roadmap.md § Longer horizon](roadmap.md#longer-horizon) for the full list. Highlights:

- **Push to checked-out branch** — sit silently advances the remote's ref while leaving its working tree stale. Git rejects this by default (`receive.denyCurrentBranch=refuse`); sit should follow suit.
- **`sit fsck` reachability** — only checks integrity today, not reachability (no dangling-object detection).
- **Gitignore semantics incomplete** — no negation (`!pattern`), no `**`, no char classes.
