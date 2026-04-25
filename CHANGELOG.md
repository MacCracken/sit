# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
