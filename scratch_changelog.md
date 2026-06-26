# Changelog

All notable changes to Patra will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.12.4] - 2026-06-23

**Windows syscall-ABI correctness — WAL getrandom.** Completes the 1.12.2
flock / fdatasync / getrandom sweep for the one target it missed: **Windows**.
`_wal_gen_salts` drew its CSPRNG salts via a raw `syscall(SYS_GETRANDOM, …)`.
That resolves on Linux / aarch64 / macos / agnos (their syscall peers define the
`SYS_GETRANDOM` constant), but **Windows has no raw getrandom syscall** — its peer
deliberately omits the constant and routes randomness through
`bcryptprimitives.dll!ProcessPrng` via the `sys_getrandom()` wrapper. So
`cyrius build --win` failed to link with `undefined variable 'SYS_GETRANDOM'`.
Source-only; Linux / macos / aarch64 / agnos behavior byte-identical (834 tests
pass), and `cyrius build --win` now links the WAL path.

### Fixed

- **`src/wal.cyr` — `_wal_gen_salts` getrandom acquisition under `#ifdef CYRIUS_TARGET_WIN`.**
  Windows now calls the portable `sys_getrandom(buf, len, flags)` wrapper
  (→ `ProcessPrng`, returns `len` on success); every other target keeps the raw
  `syscall(SYS_GETRANDOM, …)` with its peer-supplied constant (never a hardcoded
  number). The stale "ABI-correct on every target" comment that assumed a raw
  getrandom syscall exists everywhere is corrected. Mirrors the existing
  `#ifdef CYRIUS_TARGET_AGNOS` guard on the time-fallback path.

## [1.12.3] - 2026-06-21

**AGNOS syscall-ABI correctness — WAL salt timestamp.** Follow-up to 1.12.2's
flock / fdatasync / getrandom sweep: the WAL salt-fallback path still issued a
raw `syscall(201)` (Linux `time()`), which mis-dispatches on the AGNOS ring-3
target (no #201). Source-only; Linux / macos / aarch64 behavior byte-identical.

### Fixed

- **`src/wal.cyr` — `_wal_gen_salts` time fallback under `#ifdef CYRIUS_TARGET_AGNOS`.**
  When `getrandom` is unavailable the WAL salt mixes in wall-clock seconds; this
  used Linux `time()` #201, not an agnos syscall. agnos now reads `time_unix` #46
  (unix seconds in rax, same ABI shape) from the syscall peer; Linux keeps #201.
  The last raw Linux syscall number in patra's agnos-reachable path is now gone.

## [1.12.2] - 2026-06-20

**AGNOS syscall-ABI correctness — flock / fdatasync / getrandom.** patra's
seek-based storage (WAL + B-tree files) hardcoded Linux x86_64 syscall numbers
that are wrong on the AGNOS ring-3 target, so `cyrius build --agnos` either
shadowed the syscall peer with conflicting values or trapped at runtime.
Source-only; Linux/macos/aarch64 behavior byte-identical.

### Fixed

- **`src/file.cyr` — `flock`/`fdatasync` under `#ifdef CYRIUS_TARGET_AGNOS`.**
  On agnos `flock` is kernel #59 and `lseek` #58 — both supplied by the cyrius
  syscall peer (`SYS_FLOCK` / `SYS_LSEEK`), so patra no longer redefines them on
  agnos (a redefinition shadowed the peer with a duplicate symbol). agnos has no
  per-fd `fdatasync`; durability maps to whole-FS `sync` #12. Linux/macos keep
  `SYS_FLOCK` #73 / `SYS_FDATASYNC` #75.
- **`src/wal.cyr` — removed the hardcoded `SYS_GETRANDOM = 318`.** #318 is the
  Linux x86_64 number; it collided with the agnos peer's #45 (last-def-wins →
  trap on agnos) and was redundant on Linux. `SYS_GETRANDOM` now comes from the
  syscall peer on every target (Linux #318, aarch64 #278, macos #318, agnos #45).

### Changed

- **VERSION `1.12.1` → `1.12.2`.**

## [1.12.1] - 2026-06-19

**Dependency-refresh patch — cyrius pin `6.2.22` → `6.2.28`, sakshi `2.2.3` →
`2.4.0`.** Source-change-free: patra carves out no stdlib modules, and the
sakshi bump (two minors, additive `sakshi_log_kv` — patra still calls only
`sakshi_error` / `sakshi_set_level`) introduces no API break. The cyrius bump
clears the build-time pin-drift warning against the installed toolchain.

### Changed

- **cyrius toolchain pin `6.2.22` → `6.2.28`** (`cyrius.cyml [package].cyrius`).
  Latest released 6.2.x. Build, 834 tests, 7 fuzz, 38 benchmarks, libro/vidya
  integration, lint, and the `dist/patra.cyr` regen all green on the new pin.
- **sakshi dep `2.2.3` → `2.4.0`** (`cyrius.cyml [deps.sakshi].tag`; README
  consumer-replication block bumped in lockstep). 2.4.0 is additive
  (`sakshi_log_kv` context-pair logging); patra's `sakshi_error` /
  `sakshi_set_level` call sites are unchanged. Consumers vendoring
  `dist/patra.cyr` must bump their replicated `[deps.sakshi]` tag to match.

### Notes

- **Binary size 243,728 → 279,456 bytes** (DCE demo, `programs/demo.cyr`,
  x86_64). The +35,728 is entirely cyrius codegen drift across the 6.2.22 →
  6.2.28 toolchain span — zero patra source changed (the `dist/patra.cyr` diff
  is the one-line version header). Measured on the host's installed 6.2.29
  (one patch ahead of the 6.2.28 pin); CI/release builds against 6.2.28. Under
  cyrius 6.2.x, DCE and non-DCE remain byte-identical (NOP-in-place; 373
  unreachable fns / 70,312 bytes NOPed).
- **agnos cross-target ABI** (`docs/development/issues/2026-06-18-agnos-cross-target-abi.md`)
  reviewed this cut — patra's random-access page engine has no agnos-native
  positional-I/O path (no `lseek`/`pread`/`flock`). Left open pending an
  architecture decision by the owner (mmap-backed backend vs. kernel
  positional-I/O ask vs. defer-and-guard); no code change in 1.12.1.

## [1.12.0] - 2026-06-18

**Concurrent readers (yeo-cy-test P2) + opt-in shared page cache + cyrius pin
`6.2.21` → `6.2.22`.** SELECTs now run in parallel across threads instead of
serializing on the process-global statement lock. The win is **~3.6×** read
throughput on a 4-thread scan (`read_scan_4t_serial` 514 µs → `read_scan_4t_par`
143 µs/scan). Reads are lock-free; writers stay serialized (single-writer). The
model is **connection-per-thread**: each worker opens its own handle over one
file, and the existing per-fd `flock` (shared for readers, exclusive for
writers) arbitrates across handles and processes — leveraging the OS page cache
for shared caching for free. The old shared-single-handle model still works
(just without read parallelism), so existing consumers need no change.

A shared in-process page cache also ships, but **OFF by default** — see Added.

### Added

- **Concurrent `SELECT`s (P2).** `patra_query` / `patra_query_prepared` no
  longer take the statement mutex. Each reader thread runs on its own handle
  (own fd + header). Made safe by moving the SQL parse scratch and the page-slab
  allocator into thread-local storage (`lib/thread_local.cyr`) and serializing
  the freelist behind an allocator mutex. `patra_init` now installs the calling
  thread's TLS block; worker threads spawned via `lib/thread.cyr` inherit one
  free (foreign threads must call `thread_local_init` once). **Migration for
  read parallelism:** open one handle per worker thread instead of sharing one.
- **`patra_cache_enable(on)` / `patra_cache_enabled()`** — opt-in shared page
  cache (process-global; one cache across all handles). **Default OFF.** It is
  redundant with the OS page cache for RAM-resident data and its global lock
  re-serializes the concurrent readers, so it is a net loss on warm workloads
  (measured ~3× slower on tmpfs: `read_scan_4t_cached` ~475 µs vs the 143 µs
  default). Enable it only for **cold / slow-disk read-heavy** workloads where
  avoiding real I/O beats the lock cost. Coherence (when enabled): Variant I
  invalidate-on-write (`page_write` evicts) for same-process, plus a header
  commit-generation gate for cross-handle / cross-process. The 4 MB pool is
  allocated lazily on first enable, so default-off consumers pay nothing.
- **`HDR_COMMITGEN`** — a monotonic commit-generation counter in the header's
  formerly-reserved byte 32. Bumped on every committed mutation; the page cache
  compares it to detect another handle's/process's writes. **No format break**:
  old and new files read 0 there, `PATRA_VER` stays 1, old/new binaries
  interoperate.

### Changed

- **cyrius toolchain pin `6.2.21` → `6.2.22`.** Clears the build-time pin-drift
  warning; source-change-free for the toolchain itself.

### Known limitations

- **BYTES/TEXT result-set reads under concurrent writers.** A result set stores
  BYTES/TEXT columns as a `(page, len)` reference materialized lazily by
  `patra_result_read_bytes` / `patra_result_read_text` *after* the query's read
  lock releases. A concurrent writer that frees+reuses those chain pages can make
  the lazy read return stale/foreign bytes — a **pre-existing** TOCTOU (not
  introduced or worsened by this release). Read a result set's BYTES/TEXT values
  before yielding to a writer that may delete those rows, or serialize. Eager
  materialization is deferred until a consumer needs it.

### Gates

- **834 tests** (+22: read-concurrency stress on per-thread handles,
  cross-handle visibility, commit-generation, page-cache unit + coherence),
  **7 fuzz** (+1: `fuzz_pcache` shadow-model invariant check), 38 benchmarks
  (+2: `read_scan_4t_par` 143 µs / `read_scan_4t_cached` 475 µs; no regression
  on the default path — `insert_1k` ~21 µs), libro 15/15, vidya 19/19, lint
  clean. New module `src/pcache.cyr`. `dist/patra.cyr` regenerated.

## [1.11.5] - 2026-06-18

**Atomic insert-returning-id (yeo-cy-test) + cyrius pin `6.2.19` → `6.2.21`.**
Closes the readback race the consumer flagged after adopting the v1.11.3
write-readback API. `patra_exec_prepared` + `patra_last_insert_id` are two
ops: under a lock-free worker pool sharing one handle, a concurrent INSERT can
land between them and overwrite `DB_LAST_ID`, so the echo can return another
worker's id (same hazard for `rows_affected` after a concurrent UPDATE /
DELETE). The stored rows were always uniquely id'd — only the readback raced —
but it was a real correctness hazard by inspection. The fix captures the field
*inside* the same statement-mutex critical section as the write. Additive, no
format change, no public-API break.

### Added

- **`patra_insert_returning(db, stmt, out_id)`** — execute a prepared INSERT
  and atomically read back its assigned `AUTOINCREMENT` id (auto or explicit)
  into `out_id` (a writable i64 cell; pass `0` to ignore). Returns the exec
  status. The id mirrors `patra_last_insert_id` exactly — a non-AUTOINCREMENT
  INSERT leaves it at the prior value, so the call is only meaningful on an
  AUTOINCREMENT target. Race-free replacement for `patra_exec_prepared` +
  `patra_last_insert_id` when concurrent writers share a handle.
- **`patra_exec_returning(db, stmt, out_affected)`** — execute a prepared
  INSERT / UPDATE / DELETE and atomically read back its affected-row count into
  `out_affected` (pass `0` to ignore). The race-free pairing of
  `patra_rows_affected` for concurrent UPDATE / DELETE under a shared handle.
  On a non-`PATRA_OK` status both APIs write `0` to the out-param (no stale
  value leaks).

### Changed

- **cyrius toolchain pin `6.2.19` → `6.2.21`.** Clears the build-time
  pin-drift warning against the installed toolchain; source-change-free for the
  toolchain itself (build, tests, fuzz, benchmarks, libro/vidya integration all
  green either way).

### Gates

- **795 tests** (+23: `insert_returning`, `insert_returning OR IGNORE`,
  `exec_returning`), 6 fuzz, 36 benchmarks (no regression — `insert_1k`
  ~21 µs, `insert_1k_prepared` ~15.3 µs), libro 15/15, vidya 19/19, lint clean.
  `dist/patra.cyr` regenerated.

## [1.11.4] - 2026-06-17

**Thread-safety mutex migrated to stdlib `lib/sync.cyr`.** The process-global
statement lock (`_patra_mtx`) now uses the cyrius stdlib's portable mutex
instead of patra's hand-rolled inline futex. Behavior is unchanged on patra's
Linux targets — the stdlib Linux backend is the same `atomic_cas` +
`FUTEX_WAIT`/`WAKE` 2-state scheme patra had vendored — but patra now gets the
per-OS backends (Windows `SRWLOCK`, macOS spinlock) for free and drops a
maintenance burden. Closes the loop on the v1.11.0 workaround: patra filed the
"no portable stdlib mutex" gap during P1, cyrius 6.2.x shipped `lib/sync.cyr`
(its header cites patra's issue), and this release adopts it.

### Changed

- **`_patra_lock` / `_patra_unlock` now call `mutex_lock` / `mutex_unlock`** from
  `lib/sync.cyr`; `patra_init` allocates the lock via `mutex_new()` instead of
  `fl_alloc(8)`. The no-init / single-threaded no-op path (lock cell `0`) is
  unchanged. Adds `"sync"` to `[deps].stdlib` and `include "lib/sync.cyr"` to
  `src/lib.cyr` (after `atomic`, which `sync` depends on). The inline
  `atomic_cas` / `SYS_FUTEX` calls are gone from patra's source.

### Gates

- **772 tests** (incl. the `test_concurrency` 4×250 shared-handle stress —
  exact count, zero torn rows), 6 fuzz, 36 benchmarks (no regression —
  `insert_1k` ~21 µs, `insert_1k_prepared` ~14.6 µs), libro 15/15, vidya 19/19,
  lint clean. `dist/patra.cyr` regenerated.

## [1.11.3] - 2026-06-17

**Write-readback API (yeo-cy-test) + cyrius pin `6.2.1` → `6.2.19`.**
The yeo-cy-test probe (full-stack SecureYeoman slice) re-ran on patra 1.11.2
and confirmed thread-safety P1 holds in a real concurrent consumer (250
concurrent POSTs → 250 unique ids, no external lock). It filed two LOW
"what did that write do?" gaps that block adopting `AUTOINCREMENT` for the
common insert-then-echo REST shape. Both are closed here — additive, no
format change, no public-API break.

### Added

- **`patra_last_insert_id(db)`** — the `AUTOINCREMENT` id of the most recent
  successful `INSERT` on the handle (auto-assigned or explicitly supplied), à
  la `sqlite3_last_insert_rowid`. Returns 0 on a fresh handle, a null handle,
  or when the last INSERT targeted a table with no `AUTOINCREMENT` column. An
  ignored `INSERT OR IGNORE` does not advance it; `UPDATE` / `DELETE` leave it
  untouched. Lets consumers drop the app-side id counter and use
  `AUTOINCREMENT` for `201`-with-created-row handlers (the gap that kept
  yeo-cy-test on explicit app-assigned ids).
- **`patra_rows_affected(db)`** — rows matched by the most recent
  `INSERT` / `UPDATE` / `DELETE`, à la `sqlite3_changes`. A successful INSERT
  is 1; an ignored `INSERT OR IGNORE` is 0; `UPDATE` / `DELETE` report the
  WHERE-matched count. Lets a `PUT` / `DELETE` handler distinguish "updated"
  from "nothing there" without a pre-`SELECT` existence probe.
  Both readbacks are captured at the `_exec_insert` / `_exec_update` /
  `_exec_delete` choke points, so they cover `patra_exec`, prepared
  statements, and `patra_insert_row` alike. New handle fields `DB_LAST_ID` /
  `DB_ROWS_AFFECTED` (DB handle 48 → 64 bytes); `tbl_update` / `tbl_delete`
  surface their matched count via `_tbl_rows_affected`.

### Changed

- **cyrius pin `6.2.1` → `6.2.19`.** No source change required for the bump
  itself (clears the build-time pin-drift warning against the installed
  6.2.19 toolchain).

### Gates

- **772 tests** (+25: `last_insert_id`, `last_insert_id OR IGNORE`,
  `rows_affected`, `rows_affected OR IGNORE`), 6 fuzz, 36 benchmarks (no
  regression — `insert_1k` ~22 µs, `insert_1k_prepared` ~14.7 µs, the
  readback `store64`s within noise), libro 15/15, vidya 19/19, lint clean.
  `dist/patra.cyr` regenerated.

## [1.11.2] - 2026-06-14

**SQL-tokenizer enum namespaced (`TK_*` → `SQLT_*`) to clear a symbol
collision with co-linked tokenizers.** patra's internal SQL token enum
in `src/sql.cyr` used unprefixed `TK_*` constants (`TK_IDENT = 2`,
`TK_COUNT = 36`, …). When patra is co-linked into a binary that also
pulls a separate tokenizer exporting its own `TK_*` token-kind constants
(e.g. [vyakarana](https://github.com/MacCracken/vyakarana)'s
`TK_IDENT = 0` / `TK_COUNT = 10` palette), cyrius's flat symbol namespace
silently resolves both names to one definition — and unlike duplicate
`fn`s, an enum-member-vs-`var` collision is **not** warned. The foreign
values won, so inside patra's SQL parser `TK_IDENT` became `0`, aliasing
patra's own `TK_EOF = 0`: every SQL identifier tokenized as EOF and
`sql_parse()` failed on otherwise-valid queries (e.g.
`SELECT content FROM objects WHERE hash = '…'`), surfacing as
`patra_query` returning 0. Discovered downstream in owl 1.4.0
(`sit` library swap, where owl co-links vyakarana + sit→patra).

### Fixed

- **`enum TokType` members renamed `TK_*` → `SQLT_*`** (247 refs, confined
  to `src/sql.cyr` + the SQL test). Internal-only — no public API change
  (these constants were never part of patra's exported surface; consumers
  use `patra_query` / `patra_exec`, not the token enum). Any consumer
  co-linking patra with another `TK_*`-exporting library is now collision-
  free. Full `.tcyr` suite 747/747 green; `dist/patra.cyr` regenerated.

## [1.11.1] - 2026-06-12

**cyrius pin `6.1.15` → `6.2.1` (ecosystem-wide stdlib pin sweep).**

### Changed

- **cyrius pin → 6.2.1.** No source changes — patra's `[deps] stdlib` carries no
  carved-out modules, and its sole external dep (sakshi) is unaffected. Verified
  green on 6.2.1: `cyrius deps` resolves cleanly, full `.tcyr` suite 747/747,
  bench 1/1, `dist/patra.cyr` regenerated.

## [1.11.0] - 2026-06-09

**Thread-safety: shared handles are now safe (yeo-cy-test P1).** A patra
db handle can now be shared across threads — concurrent `patra_exec` /
`patra_query` / prepared-statement / `patra_insert_row` calls are
internally serialized and memory-safe. This removes the footgun that
forced yeo-cy-test's worker pool to wrap **every** patra call in an
external `g_db_lock`. Also bumps the cyrius toolchain pin 6.0.3 → 6.1.15.

### Fixed

- **P1 — concurrent same-handle access no longer corrupts state.** The
  SQL parse/exec path uses process-global scratch (`_sql_toks`,
  `_sql_pr` in `sql.cyr`) shared across **all** db handles in the
  process, so two threads parsing at once clobbered each other's tokens
  and parse result — even on different databases — silently corrupting
  writes or crashing. v1.11.0 adds a process-global futex mutex
  (`_patra_mtx`) that serializes every self-contained statement
  operation. Because the racing scratch is process-global, the lock is
  too: a per-DB lock would leave a two-handle data race. The guarantee:
  **concurrent same-handle (and cross-handle) statement calls are
  memory-safe and serializable** — the P1 minimum bar. Verified by a new
  4-thread / 1000-insert stress test (`test_concurrency`): exact row
  count, zero torn rows; with the lock disabled the same test corrupts
  the DB so the count query returns nothing.

### Added

- **`atomic` stdlib dependency** (`cyrius.cyml [deps].stdlib`) and
  `include "lib/atomic.cyr"` in `lib.cyr` — supplies `atomic_cas` /
  `atomic_store` / `atomic_fence` for the futex mutex fast path
  (`atomic_cas` 0→1 acquire, `FUTEX_WAIT`/`FUTEX_WAKE` under contention;
  the stdlib `thread.cyr` 2-state scheme). **Consumers vendoring
  `dist/patra.cyr` must add `"atomic"` to their own `[deps].stdlib`** —
  cyrius does not resolve transitive deps (same constraint as the
  `sakshi` block; see README § Dependencies).
- `test_concurrency` unit test (+4 assertions, 743 → 747) — the unit
  suite now includes `lib/thread.cyr` + `lib/mmap.cyr` to spawn real
  worker threads against a shared handle.

### Changed

- **cyrius toolchain pin 6.0.3 → 6.1.15.** Build, full test suite, fuzz,
  benchmarks, and the aarch64 cross-build of `src/lib.cyr` all clean on
  the new pin with no source changes required for the bump itself.
- `dist/patra.cyr` regenerated via `cyrius distlib` (5130 → 5215 lines;
  now carries the `_patra_mtx` mutex + `atomic_*` call sites).

### Thread-safety contract (documented)

- Each **auto-commit statement** call (`patra_exec`, `patra_query`,
  `patra_prepare`, `patra_exec_prepared`, `patra_query_prepared`,
  `patra_insert_row`) is internally locked and safe to call concurrently
  on a shared handle.
- **Explicit `patra_begin` … `patra_commit` spans are NOT internally
  serialized** — per-call locking cannot make a multi-call transaction
  atomic across threads. A caller mixing explicit transactions with
  concurrent access must serialize the transaction span itself (or keep
  transactions on one thread). `patra_begin` / `patra_commit` /
  `patra_rollback` are intentionally left unlocked.
- Result-set accessors operate on caller-owned result sets (no shared
  state) and need no lock.
- Reader/writer parallelism (concurrent `SELECT`s, per-DB locking) is
  **P2** — out of scope here; the single internal lock caps DB work at
  one operation at a time, which is fine for sub-millisecond ops.

### Verified (cyrius 6.1.15, x86_64)

- `cyrius test tests/tcyr/patra.tcyr`: **747 / 747** pass (+4 over
  v1.10.3 — the `test_concurrency` group: shared-handle open, count
  survives concurrent writers, all rows present / none lost, no corrupt
  rows).
- 6 / 6 fuzz harnesses clean.
- `cyrius bench tests/bcyr/patra.bcyr`: 36 benchmarks, **no regression**
  — mutex overhead is within measurement noise (`insert_1k_exec` 20 µs,
  `insert_1k_prepared` 14 µs; the uncontended `FUTEX_WAKE` on unlock is
  <2 % of a 20 µs insert and the kernel no-ops it when there are no
  waiters).
- Integration: libro 15 / 15, vidya 19 / 19. Lint clean (0 warnings
  across `src/` + `programs/`).
- aarch64 cross-build of `src/lib.cyr` clean (futex mutex + `atomic.cyr`
  carry aarch64 branches; `SYS_FUTEX` = 98 on arm64).
- DCE demo binary: 237,128 bytes (+5,696 over v1.10.3 — `atomic.cyr` +
  the mutex helpers and per-entry-point lock wrappers).

## [1.10.3] - 2026-05-27

**Bind parameters (yeo-cy-test HIGH) — closes the 1.10.x arc.** The final
and highest-impact yeo-cy-test blocker: `?` placeholders +
`patra_bind_int` / `patra_bind_text` close the SQL string-escaping hole.
All 5 yeo-cy-test blockers are now shipped; patra returns to a
no-queued-backlog state.

### Added

- **`?` placeholders + `patra_bind_int(stmt, idx, val)` /
  `patra_bind_text(stmt, idx, ptr, len)`** (sqlite3_bind_* shape). A `?`
  in an INSERT value, WHERE value, or UPDATE SET value is parsed to a
  bind slot; `patra_prepare` records the placeholder count, the
  `patra_bind_*` calls fill a per-statement bind area, and `_apply_binds`
  substitutes the concrete value into the restored parse result before
  exec — so every downstream path sees ordinary `COL_INT` / `COL_STR`
  values and needs no change. Bind buffers must stay valid until
  `patra_exec_prepared` / `patra_query_prepared` runs; binds can be
  re-set and the statement re-executed. Out-of-range bind index returns
  the new `PATRA_ERR_PARAM`.
- A bound text value flows into a `TEXT` column the same as into `STR`,
  so `INSERT INTO notes (body) VALUES (?)` + `patra_bind_text` stores
  arbitrary-size free text safely — **retiring the base64 stopgap** the
  SecureYeoman port was using.

### Security

- **SQL string-injection / escaping hole closed.** Previously the only
  way to store free text via `patra_exec` was to inline it as a `'…'`
  literal, and the tokenizer closes a literal at the first `'` with no
  `''` doubling or escapes — so a value containing a quote either
  truncated (`PATRA_ERR_SYNTAX`) or, crafted, injected SQL. Bound values
  are written to the row / compared as bytes and are never reparsed as
  SQL, so quotes and other metacharacters cannot escape the value.
  Regression-tested (`test_bind_text_quotes`, fuzz 170–172):
  `O'Brien'; DROP TABLE t--` bound as text stores verbatim, table intact.
- `patra_exec` / `patra_query` now reject a statement containing `?`
  (`PATRA_ERR_PARAM` / `0`) — placeholders require prepare + bind, so an
  unbound `COL_PARAM` can never reach a storage path.

### Changed

- `patra_bind_blob` (binary into BYTES via `?`) is intentionally **not**
  included — BYTES stays write/read-only via `patra_insert_row`. Deferred
  until a consumer needs SQL-driven binary writes.
- `dist/patra.cyr` regenerated via `cyrius distlib` (4986 → 5130 lines).

### Verified (cyrius 6.0.3, x86_64)

- `cyrius test tests/tcyr/patra.tcyr`: **743 / 743** pass (+32 over
  v1.10.2 — 8 bind-parameter groups incl. INSERT/WHERE/UPDATE binds,
  rebind+reuse, the injection regression, text-into-TEXT, and error
  paths).
- 6 / 6 fuzz harnesses clean; `fuzz_sql` gains 14 bind invariants (exit
  codes 160–173) incl. a quote-injection case.
- `cyrius bench tests/bcyr/patra.bcyr`: 36 benchmarks, no regression
  (`insert_1k` 19 µs, `insert_1k_prepared` 14 µs — `_apply_binds`
  no-ops for unparameterized statements).
- Integration: libro 15 / 15, vidya 19 / 19. Lint clean.
- DCE demo binary: 231,432 bytes (+3,504 over v1.10.2).

## [1.10.2] - 2026-05-27

**TEXT column type (yeo-cy-test MEDIUM).** Second patch of the 1.10.x
arc. Surfaces variable-length text to SQL, lifting the 256-byte `STR`
cap that blocked real document storage. Shipped as a patch to keep the
yeo-cy-test batch in the 1.10 line (precedent: 1.6.1, 1.7.1). With this
in, `base64 + TEXT` already stores arbitrary-size text via `patra_exec`;
1.10.3 (bind parameters) will retire the base64 stopgap entirely.

### Added

- **`TEXT` column type** — `CREATE TABLE t (body TEXT)` (and `ALTER TABLE
  … ADD COLUMN body TEXT`). A TEXT cell is written from a SQL string
  literal in `INSERT` / `UPDATE` and stored in the same chain-page infra
  as `COL_BYTES` (16-byte `(first_page, length)` row ref, payload spilled
  across `PAGE_BYTES` pages), so the fixed-width row layout is preserved.
  Read back with the new `patra_result_get_text_len(rs, row, col)` +
  `patra_result_read_text(db, rs, row, col, out)` accessors. Unlike the
  256-byte `STR` slot, TEXT has no length cap.
- Composes with `AUTOINCREMENT` (1.10.1) and column-list / positional
  INSERT, and with `INSERT OR IGNORE` (a TEXT chain written for a row
  that's then skipped on a dedup hit is reclaimed, not orphaned).

### Changed

- TEXT chains are freed on `DELETE`, `DROP TABLE`, and `ALTER TABLE …
  DROP COLUMN` — reusing the existing BYTES chain-cleanup paths via a new
  `_col_is_chain` predicate that both BYTES and TEXT answer to (keeps the
  size, cleanup, and guard switches in sync).
- `UPDATE … SET text_col = '…'` rewrites the cell: the old chain is freed
  and a new one written.
- **Constraints:** `WHERE` on a TEXT column never matches and `CREATE
  INDEX` on TEXT is rejected (`PATRA_ERR_TYPE`) — variable-length values
  aren't comparable / hashable (same contract as BYTES). `BYTES` stays
  binary and programmatic-only (`patra_insert_row`); the TEXT vs BYTES
  split mirrors SQLite's TEXT vs BLOB.
- `dist/patra.cyr` regenerated via `cyrius distlib` (4912 → 4986 lines).

### Verified (cyrius 6.0.3, x86_64)

- `cyrius test tests/tcyr/patra.tcyr`: **711 / 711** pass (+31 over
  v1.10.1 — 9 new TEXT groups incl. >256-byte, multipage, update,
  delete-frees-chain, WHERE/index rejection, ALTER ADD).
- 6 / 6 fuzz harnesses clean; `fuzz_sql` gains 10 TEXT invariants (exit
  codes 140–149).
- `cyrius bench tests/bcyr/patra.bcyr`: 36 benchmarks, no regression
  (`insert_1k` 20 µs, `bytes_insert_2kb` 26 µs unchanged).
- Integration: libro 15 / 15, vidya 19 / 19. Lint clean (now a hard CI
  gate — caught a 126-char `ColType` line during this cut, since split).
- DCE demo binary: 227,928 bytes (+1,648 over v1.10.1).

## [1.10.1] - 2026-05-27

**AUTOINCREMENT / rowid (yeo-cy-test LOW).** First patch of the 1.10.x arc
working the remaining yeo-cy-test blockers. Shipped as a patch (not a
minor) to keep the whole consumer-feedback batch in the 1.10 line —
consistent with patra precedent (1.6.1, 1.7.1 shipped features as
patches). Removes the hand-rolled id counter consumers seeded from
`SELECT id … ORDER BY id` at boot.

### Added

- **`AUTOINCREMENT` column modifier** — `CREATE TABLE t (id INT
  AUTOINCREMENT, …)`. When an INSERT omits the column (column-list form)
  or supplies `0` (positional), patra assigns the next id = current
  `max + 1` (`1` for an empty table); an explicit non-zero value is
  honored. INT-only, at most one per table (both rejected at parse with
  `PATRA_ERR_SYNTAX`). Composes with `OR IGNORE` (the auto id is computed
  before the dedup probe, so an auto id — always unique — never dedups;
  only explicit ids do). Deleting the highest row lets its id be reused
  (derive-from-MAX semantics, matching the consumer's prior `MAX(id)`
  pattern).

### Changed

- Schema page gains an additive `SCH_AUTOINC_COL` marker (offset 4072,
  stored as `col_idx + 1` so `0` = none). Backward-compatible: a zeroed
  old schema reads `0`, and an old patra opening a new autoinc DB just
  sees a normal INT column — no format break.
- `dist/patra.cyr` regenerated via `cyrius distlib` (4894 → 4912 lines).
- **CI/release modernization** (`.github/workflows/{ci,release}.yml`,
  patterned on sigil): the ~40-line manual cyrius tarball install is
  replaced by the upstream `install.sh` one-liner, still sourcing the
  version from the `cyrius.cyml` pin (no hardcoded version in YAML, per
  CLAUDE.md) and resolving deps via `cyrius deps`. CI `lint` is now a
  hard gate — any `warn` line fails the build (patra's `src/*.cyr` +
  `programs/*.cyr` lint clean, so no exemptions needed) — replacing the
  prior advisory `|| true`.

### Verified (cyrius 6.0.3, x86_64)

- `cyrius test tests/tcyr/patra.tcyr`: **680 / 680** pass (+28 over
  v1.10.0 — 5 new AUTOINCREMENT groups).
- 6 / 6 fuzz harnesses clean; `fuzz_sql` gains 13 AUTOINCREMENT
  invariants (exit codes 120–132) covering parse guards, sequential
  auto-assign, explicit/zero handling.
- `cyrius bench tests/bcyr/patra.bcyr`: 36 benchmarks, no regression —
  `insert_1k` 20 µs unchanged (the auto-assign branch is one load + test
  for non-autoinc tables).
- Integration: libro 15 / 15, vidya 19 / 19.
- DCE demo binary: 226,280 bytes (+1,216 over v1.10.0).

## [1.10.0] - 2026-05-27

**Consumer-driven feature release (yeo-cy-test).** Clears two of the
blockers the SecureYeoman → Cyrius port probe filed against patra
(2026-05-27): column-list INSERT (MEDIUM) and the sakshi transitive-dep
packaging gap (LOW). Toolchain pin moves 6.0.1 → 6.0.3 within the 6.0.x
line. The higher-impact yeo-cy-test items — bind parameters / SQL string
escaping (HIGH), TEXT/VARLEN columns (MEDIUM), rowid / AUTOINCREMENT
(LOW) — remain on the [roadmap](docs/development/roadmap.md) for a later
cut.

### Added

- **Column-list INSERT** — `INSERT INTO t (a, b) VALUES (…)`. Values bind
  to the named columns by name (any order); columns left unnamed take
  their zero/empty default. Plain positional `INSERT INTO t VALUES (…)`
  is unchanged. The value count must equal the named-column count
  (`PATRA_ERR_COLCOUNT` otherwise); an unknown column name is
  `PATRA_ERR_NOTFOUND`, a column named twice is `PATRA_ERR_SYNTAX`, and a
  value whose type mismatches its column is `PATRA_ERR_TYPE`. Composes
  with `OR IGNORE` and with prepared statements. Removes the positional
  brittleness yeo-cy-test hit porting SQLx/axum code that names columns.
  Parser carries the column-name list in the free tail of the 4096-byte
  parse-result buffer (`PR_INS_COLS` at 2824, past the WHERE region —
  INSERT never populates WHERE); exec resolves each name via
  `_wh_resolve_col` and binds into the row.

### Changed

- `cyrius` pin bumped 6.0.1 → 6.0.3 in `cyrius.cyml`. Patch bump within
  the 6.0.x line. 6.0.3 also heals the 6.0.1 `cyrius deps --lock`
  regression — `cyrius.lock` now serializes full content (81-byte stub →
  6595 bytes / 81 deps); the regenerated lock ships with this release.
- `dist/patra.cyr` regenerated via `cyrius distlib` (4785 → 4894 lines;
  the column-list parser/exec additions).

### Documentation

- README gains a **Dependencies** section documenting the sakshi
  transitive-dep requirement: cyrius does not resolve transitive deps, so
  a consumer declaring `[deps.patra]` must also declare `[deps.sakshi]`
  at patra's pinned tag or the link fails on undefined `sakshi_*`
  symbols. Mirrored as a maintainer note in `cyrius.cyml [deps.sakshi]`.
  The single-include `dist/patra.cyr` bundle carries the same
  requirement.
- README **SQL Supported** lists the column-list INSERT form and its
  bind/default semantics.

### Verified (cyrius 6.0.3, x86_64)

- `cyrius test tests/tcyr/patra.tcyr`: **652 / 652** pass (+32 over
  v1.9.5 — 6 new column-list INSERT test groups).
- 6 / 6 fuzz harnesses clean; `fuzz_sql` gains 20 column-list invariants
  (exit codes 100–119) covering malformed lists, valid named lists,
  reorder, omitted-column defaults, and the unknown/count error paths.
- `cyrius bench tests/bcyr/patra.bcyr`: 36 benchmarks complete; no
  regression vs the v1.9.5 baseline — the column-list branch adds zero
  overhead to positional INSERT (`parse_insert` 7 µs).
- Integration: libro 15 / 15, vidya 19 / 19.
- DCE demo binary: 225,064 bytes (60,606 NOPed) under `CYRIUS_DCE=1`.

## [1.9.5] - 2026-05-21

**Cyrius 6.0 toolchain bump.** Pins `cyrius` 5.11.4 → 6.0.1 —
patra's first major-version cyrius bump. Cyrius 6.0 renames the
named compiler (`cc5` → `cycc`, `cc5_aarch64` → `cycc_aarch64`)
and removes the legacy aliases on the release-asset path, but
patra's CI invokes the `cyrius` CLI wrapper (`cyrius build`,
`cyrius test`, `cyrius lint`, `cyrius distlib`) rather than the
named-compiler binary directly, so no workflow surgery was
required for the rename itself. Pattern-match against agnosys
(commits 4588938 + b1e9eca) — that repo's CI invokes
`cc5 --version` as a verify step and ships an aarch64
cross-build, so it had to migrate both call sites; patra's
narrower CI surface inherits the rename transparently.

### Changed

- `cyrius` pin bumped 5.11.4 → 6.0.1 in `cyrius.cyml`. Major
  bump driven by the `cc5` → `cycc` compiler-binary rename
  (Cyrius 6.0 release manifest). No language-level breakage
  surfaced in patra: lint clean (0 warnings on `src/lib.cyr`
  include graph), full test sweep green.
- `dist/patra.cyr` regenerated via `cyrius distlib` at v1.9.5
  (4785 lines, unchanged shape — bundle regen tracks the
  package.version stamp).

### Verified (cyrius 6.0.1, x86_64)

- `cyrius test tests/tcyr/patra.tcyr`: **620 / 620** pass.
- 6 / 6 fuzz harnesses clean (btree, bytes, file, jsonl, sql,
  wal); each ran to completion under the 10s CI timeout.
- `cyrius bench tests/bcyr/patra.bcyr`: 35 benchmarks complete;
  no regressions vs 1.9.4 baseline
  (btree_insert_1k 4µs, btree_search_1k 2µs,
  insert_500_sync_batch 81µs, insert_1k_prepared 14µs).
- `cyrius build programs/demo.cyr`: DCE-clean, 322 unreachable
  fns NOPed (59,889 bytes).
- libro integration: **15 / 15** asserts pass.
- vidya integration: **19 / 19** asserts pass.
- aarch64 cross-build of `src/lib.cyr`: produces a valid ARM
  aarch64 ELF (1262 unreachable fns NOPed) — confirms 1.9.1's
  aarch64 portability still holds under cyrius 6.0.

### Notes

- CI workflows (`.github/workflows/ci.yml`,
  `.github/workflows/release.yml`) are unchanged: patra's
  install path copies `$CYRIUS_DIR/bin/*` wholesale, so it
  picks up `cycc` automatically when present and continues to
  copy any legacy `cc5` binary if a transitional release ships
  both. No `cc5 --version` / `cc5_aarch64` references existed
  in patra to update — the only `cc5` mention in-tree is the
  historical-incident comment in `scripts/version-bump.sh`
  describing cyrius's own pre-5.6.39 drift, kept as context.

### Docs (same-day follow-up)

Conformance pass against the genesis [first-party-documentation.md](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/first-party-documentation.md) + [example_claude.md](https://github.com/MacCracken/agnosticos/blob/main/docs/development/planning/example_claude.md) standards:

- **`CLAUDE.md` refactored** to durable rules only. Stripped the
  inlined "Stable: 1.9.x — …" multi-version narrative block and
  the inlined version number; volatile state now lives in
  [`docs/development/state.md`](docs/development/state.md). Matches
  the cyrius / sit CLAUDE.md shape.
- **`docs/development/state.md` created** — live volatile state:
  current version, cyrius / sakshi pins, binary sizes
  (~224 KB demo, ~266 KB aarch64 `src/lib.cyr` cross-build),
  11-module source layout table, full 35-bench numbers under
  cyrius 6.0.1, dependency pins, consumers, recent-release table
  through 1.9.5, known footguns.
- **`docs/doc-health.md` created** — bucketed ledger (Fresh /
  Stale / Read-through / Evergreen / Archive / Open-question)
  covering all ~18 markdown files. Dedicated "Cyrius language
  usage across docs" drift table.
- **`docs/development/issues/archive/`** created. The
  `2026-04-30-cyrius-cyrfmt-cyrlint-buffer-truncation.md` issue
  moved there with an `ARCHIVED` header — **resolved upstream in
  cyrius 6.0.1**: internal buffer raised 131,072 → 524,288 bytes
  (4× bump), verified by feeding a 6,665,292-byte concatenated
  source to `cyrfmt` (output now caps at 524,289 bytes, not
  131,072). Patra's largest source file is 130,692 bytes after
  v1.9.2's ASCII pass — well under the new cap.
- **`docs/development/BENCHMARKS.md` re-baselined** under cyrius
  6.0.1. Full 35-bench sweep, two runs, medians taken. Re-baseline
  notes section calls out the deltas vs the prior 2026-04-24 /
  v1.8.1 / cyrius 5.6.39 table:
  - tmpfs-bound benches: flat-to-faster (0–10%) — compiler-side
    wins from cyrius 5.6.39 → 6.0.1
  - `select_where_1k`: ~22% faster (1.51 ms → 1.18 ms) — largest
    tmpfs improvement, from WHERE-evaluator codegen wins
  - `insert_500_sync_full`: 19.7 ms → 3.22 ms (~84%) and
    `insert_500_sync_batch`: 300 µs → 90 µs (~70%) — **hardware-
    class shift**, not a compiler/source claim. Disk-bound; the
    underlying NVMe is faster on this measurement host. The
    BATCH-vs-FULL speedup ratio recomputes from ~64× to ~36×;
    the absolute BATCH improvement is what consumers actually see
  - No regressions anywhere; `bytes_read_2kb` shifted 5 → 6 µs but
    that's within the 4–16 µs min/max noise range
- **`CONTRIBUTING.md`** — `cc2` (pre-`cc5`-era compiler reference)
  → `cyrius.cyml [package].cyrius` pointer; expanded with deps /
  fuzz / bench / process steps.
- **`docs/development/roadmap.md` + `completed-phases.md`** —
  rewritten through the 1.9.x line; previously stopped at 1.8.3 /
  1.6.0 respectively.
- **`docs/adr/README.md` + `docs/adr/template.md`** + **`docs/
  architecture/README.md`** created — ADR / architecture index +
  ADR-authoring template per the standard.

No source changes; CHANGELOG narrative and doc tree only.

## [1.9.4] - 2026-05-11

### Changed

- **Stdlib annotation pass**: every public fn in `src/*.cyr`
  carries a `: i64` return-type annotation. Mechanical pass
  matching cyrius's v5.11.x annotation arc; parse-only, zero
  runtime / codegen change.
- `cyrius` pin bumped 5.8.64 → 5.11.4 — required for `: i64`
  return-type syntax (v5.10.x REAL TYPE SYSTEM).
- `dist/patra.cyr` regenerated via `cyrius distlib` at v1.9.4.
  Ready for next cyrius-side fold-in slot.

### Verified

- `cyrius build src/lib.cyr build/patra`: green.

## [1.9.3] - 2026-05-05

### Changed

- `cyrius` pin bumped 5.7.48 → 5.8.64 ahead of the cyrius v5.8.65
  stdlib foldin. Patra is on the foldin manifest; this patch is
  the prerequisite for cyrius's `[deps].patra.tag` to point at
  1.9.3 in the foldin slot.
- `[deps.sakshi].tag` bumped 0.9.0 → 2.2.3 — closes a 1.3.0+
  version-of-sakshi gap (patra had been pinned to a very old
  sakshi). Modules path corrected at the same time:
  `"sakshi.cyr"` → `"dist/sakshi.cyr"` (the canonical convention
  used by every other dep manifest).
- No source changes beyond the manifest fixes. `dist/patra.cyr`
  rebuilt at 4785 lines.

### Verified

- `cyrius test`: **620 / 620** asserts pass against cyrius 5.8.64
  with sakshi 2.2.3 resolved.
- Manifest/module path now canonical; future bumps won't trip the
  resolver.

## [1.9.2] - 2026-04-30

**Lint / fmt clean surface — pre-existing pollution flushed.** 1.9.1
landed the toolchain bump and aarch64 unblock but flagged ~50
upstream-surfaced lint warnings + fmt drift on test/fuzz files as
"pre-existing pollution, not 1.9.1 introduced, not CI-blocking".
This patch closes those out so the surface lints + formats clean
end-to-end. Also extends the syscall-wrapper migration started in
1.9.1 to the remaining `SYS_CLOSE` / `SYS_READ` / `SYS_WRITE`
callers (no portability impact — those numbers are arch-stable —
but the `sys_*` wrapper form removes the per-call-site
`syscall arity mismatch` warnings that surfaced during aarch64
cross-build).

### Changed

- **Banner-comment unicode → ASCII** across `tests/tcyr/patra.tcyr`,
  `tests/bcyr/patra.bcyr`, and four fuzz harnesses. 1,558 occurrences
  of `─` (U+2500 BOX DRAWINGS LIGHT HORIZONTAL, 3 bytes UTF-8) →
  `-`, plus 39 `—` (em-dash) → `--` and 27 `→` (arrow) → `->`.
  Visual structure preserved; pure encoding swap.

  Two side effects this fixes:
  1. **38 `line exceeds 120 characters` lint warnings vanish.**
     `cyrlint` counts bytes, not characters, so a 60-char banner
     of `─`s was 180 bytes wide and tripped the 120-byte cap. Same
     issue across all 9 long-line warnings in `fuzz/*.fcyr`.
  2. **`tests/tcyr/patra.tcyr` falls under the 128 KB
     cyrfmt/cyrlint internal buffer cap** (134,107 → ~131,000
     bytes), eliminating the false-positive
     `unclosed braces at end of file` warning at line 3681 and the
     silent truncation that broke `cyrfmt --write` on this file.
     Root cause filed in
     `docs/development/issues/2026-04-30-cyrius-cyrfmt-cyrlint-buffer-truncation.md`
     — same shape as the v5.7.36 distlib 64 KB → 256 KB fix that
     should propagate to cyrfmt/cyrlint upstream.

- **Multi-blank-line cluster** at `tests/tcyr/patra.tcyr:1006-1009`
  collapsed (between the v0.11 SHA-256 and Transactions sections) —
  the only two `multiple consecutive blank lines` lint warnings.

- **Syscall wrapper migration extended — 27 sites across 5 modules**
  (continues 1.9.1's `sys_open`/`sys_unlink` migration):
  - `src/page.cyr` — 2 sites (`page_read`, `page_write` — both
    `sys_read`/`sys_write`).
  - `src/wal.cyr` — 13 sites (`wal_start` header write, `wal_log_page`
    read+write, `wal_commit` close, `_wal_hdr_verify` read,
    `wal_rollback` close+read+write+close, `wal_recover`
    close+read+write+close).
  - `src/file.cyr` — 4 sites (`patra_hdr_read` read, both write paths,
    `_pt_file_create` write+close).
  - `src/jsonl.cyr` — 5 sites (`jsonl_close`, `jsonl_append` write × 2,
    `jsonl_read` read, `jsonl_read_streaming` read).
  - `src/lib.cyr` — 3 sites (open-handle close paths).

  Pattern: `syscall(SYS_CLOSE, fd)` → `sys_close(fd)`,
  `syscall(SYS_READ, fd, buf, n)` → `sys_read(fd, buf, n)`,
  `syscall(SYS_WRITE, fd, buf, n)` → `sys_write(fd, buf, n)`.
  Pass-through on x86_64. Net effect on aarch64 cross-build:
  warning count down on cleanly-wrappable callers; the remaining
  direct callers (`SYS_LSEEK`, `SYS_FLOCK`, `SYS_FDATASYNC`,
  `SYS_GETRANDOM`, `syscall(201, …)` for `time(2)`) stay direct —
  no stdlib wrappers exist for those today, and their numbers are
  either arch-stable or arch-defined per-file.

### Fixed

- **`cyrfmt --write` no longer corrupts `tests/tcyr/patra.tcyr`.**
  The file is now under the 128 KB upstream tool buffer ceiling so
  fmt processes the full content. Previously
  `cyrfmt --write tests/tcyr/patra.tcyr` was a destructive operation
  (silent data loss — truncated mid-identifier near
  `test_like_underscor`, dropping `fn main()`'s closing brace and
  the `var r = main(); syscall(SYS_EXIT, r)` epilogue). See the
  upstream issue file referenced above.

### Added

- **`docs/development/issues/2026-04-30-cyrius-cyrfmt-cyrlint-buffer-truncation.md`**
  — root-cause writeup of the upstream cyrfmt/cyrlint 128 KB
  buffer limit. Includes a synthetic reproducer, byte-precise
  cause, suggested upstream fix (match v5.7.36 distlib's 64K→256K
  bump, or stream the input/output), and the pinned workaround
  applied here. To revisit when next cyrius bump lands.

### Verified

- Build clean on 5.7.48: `OK`, only the expected `dead: sakshi_error`
  unused-import report.
- 620/620 unit tests, 6/6 fuzz harnesses (btree, bytes, file,
  jsonl, sql, wal), libro integration 15/15, vidya integration
  19/19, demo runs cleanly.
- Lint sweep `0 warnings` across every `src/*.cyr`,
  `programs/*.cyr`, `tests/tcyr/*.tcyr`, `tests/bcyr/*.bcyr`,
  `fuzz/*.fcyr`. Fmt sweep `0 drift` across the same surface.
- aarch64 cross-build still produces a valid ARM aarch64 ELF
  (`CYRIUS_DCE=1 cyrius build --aarch64 src/lib.cyr build/patra-aarch64`
  → `ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV),
  statically linked, no section header`). Remaining `syscall arity
  mismatch` warnings are now confined to the unwrappable LSEEK /
  FLOCK / FDATASYNC / GETRANDOM / time callers.
- `dist/patra.cyr` regenerated (4785 lines, v1.9.2).
- Lockfile (sakshi 0.9.0) unchanged.

## [1.9.1] - 2026-04-30

**aarch64 portability + toolchain bump 5.7.8 → 5.7.48.** The
syscall surface migrates off raw `SYS_OPEN` / `SYS_UNLINK`
(absent from aarch64's syscall table — the kernel only has the
AT-variants on arm64) onto the stdlib's arch-translating
`sys_open(path, flags, mode)` / `sys_unlink(path)` wrappers.
`build/patra-aarch64` now produces a valid ARM aarch64 ELF;
unblocks downstream consumers that need to cross-compile
through patra (yukti's device manager, vidya, sit, libro).

### Changed

- **Toolchain pin bumped 5.7.8 → 5.7.48** (`cyrius.cyml`). 40
  patches across 35 days — the longest minor in cyrius history
  (v5.7.0 2026-03-26 → v5.7.48 2026-04-30 closeout backstop).
  The arc is mostly stdlib expansion (json pretty-print +
  streaming + RFC 6901 pointer in v5.7.40-5.7.42, regex engine
  in v5.7.18, JSON tagged-tree engine in v5.7.20, sandhi HTTP
  fold at v5.7.0, Landlock + getrandom syscall wrappers in
  v5.7.35) and aarch64 backend hardening (f64 basic ops in
  v5.7.30, codebuf cap raised in v5.7.34) — none of which patra
  exercises. Two latent language gotchas surface during the
  bump — both audited, neither requires a patra code change:
  - `var buf[N]` inside a function body is **static data**, not
    stack — consecutive calls share backing memory, so any
    `Str` or pointer aliasing into `buf` dangles on the next
    call. Patra has zero such sites in src/ — discipline note
    in CLAUDE.md ("Heap-allocate large buffers — `var
    buf[256000]` bloats binary by 256KB") was followed
    consistently. All buffers go through `pg_alloc()` /
    `fl_alloc()`.
  - 5.x stdlib lookup helpers (`toml_get`, `args_get`, etc.)
    take cstr keys, not `Str`. Patra rolls its own SQL parser /
    JSON tokenizer / B-tree and consumes none of the affected
    helpers — `[deps] stdlib` lists only `syscalls`, `string`,
    `alloc`, `freelist`, `io`, `fmt`, `str`, `vec`. Nothing to
    migrate.

  Notable 5.7.x additions patra doesn't currently exercise but
  worth flagging:
  - `cyrius smoke` / `cyrius soak` subcommands (v5.7.38) —
    natural fit for the alloc-pressure-heavy test surface.
  - `cyrius api-surface` (v5.7.33) — public-API diff gate;
    could formalize patra's stable surface for libro / vidya /
    sit / yukti / daimon.
  - `lib/security.cyr` Landlock + `lib/random.cyr` getrandom
    (v5.7.35) — useful for path-traversal hardening on
    `.patra` file open paths.
  - `lib/test.cyr` v1 with `test_each` table-driven dispatch
    (v5.7.43) — could compress the 620-assertion suite.

  Full gate verified on 5.7.48: build 0 warnings (modulo
  expected `dead:` reports from DCE), `cyrius lint` 0 warnings
  on every `src/*.cyr`, 620/620 unit tests pass, 6/6 fuzz
  harnesses pass (btree, bytes, file, jsonl, sql, wal),
  benchmarks running cleanly (1.8.x perf claims preserved:
  insert_1k_prepared 14µs, dedup_insert_or_ignore_500 14µs,
  insert_500_sync_batch 87µs), libro integration 15/15 pass,
  vidya integration 19/19 pass, demo runs cleanly. Lockfile
  unchanged (sakshi 0.9.0 tag didn't move).

- **Syscall wrapper migration — 9 sites across 3 modules**
  (the aarch64 unblock):
  - `src/jsonl.cyr:11` — `jsonl_open(path)` now uses
    `sys_open(path, 132162, 420)` (was raw
    `syscall(SYS_OPEN, …)`).
  - `src/file.cyr:178` — `_pt_file_create(path)` now uses
    `sys_open(path, 194 + O_NOFOLLOW, 420)`.
  - `src/file.cyr:191` — `_pt_file_open(path)` now uses
    `sys_open(path, 2 + O_NOFOLLOW, 0)`.
  - `src/wal.cyr:77` — `wal_start(...)` now uses
    `sys_open(wal_path, 578, 420)`.
  - `src/wal.cyr:204` — `wal_recover(...)` now uses
    `sys_open(wal_path, 0, 0)`.
  - `src/wal.cyr:149,177,197,227` — four `wal_*` cleanup
    paths now use `sys_unlink(wal_path)` (was raw
    `syscall(SYS_UNLINK, …)`).

  The wrappers are pass-through on x86_64 (same `SYS_OPEN = 2`
  / `SYS_UNLINK = 87` as before — no behavioral change) and
  dispatch through `SYS_OPENAT(AT_FDCWD, …)` /
  `SYS_UNLINKAT(AT_FDCWD, …)` on aarch64. Flag values are
  POSIX-stable across arches; the migration is purely
  call-site syntax. Verified:
  `CYRIUS_DCE=1 cyrius build --aarch64 src/lib.cyr
  build/patra-aarch64` → "ELF 64-bit LSB executable, ARM
  aarch64, version 1 (SYSV), statically linked, no section
  header". Nine `syscall arity mismatch` warnings remain on
  the *other* direct syscall callers (`SYS_FDATASYNC`,
  `SYS_LSEEK`, `SYS_READ`, `SYS_WRITE`, `SYS_CLOSE`,
  `SYS_FLOCK`) — those are arch-stable so no portability
  blocker, but a follow-on patch could migrate them to their
  matching `sys_*` wrappers for warning hygiene.

- `dist/patra.cyr` regenerated (4785 lines, v1.9.1). Generated
  code byte-identical to v1.9.0 modulo the version header and
  the 9 syscall call sites — semantic equivalence on x86_64
  preserved.

## [1.9.0] - 2026-04-26

**`json_build` → `patra_json_build` rename to clear stdlib
collision with `lib/json.cyr`.** Required by cyrius v5.7.9's
new duplicate-fn warning.

### Changed (BREAKING — minor bump)

- **`fn json_build(buf, max, keys, vals, types, n)` →
  `fn patra_json_build(buf, max, keys, vals, types, n)`** in
  `src/jsonl.cyr`. The fn name collided with
  `lib/json.cyr::json_build/1` (the general pairs-vec utility);
  consumers including both modules saw last-include-wins
  semantics with the losing arity silently miscompiling. Cyrius
  v5.7.9 now emits a `warning: duplicate fn` at registration
  time; this rename makes patra's variant unambiguous and matches
  the `patra_*` namespace prefix used elsewhere in patra
  (`patra_open`, `patra_close`, `patra_prepare`, etc.). Body and
  semantics unchanged.
- Test caller in `tests/tcyr/patra.tcyr::test_json_build`
  updated to call `patra_json_build`.
- Comment in `src/jsonl.cyr` referring to the buffer-size
  contract updated to use the new name.

### Migration

Consumers calling `json_build(buf, max, keys, vals, types, n)`
on a patra dep ≥ 1.9.0 must rename the call to
`patra_json_build(...)`. The 7-arg `json_build_lens(...)` is
unchanged and remains the recommended path for inputs that may
contain embedded NUL bytes.

### Compiler version

- Toolchain pin: cyrius v5.7.8 (the most-recent released cyrius
  as of this patra release). Cyrius v5.7.9 — when released —
  is the version where the duplicate-fn warning actually fires;
  this patra release does NOT require it. The pin moves to v5.7.9
  in the next patra patch after the cyrius v5.7.9 tarball is
  available on GitHub Releases. (Pinning ahead of an unreleased
  cyrius version is what tripped the v1.9.0 first-push CI: the
  installer 404'd on `cyrius-5.7.9-x86_64-linux.tar.gz`.)

## [1.8.3] - 2026-04-24

Release-prep pass: format, lint, doc summaries, regenerated dist bundle.

### Changed
- **`cyrius fmt`** applied to `src/btree.cyr` and `src/lib.cyr` —
  whitespace-only continuation-line reflow on three multi-line argument
  lists. No behavior change.
- **`cyrius lint`** clean across all 11 source files (was 1 warning;
  shortened two over-long section-header comments in `src/file.cyr`
  and `src/lib.cyr` that exceeded the 120-byte cap when counting the
  UTF-8 box-drawing chars).
- **`cyrius doc`** clean across all public APIs. The doc tool extracts
  the LAST `#` line immediately above each `fn`; multi-line block
  comments were causing fragments like "writes — losing data on close
  would defeat the durability contract." to surface as `patra_close`'s
  doc string. Added single-line summary comments to the bottom of the
  affected blocks in `src/file.cyr` and `src/lib.cyr` (`pg_alloc`,
  `pg_free`, `patra_close`, `patra_set_sync_mode`, `patra_get_sync_mode`,
  `patra_prepare`, `patra_exec_prepared`, `patra_result_get_str_len`,
  `patra_result_read_bytes`, `patra_insert_row`, `patra_hdr_write_nosync`,
  `patra_hdr_verify`). Existing detailed block comments are retained
  for human readers; the trailing single-liner just gives the doc tool
  something clean to extract.
- **`dist/patra.cyr`** regenerated via `cyrius distlib` — 4777 lines,
  v1.8.3 header. Bundle shape unchanged from 1.8.2 except the version
  string and the formatted/doc-cleaned source.

### Verified
- `cyrius build programs/demo.cyr build/demo` — clean
- `cyrius test tests/tcyr/patra.tcyr` — 620 / 620 passing
- `cyrius fuzz fuzz/` — 6 / 6 passing
- `cyrius lint src/*.cyr` — 0 warnings across 11 files
- `cyrius fmt src/*.cyr --check` — no diffs
- `cyrius doc --check src/*.cyr` — 0 undocumented across 11 files
- `cyrius distlib` — `dist/patra.cyr` regenerated, 4777 lines

## [1.8.2] - 2026-04-24

Three perf optimizations bundled, all flagged as deferred in 1.8.1's
"Considered, Deferred" section. Each lands a measurable win and they
compose cleanly: prepared statements call into the same hot paths that
the slab + word-at-a-time helpers accelerate.

### Added
- **4KB page-slab allocator** (`pg_alloc` / `pg_free` in `src/file.cyr`).
  LIFO stack of pre-allocated `PAGE_SIZE` buffers replaces
  `fl_alloc(PAGE_SIZE)` / `fl_free` at ~45 hot sites across
  `btree.cyr`, `bytes.cyr`, `table.cyr`, `lib.cyr`, `file.cyr`.
  `PG_SLAB_MAX = 32` caps retained memory; overflow falls back to
  freelist transparently. Skips size-class lookup + per-call freelist
  bookkeeping on the dominant 4KB scratch-buffer pattern.
- **Word-at-a-time `_memeq256(a, b)`** in `src/row.cyr` — 32 × 8-byte
  loads, returns 1 if equal, 0 otherwise. Used by `_exec_insert`'s
  INSERT OR IGNORE STR conflict-probe verify (replaces the
  `memeq(..., COL_STR_SZ)` byte loop). Stdlib `memeq` is byte-by-byte
  for portability; this helper is COL_STR_SZ-specific.
- **Prepared statements** — four new public APIs in `src/lib.cyr`:

  | API                                   | Effect |
  |---------------------------------------|--------|
  | `patra_prepare(db, sql)`              | Tokenize + parse once, return opaque stmt handle (4112 bytes; owns a copy of the SQL string). 0 on parse error. |
  | `patra_exec_prepared(db, stmt)`       | Dispatch a prepared DDL/DML stmt without re-parsing. |
  | `patra_query_prepared(db, stmt)`      | Same, for SELECT. Returns result set or 0. |
  | `patra_finalize(stmt)`                | Free the stmt + its owned SQL buffer. Safe on 0. |

  The stmt holds an 8-byte SQL pointer + length + a 4096-byte snapshot
  of the parsed `_sql_pr`. `_stmt_restore` copies the snapshot into
  `_sql_pr` (word-at-a-time, since stdlib `memcpy` is byte-by-byte
  and a 4KB byte-loop would eat most of the win) before dispatching
  through the existing `_exec_*` / `_patra_query_exec` paths. Single-
  threaded — the `_sql_pr` global is overwritten per call.
- **`_patra_query_exec(db)`** internal split — extracted the body of
  `patra_query` so prepared-query and ad-hoc query share the same
  implementation. No caller-visible effect.
- **25 new tests** (595 → 620): prepared INSERT + SELECT, dispatch
  across all DDL/DML stmt types, syntax-error returns 0, stmt owns
  its SQL buffer (input freed-after-prepare still works),
  `patra_finalize(0)` is a no-op, prepared INSERT OR IGNORE on
  STR-indexed table (exercises slab + memeq256 + prepared together).
- **2 new benchmarks**:

  | Bench                  | Avg / insert |
  |------------------------|--------------|
  | `insert_1k_exec`       | 22µs         |
  | `insert_1k_prepared`   | 14µs         |

  ~36% faster per repeated INSERT. The saving (~8µs) matches the
  `parse_insert` bench; the prepared path skips the tokenize+parse
  on each call and the word-at-a-time `_stmt_restore` keeps the
  4KB snapshot copy from eating the win.

### Changed
- **47 `fl_alloc(PAGE_SIZE)` call sites** routed through `pg_alloc`;
  matching `fl_free` calls routed through `pg_free`. Internal change
  — no caller-visible effect. Existing freelist allocations for
  non-PAGE_SIZE buffers (token arrays, refs buffers, row scratch)
  unchanged.

### Notes
- All 620 tests pass against the new paths. Slab cap of 32 buffers
  bounds retained memory at 128 KB; chosen to comfortably cover the
  deepest btree walk (page reads at every level + path tracking +
  scratch).
- Prepared statements are single-threaded by design; `_sql_pr` is
  global, and concurrent prepare + exec_prepared would race. Patra's
  flock-protected single-writer model already enforces this.
- The slab + memeq256 deltas are too small to show on individual
  benches at this scale (each saves a few hundred ns per op);
  they're load-bearing for the prepared-statement win, where 4KB
  copies and 256-byte compares per call would otherwise dominate.

## [1.8.1] - 2026-04-24

Optimization-review pass after the 1.6.1 → 1.8.0 perf-feature sweep.
Surveyed Cyrius compiler changes since the prior pin and the vidya
knowledge base for tractable patra-side wins, then shipped what
actually clears the bar.

### Changed
- **Cyrius toolchain pin** raised from `5.6.21` to `5.6.39`. The
  5.6.21→5.6.39 compiler chain shipped:
  - **Linear-scan register allocation** (5.6.20–24) — Poletto-Sarkar
    picker auto-enabled for x86; reduces stack-frame load/store on
    hot loops with several locals (e.g. `sql_tokenize`, parser
    recursive-descent, btree walks). cc5-on-self measured a net
    −2–5% across regalloc phases.
  - **Codebuf NOP compaction** (5.6.27) — strips picker's 4-byte NOP
    fills post-regalloc and repairs disp32/JMP displacements.
    cc5-on-self: −2.13% binary, −16 KB cache pressure.
  - **Dead-store elimination** (5.6.18) — removes redundant
    `STORE_LOCAL` when the next instruction overwrites the same
    local.
  - **Bare-truthy branch fix** (5.6.21) — the 5.6.x truthy-on-fn-call
    codegen regression that prompted patra's earlier defensive `!= 0`
    sweep (since reverted).

  Pin is metadata-only — the local installed `cyrius` is what
  actually generates code. The bump documents the compatibility
  floor that captures these gains for downstream users on older
  pins.

- **No patra-side code changes.** All 595 tests, 6 fuzz harnesses,
  and 33 benchmarks pass against the bumped pin. Bench numbers
  unchanged from 1.8.0 (since the local cyrius was already 5.6.39
  during the 1.8.0 release run).

### Added
- **`docs/development/BENCHMARKS.md`** — baseline table for all 33
  benches plus a "perf arc 1.6.0 → 1.8.1" section showing the
  cumulative wins from sit's perf-review sweep. Captured on
  Linux 6.18 / btrfs / NVMe / x86-64 with cyrius 5.6.39.

### Considered, Deferred
- **Slab allocator for row buffers** — vidya's `allocators` entry
  flags this as a tractable medium-effort win on insert-heavy
  workloads. Deferred until a profiled hot-path actually points at
  allocation pressure; the patch-strategy preference says no
  speculative refactors. Patra's existing `fl_alloc` / `alloc`
  split (freelist + bump) already covers the documented patterns.
- **Word-at-a-time `memeq` for COL_STR_SZ comparisons** — could
  shave a few hundred nanoseconds off the `INSERT OR IGNORE` STR
  verify path, but the cost there is dominated by `btree_search`
  + `page_read`, not the byte loop. Not currently a bottleneck.
- **Prepared statements / cached SQL parse trees** — every
  `patra_exec` re-tokenizes + re-parses (8–10µs/call). For sit's
  300-object clone that's ~3ms in parsing, dwarfed by the
  fdatasync-bound writes 1.8.0 already amortized. Real win exists
  but the API + schema work belongs in 1.9.0, not a patch.

## [1.8.0] - 2026-04-24

Group commit / batched fsync. Third and final follow-up from sit's v0.6.4
perf review — the `clone-100commits` bottleneck is 300 × ~1ms fdatasync
on the implicit-per-exec path, which an opt-in batch mode collapses by
flushing once per 64 writes instead of once per write. Drops single-INSERT
durability cost from ~19.5ms to ~306µs on real-disk btrfs/nvme — about
**64× faster** for the workload sit hits during clone.

### Added
- **Per-DB sync mode (`PATRA_SYNC_FULL` / `PATRA_SYNC_BATCH`)** with
  three new public APIs in `src/lib.cyr`:

  | API                                   | Effect |
  |---------------------------------------|--------|
  | `patra_set_sync_mode(db, mode)`       | Switch mode. Flushes pending writes before the switch so no batch crosses a mode boundary unsynced. |
  | `patra_get_sync_mode(db)`             | Returns the current mode (testing / introspection). |
  | `patra_flush(db)`                     | Force durability of any pending BATCH-mode writes. No-op in FULL mode. Idempotent. |

  Default mode is `PATRA_SYNC_FULL` (current 1.7.1 behavior — fdatasync
  after every mutating exec, durable on every call). Mode is per-handle
  and not persisted in the file, so reopen returns to FULL.

- **`PATRA_BATCH_FLUSH_N = 64`** — auto-flush threshold. After 64
  un-synced writes the next exec triggers an implicit fdatasync,
  bounding the worst-case crash window to 64 ops regardless of how
  long the consumer holds the handle.

- **`_db_hdr_commit(db, fd, hdr)`** internal helper. Every implicit
  per-exec header write in `_exec_*` and `patra_insert_row` (10 sites
  in `src/lib.cyr`) now routes through this helper. FULL mode delegates
  to the legacy `patra_hdr_write` (with fdatasync); BATCH mode calls
  the new `patra_hdr_write_nosync` (added to `src/file.cyr`) and bumps
  the pending counter, auto-flushing at threshold. Explicit transactions
  (`patra_begin`/`patra_commit`) are unchanged — `patra_commit` still
  fdatasyncs on commit regardless of mode, since the WAL contract
  requires it.

- **`patra_close(db)` flushes** any pending BATCH-mode writes before
  releasing the fd. Without this guard a consumer could lose data on a
  clean shutdown — defeats the durability contract.

- **10 new tests** (585 → 595): default-mode-is-FULL, BATCH same-process
  visibility, explicit `patra_flush` (incl. idempotence), `patra_close`
  flushes pending, mode resets to FULL on reopen, switching mode flushes
  pending, auto-flush threshold (70 writes → consistent reads).

- **2 new benchmarks** (run on a real-disk btrfs/nvme path; `/tmp` is
  tmpfs where fdatasync is a no-op and the win is invisible):

  | Bench                          | Time / insert |
  |--------------------------------|---------------|
  | `insert_500_sync_full`         | 19.483ms      |
  | `insert_500_sync_batch`        | 306µs         |

  Math checks out: 500 inserts × 1 fdatasync at ~19.5ms = ~10s for
  FULL; 500 inserts × ~8 fdatasyncs (500/64 + final flush) = ~152ms
  for BATCH ≈ 306µs/insert amortized.

### Changed
- **DB struct grew** from 32 to 48 bytes (`DB_SYNC_MODE` at offset 32,
  `DB_BATCH_PENDING` at offset 40). Internal — no caller-visible
  effect; consumers only see the new APIs.

### Notes
- BATCH mode's durability contract: a successful `patra_exec` means
  the operation is in OS page cache and visible to the same process,
  but may not survive a crash until the next fdatasync (auto at
  64-op threshold, on `patra_flush`, on `patra_close`, or on explicit
  `patra_commit` for the transactional path).
- BATCH does not weaken `patra_begin`/`patra_commit` — explicit
  transactions still fsync on commit. The mode only affects the
  implicit per-exec path that 1.7.0/1.7.1 callers (and sit) hit when
  not using explicit transactions.
- Sit's `clone-100commits` workload is exactly the shape this
  optimizes: many independent INSERTs, no explicit BEGIN/COMMIT,
  durability acceptable per-batch rather than per-row.

## [1.7.1] - 2026-04-24

STR-keyed B+ tree indexes — the prerequisite called out in 1.7.0's
caveat. Sit's `hash STR` and `path STR` columns can now carry a
`CREATE INDEX`, and `INSERT OR IGNORE` against those columns probes
the tree directly instead of falling through to the no-index pass-through.
Reuses the existing i64-keyed btree with djb2-64 hash + verify-on-hit:
no parallel implementation, no file-format change.

### Added
- **`_str_hash64(ptr, len)`** in `src/row.cyr` — djb2-64 over the
  input bytes followed by zero-padding to `COL_STR_SZ`. Matches the
  hash of a 256-byte zero-padded slot, so query-time literals hash
  identically to stored rows.
- **`_idx_key_from_row(schema, ncols, ic, row)`** dispatcher — INT cols
  return the raw i64; STR cols return `_str_hash64` of the slot.
  Replaces every `row_read_int(row, koff)` site that was reading the
  indexed column key (`src/lib.cyr` × 4, `src/table.cyr` × 3).
- **`CREATE INDEX ON t (str_col)`** — `_exec_create_index`'s INT-only
  rejection at `src/lib.cyr:780` is replaced with a `COL_BYTES` rejection
  only. Population loop hashes each row's STR slot.
- **WHERE indexed-eq STR fast path** (`src/lib.cyr:1107-1145`) — when
  the indexed col is STR and the WHERE has a `=` literal, hash the
  literal and use it as both `idx_lo` and `idx_hi`. The downstream
  `where_eval` re-check at `src/where.cyr:149-153` does the byte-compare
  that filters any hash collisions, so the fast path is correctness-
  preserving by construction. Range ops on STR (`<`, `>`, `<=`, `>=`)
  fall through to scan since hashed keys don't preserve ordering.
- **`INSERT OR IGNORE` STR verify path** (`src/lib.cyr:207-256`) — INT
  cols stay on the `max=1` btree probe; STR cols pull up to 256
  candidates, then byte-compare the 256-byte slot against the inserted
  row's slot to filter false positives. Verified hit → return `PATRA_OK`
  without inserting.
- **20 new tests** (565 → 585): STR index create + select, STR-indexed
  `INSERT OR IGNORE` dedup hit/miss, UPDATE keeps tree consistent,
  DELETE drops ref + reinsert, persistence across reopen, hash-bucket
  saturation safety with 50 distinct STR keys.
- **`fuzz_sql.fcyr`** gains a STR-indexed dedup probe path.
- **3 new benchmarks**:

  | Bench                              | Time           |
  |------------------------------------|----------------|
  | `str_dedup_insert_or_ignore_500`   | 16µs / attempt |
  | `select_str_idx_eq_500`            | 256µs          |
  | `select_str_scan_500`              | 324µs          |

  STR `INSERT OR IGNORE` matches INT's 14µs (the hash + verify is paid
  only on candidate-set walk, not the early-skip path). STR-indexed
  equality select is ~21% faster than the scan baseline; smaller
  speedup than INT's ~39% because `where_eval` already byte-compares
  the same way the scan does — the win is just the smaller candidate
  set.

### Changed
- **CREATE INDEX no longer rejects STR columns.** Test
  `test_create_index` updated to assert `CREATE INDEX ON ci (name)`
  returns `PATRA_OK` instead of `PATRA_ERR_TYPE`. The existing
  `PATRA_ERR_TYPE` rejection now applies only to `COL_BYTES` columns.
  No other behavior change for INT-keyed callers.

### Notes
- Hash collisions are correctness-neutral: every read-side path
  (`where_eval`, `INSERT OR IGNORE` conflict probe) byte-compares the
  full 256-byte slot. Engineered worst-case collision sets degrade
  selectivity but never produce wrong rows.
- Sit's `hash STR` and `path STR` columns are now indexable — that's
  the actual unblock for the 1.7.0 dedup win on sit's primary
  workload.

## [1.7.0] - 2026-04-24

`INSERT OR IGNORE`. Second of three follow-ups requested by sit's v0.6.4
perf review. Collapses every consumer's content-addressed-dedup pattern
from `SELECT exists?` + conditional `INSERT` (two SQL ops, full result-set
materialization) to a single `INSERT OR IGNORE` (one parse + one B-tree
probe + early return on hit).

### Added
- **`INSERT OR IGNORE INTO …` SQL syntax.** Parses identically to plain
  `INSERT` but sets a per-statement `PR_INSERT_IGNORE` flag (`src/sql.cyr`).
  Tokenizer adds `TK_IGNORE`; the existing `TK_OR` is reused.
- **Conflict probe in `_exec_insert`** (`src/lib.cyr:207-228`). When the
  flag is set and the table has a B-tree index (`SCH_IDX_COL >= 0`),
  `btree_search` looks up the would-be inserted key. ≥1 hit → return
  `PATRA_OK` without inserting (and without taking the WAL path).
  Tables with no index have no conflict surface, so `INSERT OR IGNORE`
  there behaves identically to plain `INSERT`. The probe runs against
  whichever column carries the auto-index (first INT col, see
  `src/table.cyr:80-88`) or an explicit `CREATE INDEX`.
- **22 new tests** (543 → 565): parse-side accept/reject + flag check,
  dedup hit, dedup miss, no-index passthrough, persistence across
  reopen.
- **`fuzz_sql.fcyr`** gains 5 new invariants covering malformed
  `INSERT OR …`, valid `INSERT OR IGNORE`, and the flag-clear-on-vanilla
  path.
- **2 new benchmarks** comparing the SELECT-then-conditional-INSERT
  workaround against `INSERT OR IGNORE` for 500 conflicting attempts
  against a 500-row indexed table:

  | Bench                              | Time / attempt |
  |------------------------------------|----------------|
  | `dedup_select_then_insert_500`     | 254µs          |
  | `dedup_insert_or_ignore_500`       | 14µs           |

  ~18× faster on the dedup-hit path. The win is one parse + one B-tree
  probe + early return, vs one parse + one full SELECT result-set
  materialization + one INSERT parse + one INSERT (which itself has to
  rewalk the same key for the index update).

### Changed
- **PR layout** (`src/sql.cyr` `enum PROff`): added
  `PR_INSERT_IGNORE = 64`, shifted `PR_ITEMS` from 64 to 72. The
  layout-invariant test (`test_parse_result_layout_invariant`) still
  passes — every PR_ITEMS-based write fits inside 4096, SELECT
  projection still ends below `PR_AGG_TYPE`. Internal change; no
  caller-visible effect.

### Notes
- `INSERT OR IGNORE`'s conflict surface today is the table's single
  B-tree index, which patra's auto-index logic only creates on the
  first INT column. STR-keyed indexes are still future work — sit's
  `hash STR` / `path STR` columns therefore can't yet take advantage
  of `OR IGNORE`. Tracked as a prerequisite once the patch-strategy
  cadence makes that the right next item.

## [1.6.1] - 2026-04-24

Sized string accessor. First of three follow-ups requested by sit's
v0.6.4 perf review (2026-04-25); see
[`docs/development/roadmap.md`](docs/development/roadmap.md).

### Added
- **`patra_result_get_str_len(rs, row, col)`** — returns the byte length
  of a STR value at `(row, col)` via a bounded scan over the 256-byte
  slot, capped at `COL_STR_SZ`. Returns `-1` for non-STR columns.
  Mirrors the existing `patra_result_get_bytes_len` shape so consumers
  can drop ad-hoc `strnlen` wrappers (sit's S-31 defense). The bounded
  scan also keeps the accessor safe if a future writer skips the
  `COL_STR_SZ` zero-fill that `row_write_str` performs today.
- **6 new tests** (537 → 543) covering empty / mid-length / 255-char
  ceiling / non-STR-column-returns-`-1` cases.

## [1.6.0] - 2026-04-23

`COL_BYTES`: variable-length binary column. Motivated by [sit](https://github.com/MacCracken/sit)
(sovereign version control) migrating its object store from loose files
on disk to patra-backed tables. Unblocks atomic blob+tree+commit through
patra's WAL — previously split between patra (refs) and loose files
(object bodies), which meant `sit commit` couldn't land atomically.

### Added
- **`COL_BYTES` column type** — variable-length binary payloads, no
  per-value cap beyond the chain-page overflow scheme. Stored as a
  16-byte `(first_page, length)` row ref pointing at a chain of
  `PAGE_BYTES` pages (`BY_DATA_MAX = 4072` bytes per page). Row ref of
  `(0, 0)` is an empty blob — no pages allocated.
- **`src/bytes.cyr`** — new module with `_bytes_write_chain` (emits the
  chain tail-first so the returned page is the head), `_bytes_read_chain`
  (bounds-checks every page through `page_read_checked` + `PAGE_BYTES`
  type marker), and `_bytes_free_chain` (walks the chain, frees each
  page onto the free list).
- **`patra_insert_row`** — programmatic insert API with parallel arrays
  indexed 0..ncols-1. Per-column slot selection by `types[i]`: COL_INT
  uses `ivals[i]`, COL_STR uses `sptrs[i]/slens[i]`, COL_BYTES uses
  `bptrs[i]/blens[i]`. The only path that writes BYTES — SQL `INSERT`
  can't carry binary through the tokenizer.
- **`patra_result_get_bytes_len(rs, row, col)`** and
  **`patra_result_read_bytes(db, rs, row, col, out)`** — read-path API.
  Caller allocates `out` sized to the declared length; the read walks
  the chain once.
- **SQL `BYTES` keyword** in `CREATE TABLE ... (col BYTES)`. `BLOB` is
  accepted as a case-insensitive legacy alias so habitual spellings
  still parse to the canonical `COL_BYTES` token.
- **Chain cleanup on DELETE, DROP TABLE, ALTER TABLE DROP COLUMN** —
  when a row with a BYTES column is removed (or the BYTES column
  itself is dropped), every chain page is released onto the free list.
  Non-BYTES tables skip the per-row chain scan via
  `_tbl_has_bytes` guard.
- **62 new tests** (475 → 537), covering: `CREATE TABLE` with BYTES,
  round-trip of small / empty / multi-page (10 000 bytes, 3 chain
  pages) blobs, 20-row iteration, DELETE frees chains, DROP TABLE +
  reclaim via free list, SQL INSERT/UPDATE rejected on BYTES columns,
  WHERE on BYTES never matches (by design), ALTER ADD COLUMN BYTES
  defaults to empty `(0, 0)`, ALTER DROP COLUMN BYTES frees chains,
  persistence across close/reopen.
- **`fuzz_bytes.fcyr`** — 5 mutations on the head chain page (bad
  `BY_TYPE`, oversized `BY_LEN`, self-cycle via `BY_NEXT`,
  out-of-file `BY_NEXT`, negative `BY_LEN`). All return cleanly.
- **Benchmarks** — `bytes_insert_2kb` (~40µs) and `bytes_read_2kb`
  (~6µs) added to the bench suite.

### Changed
- **Cyrius toolchain pin raised** from `5.5.27` to `5.6.21`. (Development
  briefly pinned to `5.6.19` with a defensive `!= 0` sweep around a
  5.6.x truthy-test-on-fn-call codegen regression; cyrius 5.6.21 shipped
  the fix and the workaround was reverted before tag.)
- **WHERE on BYTES columns is a no-match by design.** Variable-length
  binary isn't meaningfully comparable via `=` / `LIKE` / ordered ops;
  sit's workflow keys off a sibling `hash STR` column.

### Not Added
- **Compression** — sankoch is the compression layer; sit pre-compresses
  its objects. Patra stores bytes verbatim.
- **Streaming / chunked reads** — v1 is "read whole value into caller
  buffer". Chunked reads are a later refinement if a consumer needs them.
- **B-tree indexing on BYTES** — lookup goes through a sibling STR
  column (e.g. `hash STR` → `content BYTES`). No index on the bytes.

### File format
- `.patra` on-disk format is unchanged in structure. `COL_BYTES = 2`
  and `PAGE_BYTES = 4` are new values in existing enum slots. Databases
  written before 1.6.0 stay readable with no migration; databases with
  BYTES columns are **not** back-compatible with 1.5.x (earlier
  versions would mis-interpret the column type).

## [1.5.5] - 2026-04-21

Switch bundle generation from the ad-hoc `scripts/bundle.sh` shell
script to `cyrius distlib`. No functional change to the published
bundle — `dist/patra.cyr` has the same shape and content as v1.5.4.

### Changed
- **`cyrius.cyml`** — added a `[lib] modules = [...]` section
  declaring the concatenation order that `cyrius distlib` consumes.
  Bumped `[package].cyrius` from `5.5.22` to `5.5.26` (distlib is
  the path the cyrius toolchain now endorses across the ecosystem
  as of 5.5.26).
- **Bundle is now generated by `cyrius distlib`.** Rebuild command
  updated from `sh scripts/bundle.sh` to `cyrius distlib`.

### Removed
- **`scripts/bundle.sh`** — superseded by `cyrius distlib`. The
  module list it hardcoded is now declared in `cyrius.cyml`'s
  `[lib]` section; the toolchain reads it and writes `dist/patra.cyr`
  directly. One less ecosystem shell script to maintain.

## [1.5.4] - 2026-04-21

Drop `.cyrius-toolchain` as the toolchain source of truth. `cyrius.cyml`
`[package].cyrius` is now the single place the Cyrius compiler version
lives. No source / format / test changes.

### Removed
- **`.cyrius-toolchain`** file — historical holdover from before
  `cyrius.cyml` carried the toolchain pin (introduced in 1.1.0 and
  kept around for CI convenience). Removing it eliminates the
  "which one is authoritative?" ambiguity that caused the 1.1.0 latent
  bug (ci.yml / release.yml version mismatch 4.10.3 vs 3.2.1).

### Changed
- **`.github/workflows/ci.yml` and `release.yml`** now read the
  Cyrius version from `cyrius.cyml` via the same
  `grep '^cyrius = ' … | sed …` pattern already used for the version-
  consistency check. The `CYRIUS_VERSION` env-var override still works.

### Validation
- 475 passed, 0 failed (unchanged).
- 5 fuzz harnesses pass.
- No runtime behavior changed — this is purely a build-system cleanup.

## [1.5.3] - 2026-04-21

Audit P2 + P(-1) scaffold pass. Closes out the security-review work
scheduled against the 2026-04-21 external review. On-disk `.patra`
format unchanged; **WAL format is v2** (salted) — 1.5.2 WALs are refused.

### Added
- **WAL format v2: salted per-record auth** (wal.cyr). WAL header grows
  8B → 24B with a pair of 8-byte salts drawn from `SYS_GETRANDOM` on
  every `wal_start` (time+counter fallback when the syscall is
  unavailable). The per-record hash is now
  `djb2-derived(salt1, page_num, page_data) XOR salt2`. Protects
  against accidental corruption, stale-WAL replay, *and* cross-WAL
  replay. Audit §3.4 / §4.3. Does not defeat an attacker who can read
  `.wal` — documented as out of scope in `SECURITY.md`.
- **`json_build_lens` + `jsonl_append_obj_lens`** (jsonl.cyr). New
  length-aware JSON builders take a `vlens` array for explicit STR
  lengths. Embedded NUL bytes now emit as `[NUL]` instead of
  silently truncating. Audit §2.6 — closes the log-forging primitive.
  Legacy `json_build` / `jsonl_append_obj` preserved as thin wrappers
  using `strlen` for backward compatibility.
- **`SECURITY.md`** rewritten with concrete threat model, per-surface
  mitigation table, supported / unsupported deployment matrix (NFS:
  not supported; `fork` without `close`: not supported; non-flock
  concurrent writers: not supported), known limitations, and
  pointers to `docs/audit/2026-04-21/`.
- **Three new fuzz harnesses** (2 → 5 total):
  - `fuzz_btree.fcyr` — plants 5 pathological B-tree root mutations
    (NKEYS=2B, bogus child = 999999 / self / header-page, flipped LEAF);
    asserts `patra_query` returns cleanly.
  - `fuzz_wal.fcyr` — 5 WAL corruptions (empty, 4B-truncated, 1 MiB
    garbage, v1 header, v2 header with all-zero records); asserts the
    DB row-77 invariant survives every run.
  - `fuzz_jsonl.fcyr` — 7 adversarial JSONL cases (25-digit overflow,
    exact cutoff, negative, missing key, malformed line, long lines,
    embedded control bytes).
- **`test_parse_result_layout_invariant`** — static-assert-equivalent
  test that `PR_ITEMS + MAX_COLS*{CR,IR,SET,SEL}_SZ` stays within the
  4096-byte parse-result buffer, `PR_ORDERBY_COLS + OB_MAX*OB_SZ`
  stays below `PR_WHERE`, and `PR_WHERE + WH_MAX*WH_ENTRY_SZ` stays
  within 4096. Catches future parser growth that would quietly
  corrupt adjacent metadata. Audit §4.4.

### Changed
- `_wal_hash` signature: now takes `(pg, page_data, salt1, salt2)`.
- WAL header size: 8 → 24 bytes.
- WAL version: 1 → 2.
- `SECURITY.md` expanded from 13 lines to a proper policy document.

### Breaking (runtime, not source)
- **Stale `.wal` files from 1.5.1 or 1.5.2 are refused.** The version
  byte now requires 2. Committed data is untouched; any in-flight
  transaction at upgrade is lost.

### Validation
- 475 passed, 0 failed (was 467 — +5 layout invariants, +2 salt-era
  WAL paths covered by existing tests, +1 reshape).
- **5 fuzz harnesses pass** (was 2 — fuzz_btree / fuzz_wal / fuzz_jsonl
  new; fuzz_file / fuzz_sql unchanged).
- 24 benchmarks within baseline variance.
- libro (15) + vidya (19) integration unchanged.

### Known (not scheduled)
- Cyrius 5.5.x DCE still a no-op (ADR 0001).
- Consumers still using `jsonl_append_obj` (strlen-based) are unchanged;
  migration to `jsonl_append_obj_lens` is opt-in.

## [1.5.2] - 2026-04-21

Audit P1 hardening. Five security fixes driven by
`docs/audit/2026-04-21/security-review.md`. On-disk `.patra` format
unchanged; WAL format unchanged since 1.5.1.

### Added
- **Cyrius toolchain pin raised** 5.5.18 → 5.5.22 to match the
  installed compiler.
- **`_json_escape` covers all 0x00–0x1F** (jsonl.cyr). Adds `\b` (0x08)
  and `\f` (0x0C) shortcuts alongside existing `\t \n \r`, and emits
  `\u00XX` for every other control byte. `load8` results masked with
  `& 0xff` so high bytes (≥ 0x80) are not mis-classified as controls.
  Internal cap widened `slen*2` → `slen*6+8` to accommodate worst-case
  expansion. Audit §2.6, §3.6 — closes the "emits invalid JSON" vector
  for STR columns containing control bytes.
- **`jsonl_get_int` overflow guard** (jsonl.cyr). Any input whose
  running parse exceeds `MAX_I64 / 10 = 922337203685477580` now returns
  0 rather than silently wrapping. Audit §2.7.
- **`O_NOFOLLOW` on all database / JSONL opens** (file.cyr, jsonl.cyr).
  `_pt_file_create` and `_pt_file_open` now set `O_NOFOLLOW` (Linux
  flag `0x20000`), as does `jsonl_open`. A symlinked target path
  causes `open(2)` to fail with `ELOOP`; `patra_open` returns 0.
  Audit §2.8 — closes the CVE-2025-68146-style TOCTOU/symlink plant.
- **`fdatasync(db_fd)` before WAL unlink** (wal.cyr `wal_commit`).
  Data pages are flushed to stable storage before the WAL file is
  removed. Audit §2.9 — closes the LevelDB-class "committed data
  lost on crash between WAL unlink and kernel writeback" window.
- **`page_offset` overflow check** (page.cyr). Returns `-1` for
  `num < 0` or `num > 2^50`; callers' existing `_pt_seek(...) < 0`
  guards propagate the error cleanly. Audit §2.4 — defeats the
  attacker-planted `HDR_FREEHEAD = 0x0040_0000_0000_0001` wrap.
- **5 new test groups / 31 new assertions** (436 → 467):
  `json escape control chars` (NUL, 0x01, 0x08, 0x0C, 0x1F, 0x20,
  0x80), `jsonl_get_int overflow` (25-digit overflow, exact cutoff,
  MAX+n), `symlink refused` (real DB + symlink → `patra_open` returns
  0), `page_offset overflow` (cap + negative), `wal commit durable`
  (begin/insert/commit/close/reopen round-trip).

### Changed
- `cyrius.cyml` `cyrius` pin: `"5.5.18"` → `"5.5.22"`.
- `.cyrius-toolchain`: `5.5.18` → `5.5.22`.

### Validation
- 467 passed, 0 failed (was 436).
- 2 fuzz harnesses pass.
- 24 benchmarks within baseline variance.
- libro (15) + vidya (19) integration unchanged.

### Known (tracked for 1.5.3)
- **Audit P2 + P-1** items remain: new fuzz harnesses (btree / wal /
  jsonl / header mutation), salt-based WAL authentication (currently
  only integrity — attacker who knows the djb2-derived hash can forge
  records), NFS/fork SECURITY notes, static test that `_sql_pr` math
  still holds as the parser grows.
- Cyrius 5.5.x DCE still a no-op (ADR 0001).
- Embedded NUL in STR column → `strlen`-based `json_build` still
  silently truncates the tail. Closing this requires an API change
  (pass explicit lengths to `jsonl_append_obj`); scheduled for 1.5.3
  once consumer impact is scoped.

## [1.5.1] - 2026-04-21

Audit P0 hardening. Six security fixes driven by
`docs/audit/2026-04-21/security-review.md`. **WAL file format changes**
— on-disk `.patra` format unchanged, but any stale `.wal` from 1.5.0 or
earlier is refused rather than replayed (the DB is left intact; only
uncommitted transactions are lost on upgrade).

### Added
- **`page_read_checked(fd, hdr, num, buf)`** (page.cyr) — validates
  `1 ≤ num < HDR_PGCOUNT` before reading. Rejects the Magellan-class
  OOB-read vector where a malformed `.patra` points a B-tree child at
  an arbitrary page number. Every recursive B-tree walker switched to
  the checked variant.
- **`BT_MAX_DEPTH = 10` recursion cap** (btree.cyr) — `_bt_find_leaf`,
  `_bt_rwalk`, `_bt_compact_walk`, and `btree_free_all` now take a
  depth argument and abort at the cap. `_bt_path` enlarged from 48 to
  80 bytes to match. A malformed tree with a cycle terminates cleanly
  instead of stack-exhausting.
- **WAL format v1** (wal.cyr) — 8-byte header (`"PTWA"` magic +
  version) + per-record 8-byte hash of `(page_num || page_data)`.
  `_wal_hdr_verify` refuses bare / mis-versioned WAL files;
  `wal_recover` / `wal_rollback` stop replay on the first hash
  mismatch (earlier records still apply). Defeats torn writes and the
  "hostile `.wal` drop" scenario from audit §2.3.
- **WHERE condition cap** (`WH_MAX = 32`) and **INSERT value cap**
  (`MAX_COLS = 32`) in the parser — returns
  `PATRA_ERR_SYNTAX` / `PATRA_ERR_COLCOUNT` before writing past
  `_sql_pr + PR_WHERE` / `_sql_pr + PR_ITEMS`. Closes audit §2.5 + §2.10
  heap-corruption vectors.
- **Extended `patra_hdr_verify`** (file.cyr) — now also checks
  `HDR_VER == PATRA_VER`, `HDR_PGCOUNT >= 1`,
  `HDR_TBLCOUNT <= MAX_TABLES`, and `HDR_FREEHEAD < HDR_PGCOUNT`.
  Returns typed `PATRA_ERR_MAGIC` / `PATRA_ERR_PAGE`. Audit §3.7.
- **6 new test groups / 12 assertions** (424 → 436): `insert value
  count bounded`, `where condition count bounded`, `wal bad magic
  refused`, `wal checksum stops replay`, `hdr verify bad tblcount`
  (covers version + freehead + zero-pgcount cases), `btree bad child
  pointer` (deliberate corruption via `page_write`; query must not
  crash). Mirrors the deterministic invariants listed in audit §4.2
  #6, 7, 10, 11, and subset of §2.1.
- **Fuzz harness `fuzz_file.fcyr`** updated to exercise the new
  rejections (wrong version, over-cap tblcount, out-of-range
  freehead).

### Changed
- **B-tree public signatures gain `hdr`**: `btree_search`,
  `btree_remove_ref`, `btree_compact`, `_bt_range`, `_bt_find_leaf`.
  Updated callers in `table.cyr`, `lib.cyr`, tests, and benchmarks.
- **`_bt_path` size**: 48B → 80B (6 → 10 depth slots).

### Breaking (runtime, not source)
- **Stale `.wal` files from 1.5.0 or earlier are not replayed.** They
  lack the 1.5.1 magic. Patra refuses to replay and leaves the file on
  disk for inspection. Any uncommitted transaction in-flight at upgrade
  is lost; committed data is untouched. Applications that orchestrate
  patra upgrades should flush/commit before upgrading.

### Validation
- 436 passed, 0 failed (was 424).
- 2 fuzz harnesses pass (fuzz_file extended with 2 new invariants).
- 24 benchmarks within baseline variance.
- libro (15) + vidya (19) integration unchanged.

### Known (tracked for 1.5.2+)
- P1 items from the audit remain: `_json_escape` 0x00–0x1F coverage,
  `jsonl_get_int` overflow guard, `O_NOFOLLOW` on opens,
  `fdatasync(db_fd)` before WAL unlink, `page_offset` overflow check.
- P2 + P-1 items: new fuzz harnesses (btree/wal/jsonl/header mutation),
  salt-based WAL authentication (currently only integrity), NFS/fork
  SECURITY notes.
- Cyrius 5.5.x DCE still no-op (ADR 0001).

## [1.5.0] - 2026-04-21

Whole-tree B-tree page reclaim, Cyrius 5.5.x DCE limitation documented,
and a security audit landed in `docs/audit/2026-04-21/`. On-disk format
unchanged.

### Added
- **`btree_free_all(fd, hdr, root)`** — depth-first walk of every page
  in a B-tree, freeing leaves and internals before the root. Replaces
  the single-page `page_free(fd, hdr, ir)` calls in `tbl_drop`,
  `_exec_alter_add`, and `_exec_alter_drop_col`. Closes the
  long-standing leak where `DROP TABLE` and `ALTER TABLE ADD/DROP
  COLUMN` only freed the B-tree root and left every internal/leaf page
  permanently allocated.
- **2 new test groups** (424 → 424 incl. fuzz, +2 to unit suite):
  `btree reclaim on drop` (verifies the free-list grows by ≥5 pages
  on a 300-row drop with a multi-level tree) and `btree reclaim on
  alter add` (verifies file growth ≤3 pages after ALTER ADD COLUMN
  INT on a 200-row indexed table — the rebuild reuses freed pages
  instead of extending the file).
- **`docs/adr/0001-cyrius-5-5-dce-toolchain-limitation.md`** —
  documents the investigation into why `CYRIUS_DCE=1` produces
  byte-identical builds under Cyrius 5.5.x. Decision: keep the
  env var in CI/release for forward compatibility, accept the
  inflated binary size, track upstream.
- **`docs/audit/2026-04-21/security-review.md`** — external research
  cataloging 15 CVEs/incidents most-relevant to Patra's scope (SQLite
  Magellan, MongoBleed, LMDB, LevelDB durability, flock TOCTOU, etc.),
  10 bug classes with concrete reproductions, module-by-module
  concerns, and 14 next-step actions. Findings are scheduled by
  severity for **1.5.1** (P0/P1 fixes) and later.

### Changed
- `tbl_drop` (table.cyr), `_exec_alter_add`, `_exec_alter_drop_col`
  (lib.cyr) all switched from single-page `page_free` to
  `btree_free_all`.

### Validation
- 424 passed, 0 failed (was 421 — 421 carried + 3 reclaim assertions
  recombined into 2 groups, plus a tightened ALTER add bound).
- 2 fuzz harnesses pass.
- 24 benchmarks within baseline variance.
- libro (15) + vidya (19) integration unchanged.

### Known
- **Cyrius 5.5.x DCE no-op** stands. Demo binary remains ~190KB
  rather than the ~120KB baseline from Cyrius 4.10.3. Tracked in
  `docs/adr/0001-cyrius-5-5-dce-toolchain-limitation.md`.

## [1.4.1] - 2026-04-21

ALTER TABLE DROP COLUMN — completes roadmap backlog #4. On-disk format
unchanged.

### Added
- **`ALTER TABLE t DROP COLUMN name`** — removes a column and rewrites
  every row, dropping the column's bytes. Schema entries after the
  dropped position shift left by one. Returns `PATRA_ERR_COLCOUNT` when
  the table has only one column (can't leave zero-column tables).
  Returns `PATRA_ERR_NOTFOUND` for unknown column / unknown table.
- **Index handling**:
  - If the dropped column was the indexed column → index is torn down
    (`SCH_IDX_COL = -1`, root freed). Queries fall back to scan; a new
    `CREATE INDEX` can be issued afterward.
  - If the dropped column precedes the indexed column → `SCH_IDX_COL`
    shifts left by one and the B-tree is rebuilt.
  - If the dropped column follows the indexed column → position
    unchanged and the B-tree is rebuilt (refs change with row rewriting).
- **6 new test groups / 32 new assertions** (389 → 421): parser
  refresh, drop middle col (data + index intact), drop indexed col
  (index torn down, can re-CREATE INDEX), drop col before indexed
  (index position shifts), drop-last-col rejected, drop unknown
  col/table rejected, persistence across reopen.

### Changed
- **`StmtType`** extended with `STMT_ALTER_DROP_COL`.
- **`test_parse_alter`** updated: the 1.4.0 "DROP not supported"
  assertion is replaced with one that verifies the new parse path
  succeeds, plus a new "missing COLUMN keyword" syntax-error case.

### Known
- **B-tree internal/leaf pages leak** on DROP COLUMN when the dropped
  column was indexed or when the table was indexed on another column —
  same pre-existing pattern as ADD COLUMN and `tbl_drop`. Tree-wide
  page reclaim is a separate cleanup.

### Validation
- 421 passed, 0 failed (was 389).
- 2 fuzz harnesses pass.
- 24 benchmarks within baseline variance.
- libro (15) + vidya (19) integration unchanged.

## [1.4.0] - 2026-04-21

ALTER TABLE (partial — ADD COLUMN + RENAMEs). On-disk format unchanged;
schema-page layout unchanged. Closes roadmap backlog #4 for the common
migration operations. `ALTER TABLE ... DROP COLUMN` lands in 1.4.1.

### Added
- **`ALTER TABLE t ADD COLUMN name INT|STR`** — appends a column to the
  end of the schema. Existing rows get the default value (0 for INT,
  empty string for STR). Implementation: gather all rows into a scratch
  buffer with the default appended, free the old data-page chain and
  B-tree root, rewrite the schema page with the new column, allocate a
  fresh data root + B-tree (if the table was indexed), then reinsert
  every row via the normal path (which maintains TBL_NROWS, last-page
  cache, and B-tree). Refs in the rebuilt B-tree reflect the new row
  positions.
- **`ALTER TABLE t RENAME TO new_name`** — updates `TBL_NAME` in the
  table directory. Collisions with existing tables are rejected.
- **`ALTER TABLE t RENAME COLUMN old TO new`** — updates `SCH_CNAME` in
  the schema page. WHERE/ORDER BY/projection resolve against the new
  name; the existing B-tree index is unaffected (indexed by column
  position, not name).
- **8 new test groups / 44 new assertions** (345 → 389): parser,
  RENAME TO + collision + unknown-table, RENAME COLUMN + index-unaffected
  + collision + unknown-col, ADD COLUMN on empty table, ADD COLUMN on
  populated table with index rebuild + subsequent insert + UPDATE on new
  col, ADD COLUMN STR default, ADD COLUMN collision / unknown table,
  ADD COLUMN persistence across reopen.

### Changed
- **`TokType` + `StmtType` extended** with `TK_ALTER/ADD/COLUMN/RENAME/TO`
  and `STMT_ALTER_ADD/RENAME_TBL/RENAME_COL`.

### Known
- **DROP COLUMN** is not supported in 1.4.0 — `ALTER TABLE t DROP COLUMN x`
  still returns `PATRA_ERR_SYNTAX`. Lands in 1.4.1.
- **B-tree internal/leaf pages leak on ADD COLUMN** when the table had
  an index — matches the pre-existing `tbl_drop` behavior (only the root
  page is freed). Acceptable for now; whole-tree page reclaim is a
  separate cleanup.

### Validation
- 389 passed, 0 failed (was 345).
- 2 fuzz harnesses pass.
- 24 benchmarks within baseline variance.
- libro (15) + vidya (19) integration unchanged.

## [1.3.0] - 2026-04-20

LIKE operator + B-tree compaction (VACUUM). On-disk format unchanged.

### Added
- **`LIKE` operator** (roadmap backlog #6) — new comparison operator for
  string columns. Supports `%` (zero or more chars) and `_` (exactly one
  char). Implemented as iterative backtracking on the last `%` seen.
  Works alongside other WHERE conditions (`AND`/`OR`). Available in
  `SELECT`, `UPDATE`, and `DELETE` WHERE clauses.
- **`VACUUM table_name`** (roadmap backlog #5) — reclaims lazy-deleted
  B-tree entries for a table. DELETE and UPDATE tombstone index entries
  (val=-1) rather than structurally remove them; VACUUM walks all leaves
  and shifts live entries forward, updating `BT_NKEYS`. Empty leaves are
  left in-tree by design (avoids full B-tree delete rebalance). Point
  queries are already efficient over tombstones; the structural benefit
  is leaf headroom for future inserts and cleaner selectivity-gate
  inputs.
- **2 new benchmarks**: `parse_like` (~14µs) and
  `select_idx_500_tombstones` / `select_idx_500_vacuumed` pair
  (~410µs each — tombstone overhead on point lookups is within noise,
  confirming the v0.16.0 lazy-delete design was sound).
- **15 new test assertions across 9 test groups** — LIKE prefix,
  suffix, contains, underscore, literal, parse; VACUUM reclaim + parser
  + no-index + unknown-table. Total 331 → 345.

### Changed
- **`CmpOp` extended** with `CMP_LIKE = 6`. String comparison routes LIKE
  patterns to the new `_like_match` helper; all other ops unchanged.
- **`TokType`/`StmtType` extended** with `TK_LIKE`, `TK_VACUUM`,
  `STMT_VACUUM`.

### Validation
- 345 passed, 0 failed (was 314).
- 2 fuzz harnesses pass.
- 24 benchmarks (was 22). Existing benchmarks within baseline variance.
- libro (15 pass) + vidya (19 pass) integration unchanged.

### Known
- **`CYRIUS_DCE=1` appears to be a no-op under Cyrius 5.5.x** — DCE and
  non-DCE builds of `build/demo` are byte-identical (180KB vs 130KB on
  1.2.0 / Cyrius 4.10.3). The compiler still reports 219 dead functions
  but does not remove them. This is a toolchain-side concern, not a
  Patra regression, but it inflates the binary and warrants a follow-up
  once the Cyrius 5.x DCE pass is understood.

## [1.2.0] - 2026-04-20

SELECT column-list projection + Cyrius 5.5 toolchain. On-disk format unchanged.

### Added
- **SELECT column list** (`SELECT col1, col2 FROM t`) — roadmap backlog #3.
  Projection runs after WHERE, ORDER BY, and LIMIT, so sorts and filters can
  reference columns not in the projection. Up to `MAX_COLS` (32) projected
  columns per query. Duplicate columns are allowed and emitted twice.
  Unknown column names cause `patra_query` to return 0 (null result set).
  `SELECT *` and aggregates are unchanged (`PR_PROJ_N = 0`).
- **5 new integration test groups + 1 parser test group** — 40 new
  assertions covering single-col, multi-col, reordered projection,
  WHERE/ORDER BY/LIMIT on non-projected cols, unknown col, and duplicate
  cols. 274 → 314 passed.

### Changed
- **Cyrius toolchain pin raised 4.10.3 → 5.5.18** (`.cyrius-toolchain`,
  `cyrius.cyml`). Clean compile, all tests/fuzz/benchmarks pass on the
  new toolchain. No source changes required.

### Validation
- 314 passed, 0 failed (was 274).
- 2 fuzz harnesses pass.
- 22 benchmarks within baseline variance (no projection-path regressions
  on existing `SELECT *` queries).
- libro (15 pass) + vidya (19 pass) integration unchanged.

## [1.1.1] - 2026-04-16

Indexed-query planner improvements. No API changes; on-disk format unchanged.

### Changed
- **Indexed-ref cap raised 256 → 1024** (`src/lib.cyr`). Range queries
  returning up to 1024 matching refs now take the index path instead of
  silently falling back to a full table scan on overflow. The 8KB ref
  buffer is transient per query (fl_alloc/free).
- **Selectivity-based planner gate** — after collecting refs from the
  B-tree, the query engine compares `nrefs` against `TBL_NROWS` (tracked
  per table). When `nrefs >= 128` **and** the index would return ≥50%
  of the table's rows, the engine falls back to a full scan. Avoids
  paying the B-tree walk when the index offers no I/O savings
  (duplicate-heavy or low-cardinality queries on small tables).

### Added
- **`select_idx_range_400_of_2000` benchmark** — 2,000 unique keys,
  range query returning 400 refs (20% selectivity). Demonstrates the
  #1 cap-raise win: previously capped out at 256 and scanned 2,000
  rows; now uses the index. Current result: ~274 µs.
- **21 → 22 benchmarks** (was 20 before 1.1.0 added the unique-keys
  case).

### Fixed
- **`select_idx_eq_500` duplicate-heavy workload** — previously relied
  on the 256-cap overflow fallback as a de-facto planner. With the cap
  at 1024 that fallback no longer triggered and the duplicate-heavy
  path became ~30 % slower than scan. The selectivity gate now routes
  this case to scan explicitly. Result: **~159 µs** (was 185 µs with
  #1 alone, 142 µs with cap-overflow fallback).

### Validation
- 274 passed, 0 failed (unchanged).
- 2 fuzz harnesses pass.
- 22 benchmarks.
- `multipage indexed` test still passes (50 rows sharing `id=1`): the
  selectivity gate correctly sends it to scan, which returns all 50
  rows as expected.

## [1.1.0] - 2026-04-16

### Changed
- **Manifest renamed** `cyrius.toml` → `cyrius.cyml` to match first-party
  convention (ark, nous, sigil). Toolchain pin moved into `[package]` as
  `cyrius = "4.10.3"`; `[toolchain]` section dropped.
- **CI/release workflows rebuilt** to mirror ark. `CYRIUS_VERSION` is now
  read from `.cyrius-toolchain` in both workflows (fixes a latent
  ci.yml/release.yml version mismatch: 4.10.3 vs 3.2.1). Release tag
  filter tightened from `'*'` to `'[0-9]*'` (semver-only).
- **Dead code elimination enabled** — every `cyrius build` invocation in
  CI and release now runs with `CYRIUS_DCE=1`. Applies to demo, fuzz
  harnesses, benchmarks, and integration binaries. Addresses roadmap
  backlog #1 ("60KB overhead — investigate dead code elimination").
- **Release artifacts expanded** — GitHub release now ships the source
  tarball, the bundled `patra-<tag>.cyr` single-file include, and the
  DCE-built demo binary, each listed in `SHA256SUMS`.

### Added
- **`cyrius lint` step in CI** — runs per-source-file lint across all
  ten `src/*.cyr` modules (non-fatal, advisory output).
- **Bundle regeneration in release** — `sh scripts/bundle.sh` runs during
  release to rebuild `dist/patra.cyr` from current sources and publish
  it as a release asset.

### Removed
- **`bp_flush()` no-op stub** — 1-line dead function in `src/page.cyr`
  plus its sole call in `src/lib.cyr:patra_open()`. Reserved for a
  buffer pool that was investigated and rejected in v0.10.0 (4x slower
  than OS page cache). No functional change.

### Validation
- 274 passed, 0 failed (unchanged).
- 2 fuzz harnesses pass.
- 21 benchmarks (was 20 — see below).

### Benchmarks
- **New: `select_idx_eq_unique_500`** — indexed equality on 500 rows with
  distinct keys. Measures the happy path the B-tree was designed for.
  Result: **61µs** vs `select_scan_500` at 100µs — indexed is ~39% faster.
- **Kept: `select_idx_eq_500`** — 500 rows all sharing `id=1`. B-tree hits
  the 256-ref cap, engine falls back to linear scan (correctness guard
  from v0.16.0). Measures fallback overhead, not index efficacy: 142µs
  vs scan 100µs — the B-tree walk is wasted work here, by design.
- The v0.8.0 CHANGELOG's "16% faster indexed SELECT" claim was measured
  on the duplicate-key benchmark before the v0.16.0 fallback existed and
  before v0.14.0 grew `COL_STR_SZ` from 64 to 256. No longer representative;
  superseded by `select_idx_eq_unique_500`.

## [1.0.0] - 2026-04-15

Patra 1.0 — the sovereign database is stable.

### Summary

Zero-dependency SQL database engine in pure Cyrius. 3,103 lines of source
across 10 modules, bundled as a single `dist/patra.cyr` include.

**SQL**: CREATE TABLE, DROP TABLE, CREATE INDEX, INSERT, SELECT, UPDATE,
DELETE. WHERE with 6 operators and AND/OR. ORDER BY (multi-column, ASC/DESC).
LIMIT. Aggregates: COUNT(*), SUM, MIN, MAX.

**Storage**: .patra file format with 4KB pages, B+ tree order-64 index,
free list page recycling. Values are i64 or 256-byte fixed strings.

**Durability**: Write-ahead logging with automatic crash recovery.
Transaction API (BEGIN/COMMIT/ROLLBACK). fdatasync on commit. WAL overflow
detection on transactions exceeding 64 pages.

**Concurrency**: flock advisory locking (exclusive writes, shared reads).

**JSONL**: Append-only JSON Lines mode with field extraction. libro-compatible.

### Validation
- 274 passed, 0 failed.
- 2 fuzz harnesses pass (fuzz_file, fuzz_sql).
- 20 benchmarks.
- Hardened: indexed UPDATE, DROP+recreate, rollback persistence, multi-page
  indexed queries all tested.

## [0.17.0] - 2026-04-15

### Added
- **Hardening tests** — 18 new assertions across 4 test groups:
  - UPDATE on indexed column (B-tree remove old key + insert new key)
  - DROP TABLE + recreate with different schema
  - Transaction rollback persistence across close/reopen
  - Multi-page indexed query (50 rows across ~4 pages)

### Fixed
- **`test_page_overflow` comment** — row size calculation updated to
  reflect 256-byte strings (was still referencing 64-byte era).

### Validation
- 274 passed, 0 failed (was 256).
- 2 fuzz harnesses pass.

## [0.16.0] - 2026-04-15

### Added
- **DROP TABLE** — `DROP TABLE name` removes a table, frees its data pages,
  schema page, and B-tree index root. Table directory is compacted.
- **WAL overflow detection** — transactions exceeding 64 page writes now
  set an overflow flag. `patra_commit()` returns `PATRA_ERR_FULL` when
  WAL capacity was exceeded (data is still committed, but crash-safety
  is degraded beyond the 64-page window).
- **B-tree index fallback on overflow** — when a range query returns the
  maximum 256 refs, the query engine falls back to linear scan to
  guarantee complete results.

### Validation
- 256 passed, 0 failed (was 240).
- 2 fuzz harnesses pass (fuzz_file, fuzz_sql).
- New tests: DROP TABLE (4 groups), WAL overflow (1 group).

## [0.15.0] - 2026-04-15

### Fixed
- **SQL parser: WHERE with no conditions** — `SELECT * FROM t WHERE`
  (trailing WHERE, no condition) was accepted as valid. Now returns
  `PATRA_ERR_PARSE`. Root cause: `_parse_where` returned successfully
  with count=0 after consuming the WHERE token. Added `count == 0`
  check before storing results.

### Changed
- **Toolchain min raised to 4.9.3** (was 3.3.5). CI updated to 4.10.3.
- **`cyrius.toml` updated** — added `[deps]` section with stdlib and
  sakshi deps. Added `[toolchain]` section.
- **Bundle script** — rewritten from bash to sh. All source files now
  have includes stripped (`grep -v "^include "`).
- **`.cyrius-toolchain`** — added, pinned to 4.10.3.

### Validation
- 240 passed, 0 failed.
- 2 fuzz harnesses pass (fuzz_file, fuzz_sql).
- Bundle compiles clean (3025 lines).

## [0.14.0] - 2026-04-11

### Changed
- **`COL_STR_SZ` raised from 64 to 256 bytes** — string columns now support up to 255 characters (was 63). Fixes truncation of SHA-256 hex hashes (64 chars), UUIDs (36 chars), and longer text fields. Breaking change for existing .patra files — databases created with 0.13.0 are not compatible (row layout changed).

## [0.13.0] - 2026-04-11

### Added
- **Bundled distribution**: `dist/patra.cyr` — single-file 3,013-line bundle for stdlib inclusion. No `include` statements, no SHA-256, no stdlib dependencies baked in. Consumers provide their own stdlib.
- **`scripts/bundle.sh`** — generates `dist/patra.cyr` from source modules in dependency order.

### Changed
- Patra is now distributable as a stdlib dependency via `dist/patra.cyr`. Projects like libro can `include "lib/patra.cyr"` without SHA-256 conflicts (sigil handles crypto, patra handles storage).

## [0.12.0] - 2026-04-10

### Removed
- **`src/sha256.cyr`**: Hand-rolled SHA-256 (161 lines) deleted. Was included in build but
  never called by any database module. Crypto is sigil's responsibility — available as
  `lib/sigil.cyr` in the cyrius stdlib.
- SHA-256 known-answer tests removed from `patra.tcyr` (3 assertions).

### Changed
- Minimum Cyrius version pinned to 3.3.5 in cyrius.toml.

## [0.11.1] - 2026-04-09

### Changed
- Stdlib distribution formatted via cyrfmt
- Version bump for cyrius 3.2.5 stdlib inclusion

## [0.11.0] - 2026-04-09

### Added

- SHA-256 hash (FIPS 180-4): `sha256(data, len, out)`, `sha256_hex(data, len, out)`
  - Verified against NIST test vectors ("", "abc", "hello")
- Write-ahead logging (WAL): page before-images logged before modification
  - Automatic crash recovery on patra_open (replays WAL if present)
  - Max 64 pages per transaction, dedup to avoid double-logging
- Transaction API: `patra_begin(db)`, `patra_commit(db)`, `patra_rollback(db)`
  - Rollback restores all pages modified in the transaction
  - Without BEGIN/COMMIT, each patra_exec is auto-committed (existing behavior preserved)
- fdatasync on WAL commit for durability guarantee

### Testing

- 243 unit tests across 61 test groups
- SHA-256 FIPS test vectors
- Transaction commit persistence + rollback verification

## [0.10.0] - 2026-04-09

### Added

- CREATE INDEX ON table (col) — index any INT column, populates from existing rows
- Aggregate queries: SELECT COUNT(*), SUM(col), MIN(col), MAX(col) with WHERE support
- Multi-column ORDER BY: `ORDER BY age DESC, name ASC` — up to 8 columns
- JSONL field extraction: jsonl_get_str(), jsonl_get_int() — parse fields from JSON lines

### Investigated

- Buffer pool (16-slot write-through page cache) — reverted. 4x slower due to memcpy overhead. OS page cache is sufficient for current workloads.

### Testing

- 237 unit tests across 58 test groups

## [0.9.0] - 2026-04-09

### Added

- Multi-column ORDER BY: `ORDER BY age DESC, name ASC`
- ASC/DESC per column in ORDER BY
- B-tree index maintenance on UPDATE (remove old ref, insert new ref when indexed column changes)
- fdatasync after header writes and JSONL appends (durability guarantee)

### Testing

- 212 unit tests across 54 test groups
- Multi-column sort tests with mixed ASC/DESC

## [0.8.0] - 2026-04-09

### Added

- .patra file format: 4KB pages, "PTRA" magic header, free list page recycling
- Page manager: alloc, read, write, free list
- Row encoding: i64 + 64-byte fixed strings, null-padded
- SQL parser: recursive descent tokenizer with case-insensitive keywords
  - CREATE TABLE, INSERT, SELECT, UPDATE, DELETE
  - WHERE (=, !=, <, >, <=, >=) with AND/OR
  - ORDER BY (ascending, single column), LIMIT
- B+ tree index: order-64, auto-created on first INT column
  - Insert with leaf and internal node splitting
  - Search (exact key, duplicate support), range scan
  - Indexed SELECT for equality AND range queries (>, >=, <, <=)
  - AND range combination (e.g., `id > 1 AND id < 5` → single B-tree range [2,4])
  - 16% faster indexed SELECT vs full scan on 500 rows (198us vs 235us)
- JSON Lines mode: append-only JSONL storage with flock
  - JSON object builder with string escaping
  - libro-compatible audit log backend
- flock advisory locking: exclusive for writes, shared for reads
- Result set API: count, get_int, get_str, col_name, col_type, free
- sakshi integration: structured tracing via Cyrius stdlib (>= 3.2.1)
- CI/CD: GitHub Actions workflows for build, test, fuzz, bench, security scan, release

### Fixed

- `jsonl_append` now checks write return value, returns PATRA_ERR_IO on failure
- `_json_escape` bounds overflow guard added
- `page_alloc` propagates page_read errors from free list
- `_exec_update` only writes header on success (was writing unconditionally)
- Index column bounds check in insert and query paths
- OR queries correctly fall back to linear scan (was using index for first condition only)

### Testing

- 194 unit tests across 52 test groups
- 2 fuzz harnesses (SQL parser + malformed file invariants)
- 20 benchmarks (SQL parsing, page I/O, B-tree, INSERT, SELECT, UPDATE, DELETE, JSONL, ORDER BY)
- Integration tests: libro audit log, vidya knowledge index

### Known Limitations

- DELETE/UPDATE do not update the B-tree index (stale refs filtered by verification)
- Only first INT column is auto-indexed (no CREATE INDEX syntax)
- No JOINs, subqueries, or aggregates
- No crash recovery (WAL) or transaction semantics (BEGIN/COMMIT)
