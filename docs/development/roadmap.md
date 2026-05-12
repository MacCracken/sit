# sit Development Roadmap

> **v0.7.x active.** v0.7.0–v0.7.5 shipped between 2026-04-25 and 2026-05-08, taking the line from sandhi-fold toolchain pickup through working clone over `http://` with batched fetch. **v0.7.6 (HTTP push + bearer auth + ADR 0007) shipped 2026-05-08** — symmetric round trip over HTTP closed; server rehashes every uploaded object; `~/.sit/serve.token` (0600) bearer auth gates writes when `--require-auth` is set. The load-bearing decision is in [ADR 0007](../adr/0007-network-transport-security.md): **no libssl, no libcrypto, no exception**. HTTPS via libssl will not ship in sit until/unless first-party Cyrius TLS exists. **v0.7.7 inserted 2026-05-08** as a non-transport beat — `dist/sit.cyr` library export + diff-primitive cleanup, requested by owl during its 1.2.x cascade as the upstream blocker for the SIT VCS swap on its own roadmap; SSH bumped to v0.7.8. Consequently the v0.7.x line ends at SSH (v0.7.8) for encrypted-over-internet — process-boundary, not FFI. mTLS / HTTPS were dropped from the v0.7.x slot table; they're "blocked on first-party Cyrius TLS *existing*", not numbered releases. The v0.6.x perf arc closed at v0.6.12 (cumulative `add-1MB -48%`, `add-64KB -43%`, `clone -30%`, `log -17%`, `status -9%`).

Historical per-sub-version notes were collapsed into the 0.4.0 entry; see [`CHANGELOG.md`](../../CHANGELOG.md) for the tagged artifacts.

## Released

### v0.7.6 — HTTP push + bearer auth + ADR 0007 (no libssl, ever)

- **Closes the symmetric round trip over HTTP.** `sit push origin main` works end-to-end against `sit serve` over `http://...`. Server-side `POST /sit/v1/objects/<hex>` rehashes every uploaded object (sigil's `hash_data` over the full `<type> <len>\0<content>` frame) and refuses on hex mismatch — the trust boundary for client→server data. `POST /sit/v1/refs/<refname>` fast-forward gates `refs/heads/*`, treats `refs/tags/*` as immutable (any non-equal update = 409 Conflict), refuses `refs/remotes/*` always.
- **[ADR 0007](../adr/0007-network-transport-security.md) is the load-bearing decision.** Sit's no-FFI thesis is non-negotiable. The `lib/tls.cyr` path (libssl.so.3 via fdlopen) punches the same FFI hole [ADR 0001](../adr/0001-no-ffi-first-party-only.md) explicitly forbids. Five alternatives considered + rejected; HTTPS via libssl is not on the v0.7.x roadmap and won't ship until first-party Cyrius TLS exists. SSH is the canonical encrypted-over-internet transport (sit consumes the SSH binary as a process boundary, not an FFI dep — same separation as git's ssh:// support).
- **Bearer auth** via `~/.sit/serve.token` (0600). `--require-auth` flag in `cmd_serve`; `_serve_load_token` enforces strict 0600 perms + ≥16 chars + no control bytes + refuses to start on any failure (auth posture is "strictly enforced or absent," never silent fall-through). `_serve_auth_ok` does constant-time compare across `max(presented_len, token_len)` so timing doesn't leak prefix matches. Capabilities advertise `"auth":["bearer"]` when `--require-auth`, `"auth":["none"]` otherwise; `"push":true` always. Read endpoints stay anonymous in both modes.
- **Client side**: `cmd_push` branches on URL scheme. `_do_push_http` runs the full pipeline — capabilities probe → optional `~/.sit/serve.token` load → FF preflight via `http_remote_resolve_branch` → `walk_reachable_phased` → per-object `http_remote_push_object` → `http_remote_push_ref`. "everything up-to-date" short-circuit when `remote_tip == local_tip`. Counts only fresh inserts (201) in the summary, not idempotent already-present (200). Helpful error when client missing token but server requires bearer.
- **CI smoke step** generates a 0600 token, asserts capabilities advertise bearer, asserts 401 on no-auth POST, runs full push + verify, asserts "everything up-to-date" on re-push, asserts anonymous clone still works against the auth-required server, asserts client without token fails with the documented error message.
- **127/127 tests pass.** Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`. DCE binary: **1.30 MB** x86_64, 1.43 MB aarch64. file:// wire smoke (clone + push + re-clone) clean — no regression. End-to-end smoke verified all four bearer auth cases (capabilities advertise correctly, 401 without auth, 401 with wrong token, success with right token) plus the anonymous-read-against-auth-required-server case and the client-without-token error path.
- **Roadmap impact**: mTLS (was v0.7.7) and HTTPS (was v0.7.6) dropped from the v0.7.x slot table — both blocked on first-party Cyrius TLS that doesn't exist. SSH (was v0.7.8) moves up to v0.7.7 as the v0.7.x line's encrypted-over-internet path; v0.7.x ends at SSH.
- **No issue archived this release.**

### v0.7.5 — Walk-side phasing + cache-aware tree walk + frame-decoder fuzz

- **Realises the v0.7.4 protocol scaffolding into actual clone speedup.** `walk_reachable_phased` replaces the sequential `walk_reachable_from_commit` (which is now deleted along with `walk_reachable_tree`, ~95 lines of dead code). Three phases: phase 1 walks the commit chain sequentially collecting (commit_hex, tree_hex) pairs; phase 2 batch-prefetches every tree hex via `POST /sit/v1/want` (one POST per `WIRE_HTTP_BATCH_CHUNK = 256` chunk); phase 3 walks each tree from `raw_cache` via the new cache-aware `walk_reachable_tree_batched`. Per-level sub-tree batching for nested directories. `obj_src_batch_prefetch` re-enabled in `copy_objects` (held in v0.7.4). For OBJ_SRC_DB the batch hooks are no-ops so file:// is unchanged.
- **`_decompress_raw_into(raw, deco_out)`** extracted from `db_object_read_both`. Cache-aware tree walker checks `raw_cache` first; on hit, decompresses cached compressed bytes directly without going back to the transport — **the load-bearing fix that turned the phasing from a regression (220 ms with batch on but cache unconsulted) into a real win (185 ms with cache-first)**. Without this, phase 2's batch-prefetch was pure overhead because phase 3's `obj_src_read_both` re-fetched every tree it had just batched.
- **Frame-decoder fuzz target** in `tests/sit.fcyr` — `_wire_http_decode_frames` extracted from `http_remote_read_batch` so the harness drives the parser without a TCP socket. **10,000,000 iterations clean** through pseudo-random bytes (~46 s on the bench host) — no crashes, OOB reads, infinite loops, or oversized allocs. Validation invariants documented in the function's doc-comment: header fits, hex passes `hex_prefix_valid`, `0 ≤ ty ≤ 2`, `0 < clen ≤ 16 MiB`, `off + 80 + clen ≤ blen`. Fuzz harness now `include "src/lib.cyr"` (DCE strips everything not reached from `main`).
- **Bench (100-commit / 100-file fixture, 10 runs each, median)**: v0.7.4 baseline 213 ms → v0.7.5 phased + cache-aware **185 ms (−13%)** on loopback. Per-RT cost extracted from the bench: 0.14 ms/RT (28 ms saved by replacing 198 round trips). Loopback is structurally too fast for batching to dominate — per-frame allocation + parsing overhead is comparable to per-RT cost. The gate was set at realistic RTT, not loopback:

  | RTT | v0.7.4 ms | v0.7.5 ms | Speedup | Gate? |
  |----:|---:|---:|---:|:--:|
  | 0.14 ms (loopback measured) | 213 | 185 | 13% | ✗ |
  | 0.5 ms (very fast LAN) | 321 | 222 | 31% | ✓ |
  | 1 ms (typical LAN) | 471 | 273 | **42%** | ✓ |
  | 2 ms (home / cable) | 771 | 375 | 51% | ✓ |
  | 5 ms (regional internet) | 1668 | 680 | 59% | ✓ |

  Projection methodology: each variant has a fixed per-RT count (300 for v0.7.4, 102 for v0.7.5 = 100 commit GETs + 1 cap probe + 1 tree POST + 1 blob POST). Above-loopback RTT contributes (RTT − 0.14) ms × per-RT count to the wall clock; everything else (patra inserts ~90 ms, decompression ~30 ms, file materialization, etc.) stays constant.
- **127/127 tests pass.** file:// wire smoke (clone + push + re-clone) clean, no regression vs v0.7.4. aarch64 cross-build clean (1.41 MB ELF). DCE binary: **1.29 MB** (essentially flat from v0.7.4's 1.28 MB — phased walker code now live, replaces ~95 deleted lines).
- **No issue archived this release.**

### v0.7.4 — `POST /sit/v1/want` protocol scaffold (no perf change)

- **Wire-protocol scaffolding release.** Server endpoint `POST /sit/v1/want` lights up in `serve_handle_want` (`src/serve.cyr`): fixed-shape request body validation (`[8B count][count*64 hex]`), `SIT_WANT_MAX_COUNT = 512` cap (binding constraint is sandhi's `HSV_REQ_BUF_SIZE = 64 KiB` request buffer), `hex_prefix_valid` pre-pass on every requested hash, growing fl_alloc response buffer with per-frame emission per ADR 0006. Status mapping: 200 happy / 400 length-or-hex mismatch / 411 missing Content-Length / 413 over `SIT_WANT_MAX_COUNT` or `SIT_SERVE_MAX_BODY` / 500 DB or OOM. Capabilities now advertise `"batch":true,"batch_max":512`.
- **[ADR 0006](../adr/0006-batched-want-frame-format.md)** pins the wire format. Request: `[8B i64 LE count][count × 64 ASCII hex hashes]`. Response: concatenated frames `[64 hex][8B i64 LE ty][8B i64 LE clen][clen bytes compressed]`. LE because cyrius is x86_64/aarch64 first and patra stores LE on disk — no per-read byteswaps. Hashes the server doesn't have are silently omitted from the response; clients detect via short-count and demote to per-object GET fallback. Trust boundary unchanged from v0.7.3 — server doesn't recompress, client doesn't re-hash, `sit fsck` is the canonical roundtrip.
- **Client primitives in `src/wire_http.cyr`** (`_wire_http_post`, `http_remote_check_batch`, `http_remote_read_batch`) and the `obj_src_batch_prefetch` dispatcher in `src/wire.cyr` exist in source but are intentionally **not called from `copy_objects`** — DCE-stripped because the integration is held for v0.7.5+. Handle layout extended 16 → 32 bytes (adds `batch_probed` + `batch_supported` fields) so the cap probe runs once per fetch when v0.7.5 plumbs it in.
- **Why no perf change in v0.7.4.** With the batch wired into `copy_objects`, the measured speedup on the 100-commit / 100-file loopback fixture was **7%** (213 → 198 ms median, 10 runs). The blob batch saves ~15 ms; the remaining 198 ms is dominated by the walk's 200 sequential GETs for commits + trees (~30 ms total at ~0.15 ms/loopback-RT) and patra's batched-but-still-load-bearing object inserts (~90 ms — the v0.6.5 transaction-wrap floor). Per the v0.7.4 ≥30%-or-revert gate, the perf-affecting integration is held; the wire surface ships as scaffolding so v0.7.5 can extend without re-doing wire work. The real-network picture is different — at 1 ms RTT, replacing 99 GETs with 1 POST saves ~99 ms, comfortably exceeding 30%; loopback understates the win, and v0.7.5 will measure with realistic latency.
- **Smoke verified end-to-end.** `curl -X POST /sit/v1/want` round trips: 200 happy path with full frame body; 411 on zero-length body; 400 on count/length mismatch; 400 on non-hex hash; 413 on count > 512. Per-object http clone unchanged from v0.7.3 (213 ms median, `sit fsck` 300/300 clean, log byte-identical to file:// clone).
- **127/127 tests pass.** Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`. DCE binary: **1.28 MB** (slightly smaller than v0.7.3's 1.30 MB because more of the v0.7.4 code is currently DCE-stripped scaffolding than v0.7.3 added in live functions).
- **No issue archived this release.**

### v0.7.3 — HTTP client transport (fetch + clone over `http://`)

- **Closes the v0.7.x server/client read-only round trip.** `GET /sit/v1/objects/<hash>` lights up on the server side (raw compressed bytes, `X-Sit-Type: <patra-ty>` response header, 400/404/413 status mapping that doesn't leak miss-vs-error). `src/wire_http.cyr` (530 lines) lights up on the client side (sit-side HTTP/1.0 built directly on `lib/net.cyr` to dodge stdlib `http_get`'s 64 KiB recv cap; growing fl_alloc-backed recv buffer up to 16 MiB matching `db_object_read_both`'s decompression ceiling). `wire_transport_check_readable` (file + http) and `wire_transport_check_writable` (file only — push over http is v0.7.5+) replace the v0.7.1 single-shape check.
- **`obj_src` abstraction** in `src/wire.cyr` — 16-byte tagged handle (`OBJ_SRC_DB` / `OBJ_SRC_HTTP` + payload pointer); `walk_reachable_*` and `copy_objects` now run unchanged over either transport. The roadmap's "HTTP-backed `db_object_read_both` shim" lands as `obj_src_read_both` dispatching into either the patra reader or the http one. The walk-cache (P-04, v0.6.7) is transport-independent and benefits HTTP fetches identically.
- **`do_fetch`** branches on URL scheme: file:// + bare paths still call `remote_objects_open` for the patra source; `http://` URLs call `wire_http_open` and resolve the branch via `http_remote_resolve_branch`. **`cmd_clone`** target-derive: file:// + bare paths take the last path segment; `http://` URLs take the host (port + path stripped). The walk + copy pipeline downstream is fully transport-independent.
- **Toolchain**: cyrius 5.8.51 → **5.9.37** — picks up the cc5_aarch64 cap-propagation fix that was filed during the v0.7.2 release run. cc5_aarch64 grew 438896 → 449624 bytes; `cyrius build --aarch64 src/main.cyr build/sit-aarch64` now produces a 1.45 MB statically-linked aarch64 ELF without firing the workflow's best-effort swallow.
- **Stdlib**: `[deps].stdlib` unchanged from v0.7.2 — the new HTTP client uses `net` directly and `sandhi`'s `sandhi_net_parse_ipv4` indirectly, both already present.
- **Smoke gate met**: 100-commit / 100-file fixture, `sit clone http://127.0.0.1:8484` → `sit fsck` reports `300 objects, 0 bad`, log byte-identical to a `file://` clone of the same fixture. **211 ms (http) vs 167 ms (file) = 1.26×** — success gate was 3×.
- **127/127 tests pass.** CI gains a `sit serve + http clone + fsck` step alongside the existing file:// wire smoke. DCE binary: **1.30 MB** (vs 1.28 MB at v0.7.2; +18 KB net for the HTTP client). Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`.
- **2026-05-04 issue archived RESOLVED**: [`issues/archived/2026-05-04-cyrius-cc5-aarch64-token-cap-not-propagated.md`](issues/archived/2026-05-04-cyrius-cc5-aarch64-token-cap-not-propagated.md). Verified at cyrius 5.9.37; the consumer-side workaround in `.github/workflows/release.yml` is no longer load-bearing for sit but stays in place as defence against future aarch64 backend regressions.

### v0.7.2 — `sit serve` skeleton (read-only HTTP) + sandhi opt-in

- **First feature-bearing release of the v0.7.x network-transport line.** Two endpoints live: `GET /sit/v1/capabilities` (server identity + advertised limits) and `GET /sit/v1/refs` (every `.sit/refs/heads/*` and `.sit/refs/tags/*` that passes `refname_valid` and resolves to a 64-hex hash; nested ref names like `refs/heads/feature/foo` work via `dir_walk` recursion). 404 on unknown paths and on POST (read-only, GET-only).
- **`sit serve <repo> [--listen 127.0.0.1:<port>]`** — loopback-only HTTP daemon, default port 8484. One repo per process; `chdir`s into `<repo>` before serving. `--listen` is parse-locked to `127.0.0.1:<port>` in v0.7.2; non-loopback exposure is gated on the auth model that arrives in v0.7.5+ (push + bearer).
- **`src/serve.cyr`** (255 lines) — wired into `src/lib.cyr`. Hand-rolled JSON builders; uses sandhi server primitives (`sandhi_server_run`, `sandhi_server_get_method`, `sandhi_server_get_path`, `sandhi_server_path_only`, `sandhi_server_send_response`, `sandhi_server_send_status`) + `INADDR_LOOPBACK()` from `lib/net.cyr`. `cmd_serve` + usage line in `src/main.cyr` — command count: **24 → 25**.
- **Toolchain**: cyrius 5.7.1 → **5.8.51**. Spans 95+ patches; the load-bearing changes are v5.8.46 (token-array cap raise 262144 → 1048576, plus the `needed M, cap is N` diagnostic that sized the bump) and v5.8.39 (sandhi v1.1.0 vendored into stdlib with per-request-arena Allocator-aware `_a` verbs).
- **Stdlib opt-in**: `[deps].stdlib` adds `"net"`, `"tls"`, `"ws"`, `"http"`, `"json"`, `"sandhi"`. Only `sandhi` (server bits) and `net` (`INADDR_LOOPBACK`) are directly called; the rest are sandhi's transitive needs (no cyrius transitive stdlib resolution today).
- **`wire_transport_check` error strings synced** for v0.7.2: `http` → `0.7.3+` (server-side ships in 0.7.2 but the wire.cyr path is the *client*; HTTP CLIENT lands in 0.7.3 per the table below); `https` → `0.7.6+` and `ssh` → `0.7.8+` pointers unchanged; `(this is 0.7.1)` → `(this is 0.7.2)` everywhere.
- **Two sit-side bugfixes caught in smoke** (4-ref fixture: 3 heads incl. `feature/foo` nested + 1 tag): `serve_read_ref_file` `<= 0` → `< 0` (`read_file_heap` returns `0` on success, negative on error — the original check rejected success); `serve_emit_refs_subtree` Str/cstring boundary on `dir_walk` (the function expects a `Str` object and pushes `Str` objects into the results vec; the original code passed and read raw cstrings, so the walk silently returned 0 entries). Fix wraps in `str_from(dir)` and uses `str_len`/`str_data` to read the entries; matches the pattern every other `dir_list` caller in sit (`refs.cyr`, `object_db.cyr`, `diff.cyr`, `wire.cyr`) already follows.
- **127/127 tests pass.** DCE binary: 707 KB (v0.7.0) → **1.28 MB** (v0.7.2; +576 KB / +82%). Sandhi opt-in is the dominant driver — DCE strips most of the ~10K-line sandhi.cyr but the residue is real.
- **2026-04-25 issue archived RESOLVED**: [`issues/archived/2026-04-25-cyrius-fixup-table-cap.md`](issues/archived/2026-04-25-cyrius-fixup-table-cap.md). Original 32,768 → 262,144 cap raise (v5.7.1) was insufficient; v5.8.46's 4× raise to 1,048,576 was sized to the empirical M from the new diagnostic. The two distinct caps the issue conflated (fixup-table vs token-array) turned out to require separate handling.

### v0.7.1 — URL scheme detection + transport dispatch stubs

- **`url_scheme(url)`** + **`url_authority_path_valid(s, len)`** in `src/validate.cyr`; **`wire_transport_check(url)`** in `src/wire.cyr`. URL classification covers `file://` / `http://` / `https://` / `ssh://` / bare paths; whitelist body validator accepts `[a-zA-Z0-9.-_/:@%~]` (rejects shell metachars + leading dash for second-layer CVE-2017-1000117 defense).
- **`remote_url_valid()` extended** to accept http/https/ssh URLs that pass control-char + leading-dash + body-whitelist gates. URLs validate at remote-add time so users wire config in advance; transport itself ships in later v0.7.x patches.
- **`cmd_clone` / `do_fetch` / `cmd_push`** dispatch on URL scheme after validation. Network schemes return rc 1 with per-scheme version pointers (`http transport requires sit 0.7.2+`, `https → 0.7.6+`, `ssh → 0.7.8+`); file/path schemes proceed unchanged.
- **127/127 tests pass** (101 + 26 new). `fuzz_url_validators` runs 10K rounds clean on `url_scheme` + `remote_url_valid`; debug surfaced a Cyrius missing-include footgun (undefined fn refs compile clean, SIGILL at call site) — fuzz file now `include "src/validate.cyr"` explicitly.
- **Sandhi opt-in deferred** to v0.7.2 — adding `"sandhi"` to `[deps].stdlib` requires co-adding `net`/`tls`/`ws`/`http`/`json` (sandhi pulls `SYS_SETSOCKOPT` etc.). Per "ONE change at a time," that whole block lands alongside v0.7.2's first real sandhi caller (`sit serve`).
- DCE binary: 709 KB (+2 KB vs 0.7.0; new validators + dispatch helper).

### v0.7.0 — sandhi-fold toolchain unlock, v0.7.x line opens

- **Minor-line opener.** Toolchain-only — picks up cyrius 5.7.0 ("the sandhi fold"; `sandhi` v1.0.0 vendored into stdlib as `lib/sandhi.cyr`, `lib/http_server.cyr` deleted from stdlib per [sandhi ADR 0002](https://github.com/MacCracken/sandhi/blob/main/docs/adr/0002-clean-break-fold-at-cyrius-v5-7-0.md)).
- **Removed**: stale local `lib/http_server.cyr` orphan (15579-byte regular-file copy of the pre-fold stdlib snapshot; zero callers in sit). Cyrius 5.7.0's downstream worklist names "delete orphan only" as the action for sit.
- No sit source changes. Build clean, 101/101 tests pass, DCE binary 707 KB (down from 710).
- v0.7.x architectural settle: sit-native JSON/REST wire protocol under `/sit/v1/...` (reject git-smart-HTTP — wrong hash, can't carry raw compressed bytes), `sit serve <path>` daemon (one repo per process), bearer-token auth (`~/.sit/serve.token`, 0600), TLS in v0.7.6, SSH in v0.7.8.

### v0.6.12 — sigil SHA-NI + sankoch 2.1 throughput release (biggest single-release win)

- Pure dep-bump release: **cyrius 5.6.40 → 5.6.43**, **sigil 2.9.1 → 2.9.3** (SHA-NI hardware path), **sankoch 2.0.3 → 2.1.0** (DEFLATE micro-tuning). No sit source changes.
- **Sigil SHA-256 throughput up 32×** on 64 KB inputs (5.153 ms → 161 µs). Cascades into `sit add`:
  - **`add-64KB` -41%** (16.40 ms → 9.62 ms; sit/git ratio 4.5× → **2.55×**)
  - **`add-1MB` -48%** (211.52 ms → 112.39 ms; sit/git ratio 12.5× → **6.50×**)
  - `status-100files` -8% (sigil portion was small relative to file I/O at this scale)
- Sankoch 2.1.0's standard zlib path moves modestly (~5-7% on compress, within noise on decompress); larger sankoch 2.x match-finder / ring-buffer / SIMD work queued for follow-up sankoch releases. The remaining `add-1MB` budget is now ~140 ms of `zlib_compress(1MB)` — exactly what sankoch's roadmap is targeting next.
- Cumulative 0.6.0 → 0.6.12: `add-1MB **-48%**`, `add-64KB **-43%**`, `clone **-30%**`, `log **-17%**`, `status **-9%**`. The `add-1MB` ratio drop from 12.5× to 6.5× is the largest user-visible improvement of the v0.6.x arc.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.12.md`](../benchmarks/2026-04-25-v0.6.12.md).

### v0.6.11 — P-20 + multi-insert-transaction investigation (negative result)

- **P-20**: `parse_index` query gains `ORDER BY path`. Downstream `sort_entries` is now O(N) on already-sorted input instead of O(N²) on unsorted. Saves ~50µs at 100 entries, ~5ms at 1K, ~500ms at 10K. No 100-fixture bench movement (under noise floor at this scale).
- **Investigated and reverted**: multi-insert transaction wraps on `cmd_commit` (tree + commit) and `rewrite_index` (DELETE + N INSERTs). A/B measured 5-10% regression on a 50 add+commit cycle workload. patra's per-transaction setup/teardown (~30µs) exceeds saved fsyncs at small batch sizes on modern SSDs (where per-insert fsync is already kernel-batched). The pattern that worked for `copy_objects` (300+ inserts amortized one setup) doesn't generalize to 2-3-insert batches. Reverted before shipping; full investigation in [`docs/benchmarks/2026-04-25-v0.6.11.md`](../benchmarks/2026-04-25-v0.6.11.md).
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.11.md`](../benchmarks/2026-04-25-v0.6.11.md).

### v0.6.10 — dep bumps + S-31 closeout

- **cyrius 5.6.35 → 5.6.40**, **patra 1.6.0 → 1.8.3**.
- **S-31 RESOLVED**: `parse_index` now calls `patra_result_get_str_len(rs, i, 0)` directly (patra 1.6.1 API) instead of the v0.6.3 `strnlen(s, 256)` workaround. Helper deleted.
- **patra 1.7.0 `INSERT OR IGNORE`**: filed but not consumed (SQL-level only; sit's BYTES-column inserts use `patra_insert_row` which doesn't expose the flag).
- **patra 1.8.x WAL group commit (`PATRA_SYNC_BATCH`)**: investigated, reverted before shipping. No measurable bench gain (`copy_objects` already uses explicit transactions; `cmd_commit` doesn't trip the every-64-writes auto-flush; cached handle never closes so BATCH-pending writes would sit in the kernel writeback window across a power loss). Reasoning documented at both `get_object_db` and `get_index_db` call sites for future revisit.
- **No bench movement.** Cumulative 0.6.0 → 0.6.10 unchanged from v0.6.9: `log -18%`, `clone -31%`.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.10.md`](../benchmarks/2026-04-25-v0.6.10.md).

### v0.6.9 — P-06 + P-15: sit-side v0.6.x perf arc closed

- **P-06 — smarter decompression sizing.** Three sites (`read_object`, loose-migration path, `db_object_read_both`): initial multiplier dropped from 16× to 4× (most sit objects fit at ratio ~2-3); retry only on confirmed `-ERR_BUFFER_TOO_SMALL` (other negative codes mean the stream is genuinely corrupt — more memory won't help, fail fast). 75% memory reduction in the decompression-buffer alloc for objects with `blen > 1024`; bench fixture's tiny objects don't show it (4096-byte floor dominates).
- **P-15 — LCS DP table to `fl_alloc`.** `src/diff.cyr:lcs_diff` allocates via `fl_alloc` (mmap-direct for large allocs) and `fl_free`s before returning. Previously the up-to-128MB table squatted on the bump heap for the life of the process; now it goes back to the kernel after the computation. Pure memory hygiene.
- **No synthetic-bench movement** (both items are hygiene/edge-case). Final v0.6.x cumulative scoreboard: `log` **-18%**, `clone` **-30%**.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.9.md`](../benchmarks/2026-04-25-v0.6.9.md).
- **Sit-side v0.6.x perf arc closed.** Every P-NN audit item targeting sit-side code is shipped or explicitly out of scope (see backlog below). Next sit-side headline-mover requires upstream work — see "Waiting on dep updates" subsection.

### v0.6.8 — P-17: buffered stdout

- 206 `syscall(SYS_WRITE, STDOUT, ...)` sites across 9 src files swapped to a single buffered `stdout_write(data, len)` helper backed by a 64KB heap buffer (`src/util.cyr`). Auto-flush on buffer-full; large writes go straight to the kernel after flushing pending bytes. `main.cyr` trailer flushes before `SYS_EXIT`. STDERR stays direct.
- `write_sanitized` rewritten to build a sanitized copy in one heap buffer + single `stdout_write` (was emitting one byte per syscall + bypassing the buffer entirely). Caught an output-ordering bug introduced by the bulk swap (`print_commit_header` was emitting author bytes before the "Author: " prefix because `write_sanitized` was unbuffered while the surrounding writes were); fixed in the same change.
- **No measurable bench movement** on the 100-file synthetic — the `diff-edit` fixture only emits ~30 writes per run. Real win at scale (1000+ line diffs ~ 1000+ syscalls collapsed). Structural improvement (lower syscall pressure, in-order output guarantee).
- Cumulative 0.6.0 → 0.6.8: `log` **−17%**, `clone` **−32%**.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.8.md`](../benchmarks/2026-04-25-v0.6.8.md).

### v0.6.7 — P-04: walk-reachable compressed-bytes cache

- New `db_object_read_both(db, hex, raw_out, deco_out)` in `src/wire.cyr` returns BOTH compressed (formerly thrown away after the internal call) AND decompressed view. `db_object_read_decompressed` becomes a thin wrapper.
- `walk_reachable_tree` + `walk_reachable_from_commit` gained a `raw_cache` parameter; they call `db_object_read_both` and stuff the raw bytes into the cache keyed by hex. `copy_objects` checks cache first; cache misses (blobs only — walk doesn't visit them) fall back to `db_object_read_raw`. Caller (`do_fetch`, `do_push`) creates a fresh `map_new()` per operation and passes it through.
- **Win**: `sit clone-100commits` **−21.7%** (215.27 → 168.53 ms min, 13.64x git → 11.08x git). 500 source SQL ops → 300 (−40%). Other ops within noise.
- Cumulative 0.6.0 → 0.6.7: `log` **−16%**, `clone` **−32%**.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.7.md`](../benchmarks/2026-04-25-v0.6.7.md).

### v0.6.6 — P-10 + P-18: hashmap-backed lookups

- **P-10**: `src/tree.cyr:tree_find` lazily builds a name → entry hashmap per entries vec, cached by vec pointer for the process lifetime. Hot callers (`cmd_status`, `cmd_diff`, `materialize_target`, merge three-way loops) drop from O(N²) total to O(N).
- **P-18**: `three_way_path_set` dedups via `map_has` instead of a nested `streq` scan over the growing paths vec. ~4.5N² streqs → 3N hashmap ops.
- **Bench**: no measurable improvement on the 100-file fixture — too small to show — but the change is real and substantial at repo scale. Concrete projection: 1000-file `cmd_status` ~5ms → ~0.3ms on the tree_find piece; 10000-file repo ~50×.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.6.md`](../benchmarks/2026-04-25-v0.6.6.md).
- Cumulative 0.6.0 → 0.6.6: `log` **-12%**, `clone` **-13%**, everything else noise (dep-side bound).

### v0.6.5 — P-03: `copy_objects` batched transaction

- `src/wire.cyr:copy_objects` now wraps the insert loop in `patra_begin` / `patra_commit` (collapses N WAL fsyncs into 1) and drops the outer redundant `db_object_has` check (`db_object_insert_raw` already does the check internally — every object was paying for 2 SELECTs instead of 1).
- Side-effect counting fix: `db_object_insert_raw` returns `1` when the object was already present, `0` when actually inserted, negative on error. `copy_objects` increments `copied` only on `== 0`. Without this, `sit push` reported all reachable objects as "new" after a clone (caught by wire smoke).
- **Win**: `sit clone-100commits` **−15%** (245.19 → 208.44 ms min, 16.13x git → 13.82x git). Other ops within noise.
- Bigger clone wins still on patra's roadmap (`WAL group commit`, `UPSERT`) — when those land, a follow-on sit release can drop the manual transaction wrapping AND the inner has-check; expected combined improvement another ~30-50% on top of v0.6.5.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.5.md`](../benchmarks/2026-04-25-v0.6.5.md).

### v0.6.4 — First v0.6.x perf release: patra-handle caching + S-24 fold-in

- Process-wide cached handles for `.sit/objects.patra` (`get_object_db()`) and `.sit/index.patra` (`get_index_db()`). Collapses **P-01, P-02, P-05, P-08, P-12, P-25** — every `read_object` / `write_typed_object` / `resolve_hash` previously did patra_init + patra_open + CREATE TABLE + loose-migration check + patra_close on every call. Now: open + migrate once per process; reuse forever; fd dies with the process.
- **S-24 fold-in**: read_object's single-exit shape fell out for free once the open/close pattern was gone. SQL-string buffers in object_db.cyr swapped from `alloc_or_die` (bump-heap, lives forever) to `fl_alloc` + `fl_free` — trims per-query bump pressure on long-running ops.
- **Wins**: `sit log` on a 100-commit walk **−17%** (33.67 → 27.84 ms min). `sit fsck` should match or exceed (same pattern, more iterations).
- **Honestly unchanged**: `sit status`, `sit clone`, `sit add`, `sit commit`, `sit fetch` — their bottlenecks (sigil throughput, per-object zlib_decompress, file_write_all) are downstream of the patra open/close cost the cache fixed. Other queued perf items target those: see v0.6.5+ below.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.4.md`](../benchmarks/2026-04-25-v0.6.4.md).

### v0.6.3 — LOW-severity batch + audit closeout

- **S-28** confirmed already addressed: cyrius stdlib's `exec_vec` passes an empty envp, which is more aggressive than the audit's "minimal envp" prescription. No sit-side change; documented in CHANGELOG + state.md so future readers don't re-investigate.
- **S-31** — added `strnlen(s, max)` to `src/util.cyr`. Swapped `parse_index`'s `strlen(patra_result_get_str(…))` to `strnlen(…, 256)` (patra's `COL_STR_SZ` width). Defense-in-depth — patra's writer still memsets every STR slot to zero, so `strlen` would terminate inside the slot today, but the bound makes the safety property explicit at the read site instead of implicit at the write site.
- **S-32** — Cyrius string-literal lifetime invariant documented in [`docs/architecture/004-cyrius-string-literal-lifetime.md`](../architecture/004-cyrius-string-literal-lifetime.md). The audit's alternative (switch tree.cyr's mode literals to integer codes with a format table) was rejected: trades a free invariant for runtime indirection on the hottest tree-build path.
- **Audit closeout**: 2026-04-24 P(-1) audit fully resolved at every severity (CRITICAL / HIGH / MEDIUM / LOW). Only **S-24** is deferred — it folds into the v0.6.x patra-handle-caching refactor's `read_object` rewrite (avoids touching the same function twice in two consecutive releases).

### v0.6.2 — Security hygiene (MEDIUM batch)

- **S-16** through **S-27** from the 2026-04-24 P(-1) audit landed. Highlights: `alloc_or_die` helper + 52-site swap (S-17); materialize / merge / commit / clone now fail loudly on FS-mutation errors instead of silently producing partial state (S-16, S-27); `cmd_clone` requires `--force-absolute` for absolute targets (S-23); author-line + sitsig parsers hardened against integer overflow + partial hex decode (S-18, S-19, S-20); index-migrate caps per-line path length at 4096 (S-22); latent `ensure_dirs_for` mkdir("") removed (S-25). Full list in [CHANGELOG § 0.6.2](../../CHANGELOG.md#062--2026-04-25). Audit findings stamped RESOLVED in [`docs/audit/2026-04-24-audit.md`](../audit/2026-04-24-audit.md).
- **S-24 deferred to v0.6.x.** The audit's `read_object` single-exit refactor + SQL-string `fl_alloc` swap is entangled with the planned patra-handle-caching refactor (which adds `read_object_with_db(db, hex, out)` and threads the cached handle through every caller). Doing both in v0.6.2 would mean rewriting `read_object` twice in two consecutive releases.
- All P(-1) CRITICAL/HIGH/MEDIUM findings closed except the deferred S-24.
- Behavioral change: `sit clone <url> <abs-path>` requires `--force-absolute`. CI smoke + `scripts/benchmark.sh` + `docs/guides/getting-started.md` updated. Migration note in CHANGELOG.

### v0.6.1 — S-33 dep-bump release

- **S-33** — `sit status` SIGSEGV on a 100-commit / 100-file repo: **resolved** by upstream dep bumps. Triage in [`issues/archived/2026-04-24-cyrius-stdlib-alloc-grow-undersize.md`](issues/archived/2026-04-24-cyrius-stdlib-alloc-grow-undersize.md) and [`issues/archived/2026-04-24-read-object-unreadable-at-scale.md`](issues/archived/2026-04-24-read-object-unreadable-at-scale.md). Two stacked upstream bugs: cyrius stdlib `alloc` grow-by-1MB undersize (caused the SIGSEGV via the 16 MiB retry alloc) + sankoch `zlib_compress` / `zlib_decompress` asymmetry (caused the retry path to fire in the first place; lost ~20% of objects on the fixture).
- **Pin moves**: cyrius `5.6.25` → `5.6.35` (alloc grow fix landed upstream in 5.6.34), sankoch `2.0.1` → `2.0.3` (zlib symmetry restored). No sit source changes.
- `scripts/benchmark.sh` — `bench_status` + `bench_clone` rows re-enabled, producing real numbers (`status-100files` 7.08 ms ≈ 1.8× git; `clone-100commits` 245 ms ≈ 16× git, dominated by per-call patra open per P-01).
- New `docs/development/issues/` directory for upstream-bug writeups (see README). Lifecycle: file → triage → fix lands → archive with `— RESOLVED`. Two RESOLVED entries on day-one.

### v0.6.0 — security hardening

- **P(-1) audit fixes**: validators for ref names (git `check-ref-format` grammar), tree entry names, hash prefixes, config values, remote URLs. Symlink guards on all local-clone paths (CVE-2023-22490 class). Decompression multipliers tightened 256× → 16×. Output escape filter on attacker-controlled identity bytes. Full change list in [CHANGELOG § 0.6.0](../../CHANGELOG.md#060--2026-04-24). Underlying audit at [`docs/audit/2026-04-24-audit.md`](../audit/2026-04-24-audit.md).
- **New module**: `src/validate.cyr` — pure validators, one source of truth.
- **ADRs 0003, 0004, 0005** — no upward repo discovery, SHA-256 only, local-clone threat model.
- **Tests**: 101 assertions across 13 test groups (31 → 101).

### v0.5.1 — file-split refactor

- `src/main.cyr` shrank from 5096 → 112 lines (purely `print_usage` + `main()` + dispatch + trailer).
- 11 topical modules under `src/`: `util`, `config`, `object_db`, `index`, `refs`, `tree`, `diff`, `commit`, `merge`, `sign`, `wire`. Chained via `src/lib.cyr`.
- No function renames, no feature changes, no bug fixes beyond what the split surfaced. Mechanical relocation only.
- Follows the yukti / patra include-chain pattern; `cyrius.cyml [build].entry` stays on `src/main.cyr`, stdlib continues auto-including via `[deps].stdlib`.

### v0.5.0 — wire protocol (local-path transport)

- **Remotes**: `sit remote add|list|remove` — named remotes in `.sit/config` as `remote.<name>.url = <path>`. `file://` and bare absolute paths.
- **`sit fetch <remote> [<branch>]`** — BFS-walks reachability from the remote ref in the remote's `.sit/objects.patra`, copies missing objects as raw compressed bytes, writes `.sit/refs/remotes/<remote>/<branch>`.
- **`sit push <remote> [<ref>]`** — symmetric local → remote, fast-forward-only.
- **`sit pull <remote> [<branch>]`** — fetch + fast-forward merge; divergence bails out with a pointer at `sit merge`.
- **`sit clone <url> [<dir>]`** — mkdir + chdir + init + remote-add + fetch + materialize.
- **`sit merge -S`** — signed merge commits via the existing `build_merge_commit_signed`.
- **Nested refs** — `sit branch feature/foo`, `sit checkout -b feature/foo`, `sit tag rel/v1` all work; `ensure_parent_dirs` called from every ref writer.
- **Remote-tracking ref resolution** — `sit merge origin/main`, `sit show origin/main`, etc. work via `resolve_ref_name` consulting `.sit/refs/remotes/<path>`.

Command count: **24** (previous 19 + `remote`, `fetch`, `pull`, `push`, `clone`).

### v0.4.0 — first official release

The local VCS loop is complete end-to-end, with ed25519 signing and a local-path fetch/push protocol.

**Core object model**
- `sit init` creates a git-parity `.sit/{HEAD,objects.patra,refs/heads}` layout.
- Objects are SHA-256-hashed (sigil) and zlib-compressed (sankoch), framed `"<type> <len>\0<content>"` — byte-compatible with git's SHA-256 object format for identical content.
- Storage is patra-backed: `.sit/objects.patra` (`objects(hash STR, ty INT, content BYTES)`) + `.sit/index.patra` (`entries(path STR, hash_hex STR)`). Legacy plaintext/loose layouts auto-migrate on first access.
- Trees are recursive with `40000` dir + `100644` file modes, byte-matching git's SHA-256 tree format. `flatten_tree` / `read_head_tree_entries` give flat views for status/diff.

**Commands (19)**
- Write: `init`, `add [-f]`, `rm [--cached]`, `commit [-S] [-m]`, `reset [--hard]`, `merge [--abort]`, `branch [-d]`, `checkout [-b]`, `tag [-d]`, `config [--global|--list|--unset]`, `key generate|show`, `remote add|list|remove`, `fetch`, `push`.
- Read: `log [--oneline] [-n] [<ref>]`, `status`, `diff [--staged|<commit>|<c1> <c2>]`, `show [--stat] [<hash>]`, `cat-file`, `owl-file`, `fsck`, `verify-commit`.

**Signed commits (sigil/ed25519, no GPG)**
- `sit key generate` → `~/.sit/signing_key` (32B seed hex, 0600) + `signing_key.pub`.
- `sit commit -S` injects `sitsig <sig-hex> <pub-hex>\n` between `committer` and the message separator. Signed payload is the body *without* the sitsig line (self-consistent like git's `gpgsig`).
- `sit show` / `sit log` auto-decorate with `Signature: good|BAD (key <hex12>)` via a shared `print_commit_header`.

**Merge**
- Fast-forward when possible; otherwise 3-way with line-level diff3. Non-overlapping hunks auto-merge; overlapping edits fall back to conflict markers + `.sit/MERGE_HEAD`. Follow-on `sit commit` emits a 2-parent commit. `sit merge --abort` cancels.

**Wire protocol (local paths only)**
- `sit remote add <name> <url>` writes to `.sit/config`; `file://` and bare paths are the only transports in this cut.
- `sit fetch` walks remote refs, diffs against local object set, copies missing objects naively (no pack bundles).
- `sit push` is the reverse direction; fast-forward only. Non-ff push rejected.
- HTTP / SSH transports and pack bundles are explicit v0.5.x work.

**Config + identity**
- `sit config [--global] <key> [<value>]`, `--list`, `--unset`. Local `.sit/config`, global `~/.sitconfig`.
- Author chain: `SIT_AUTHOR_NAME` env → local config → global config → `"sit user"` fallback.

**Tests**: 31 assertions — sigil SHA-256 known-answers, git-SHA-256 blob framing, hex encode/decode, sankoch zlib roundtrip, patra COL_BYTES small + 16KB overflow, ed25519 sign/verify roundtrip with bit-flip negatives.

**Deps**: cyrius 5.6.25, sakshi 2.1.0, sankoch 2.0.1, sigil 2.9.1, patra 1.6.0. Git-tag pinned. No FFI, no C, no libgit2 — see [ADR 0001](../adr/0001-no-ffi-first-party-only.md).

## Backlog

### v0.6.x perf items — closed (reference only)

Patra-handle caching shipped in v0.6.4. Remaining items targeted the bottlenecks v0.6.4 didn't move: clone, status, diff. **All sit-side items shipped or explicitly deferred by v0.6.12** — the arc closed there. The waiting-on-deps subsection below is left as reference for how the cumulative scoreboard accumulated; the only forward-looking entry is `P-11` (sit add index upsert without full rewrite, gated on a patra `or_ignore` flag for `patra_insert_row`).

**Waiting on dep updates** (filed on each dep's roadmap 2026-04-25; sit gets bigger wins once these land but is not blocked from shipping the items below):

- [`patra` roadmap](../../../patra/docs/development/roadmap.md):
  - ~~Sized string getter `patra_result_get_str_len`~~ — **shipped as patra 1.6.1, consumed by sit v0.6.10** (S-31 closed).
  - ~~WAL group commit / batched fsync~~ — **shipped as patra 1.8.x; sit investigated and did NOT consume** in v0.6.10 (durability regression with no perf gain on sit's bench shape; reasoning at `get_object_db` / `get_index_db` call sites). Revisit when sit grows explicit `patra_flush()` at command exit.
  - ~~`INSERT OR IGNORE`~~ — **shipped as patra 1.7.0 (SQL-level only); sit can't consume yet** because sit's BYTES-column inserts go through `patra_insert_row` (programmatic API), not SQL strings. Re-file: ask patra to grow an `or_ignore` flag on `patra_insert_row` so sit can drop the inner `db_object_has` in `db_object_insert_raw`. Effort on patra side: small (the SQL-level path already does the dedup probe).
- [`sigil` roadmap](../../../sigil/docs/development/roadmap.md):
  - ~~SHA-256 hot-path throughput investigation~~ — **shipped as sigil 2.9.3, consumed by sit v0.6.12.** SHA-NI hardware path live on x86_64; SHA-256 throughput ~12 MB/s → ~400 MB/s on 64 KB inputs (32× factor). Drove `sit add -64KB -41%` and `sit add -1MB -48%`.
- [`sankoch` roadmap](../../../sankoch/docs/development/roadmap.md):
  - **Partial: sankoch 2.1.0 shipped** in v0.6.12 with DEFLATE micro-tuning down-payments (pre-reversed dynamic Huffman codes, others). Standard zlib path moves modestly (~5-7%) at small/medium sizes. Larger 2.x match-finder / ring-buffer / SIMD work queued for follow-up sankoch releases — the remaining `add-1MB` budget is ~140ms `zlib_compress(1MB)`, which is exactly what those bigger items target.

When any of those ship, sit can drop the corresponding workaround / get a measurable improvement on the matching workload without further sit-side code changes. Watch their CHANGELOGs.

**Sit-side items (no dep dependency, ship-ready):**

- ~~**P-03** `copy_objects`~~ — **shipped in v0.6.5** (see Released above). Partial: the transaction wrap + outer has-check drop landed; the batched `WHERE hash IN (...)` pre-filter is deferred (would need 60-hash chunking per patra's 128-token / 4096-byte SQL parser limits). When patra grows `INSERT OR IGNORE` / `UPSERT`, the inner has-check goes away too.
- ~~**P-06** + **P-15**~~ — **shipped in v0.6.9** (see Released above). Decompression sizing tightened (4× initial, retry only on `-ERR_BUFFER_TOO_SMALL`); LCS DP table moved to `fl_alloc`/`fl_free` (mmap-backed, freed after computation).
- ~~**P-04** `walk_reachable_from_commit`~~ — **shipped in v0.6.7** (see Released above). Cached compressed bytes during the walk, shared with `copy_objects`. Final clone ratio 11.08x git (from 16.13x at v0.6.4 entry).
- ~~**P-10 + P-18**~~ — **shipped in v0.6.6** (see Released above). Hashmap-backed `tree_find` + `three_way_path_set`. No 100-file bench movement; substantial at scale (1000-file `cmd_status` ~5ms → ~0.3ms on the tree_find piece).
- **P-11** `sit add` index upsert without full rewrite (needs patra UPSERT; if patra doesn't have it, push on their roadmap).
- ~~**P-17** Buffered stdout~~ — **shipped in v0.6.8** (see Released above). 64KB heap buffer in `src/util.cyr`; 206 direct stdout writes routed through it. No 100-file bench movement (fixture too small); structural improvement + win at scale.
- Re-bench after each change; gate on no regression vs. the v0.6.4 snapshot.

### ADRs to write (concurrent with v0.5.2)

- **ADR 0003** — sit does not search upward for `.sit/` (CVE-2022-24765-shape; locks in correct behavior).
- **ADR 0004** — sit is SHA-256 only; no SHA-1 interop ever.
- **ADR 0005** — Local-clone threat model (symlink handling, allowed URL schemes, future HTTP notes).

### Cross-project backlog (from audit § Downstream)

- **patra** — `INSERT OR IGNORE` / `UPSERT` (unblocks P-11 / P-24), bound parameters for STR columns (unblocks the right fix for S-01), sized `patra_result_get_str_len` (S-31). Draft entries on patra's roadmap.
- **sigil** — `hex_decode` that strictly fails on invalid chars rather than partial decode (S-20). Flag SHA-256 software throughput; software vs hardware story.
- **sankoch** — `zlib_decompress_with_ratio_cap` primitive to give every consumer a one-call decompression bomb defense (S-08 root-cause fix).

### Cross-project asks pointing back at sit (downstream-driven)

- **owl** — wants sit consumable as a Cyrius dep. owl's roadmap describes the SIT VCS swap in `src/vcs.cyr` as a "single-file rewrite" that replaces the `execve("git", "diff", …)` shell-out with a sit library call. As of sit 0.7.6 sit is binary-only — no `[lib]` clause in `cyrius.cyml`, no `dist/sit.cyr`, no namespaced public API. owl can't `[deps.sit] modules = ["dist/sit.cyr"]` the way it consumes vyakarana. **Tracked as v0.7.7 below** — slotted ahead of SSH per the explicit "before SSH" downstream ask. owl's request also surfaced two diff-primitive correctness gaps that the same release should fix: (a) `cmd_diff` ignores `-U<N>` (context width hardcoded to 3 in `group_hunks`); (b) `print_file_diff` and `lcs_diff` are tightly bound to stdout-print + working-directory state, not reusable as a "give me ops for path P at HEAD vs working tree" primitive a library consumer can call.

### v0.7.x — Network transport release sequence

Per the v0.7.x plan settled 2026-04-25. Each release is a small bite (CLAUDE.md "Large effort: small bites only"); each ships independently with a test gate.

**Architectural settles** (already locked):

- **Wire protocol**: sit-native JSON/REST under `/sit/v1/...`. Git-smart-HTTP rejected (wrong hash family — sit is SHA-256 only per ADR 0004; can't carry raw compressed `objects.patra` bytes through pack rewriting; sit owns both ends so compatibility is no leverage).
- **Routes**: `GET /capabilities`, `GET /refs[/<name>]`, `GET /objects/<hash>` (raw compressed bytes, `X-Sit-Type` header carries patra `ty`), `POST /want` (batched length-prefixed object stream), `POST /objects/<hash>` (server rehashes — only place sit rehashes; trust boundary), `POST /refs/<name>` (fast-forward enforced).
- **Server**: `sit serve <path> [--listen 127.0.0.1:8484] [--require-auth] [--token <path>]`. One repo per process. Reuses v0.6.4 patra-handle cache.
- **Auth**: bearer token via `~/.sit/serve.token` (0600). Anonymous read in both modes; `--require-auth` flag gates writes only. Per [ADR 0007](../adr/0007-network-transport-security.md): bearer auth is local-process-snoop defence on loopback, not a TLS substitute. Non-loopback exposure of HTTP is structurally unsafe and never lands without first-party Cyrius TLS.
- **Transport-layer security**: per [ADR 0007](../adr/0007-network-transport-security.md), HTTPS via libssl is not on the v0.7.x roadmap and won't ship until first-party Cyrius TLS exists. SSH (v0.7.8 — bumped from v0.7.7 when the library-export slot landed in front of it; see release table below) is the canonical encrypted-over-internet transport (process boundary, not FFI). HTTP is loopback / private-network / behind-tunnel.

**Releases:**

| ver | scope | new modules | success gate |
|---|---|---|---|
| ~~0.7.0~~ | ✅ shipped — sandhi-fold toolchain unlock; orphan delete | — | (see Released) |
| ~~0.7.1~~ | ✅ shipped — URL scheme detection + dispatch stubs | — | (see Released) |
| ~~0.7.2~~ | ✅ shipped — `cmd_serve` + `GET /capabilities` + `GET /refs` (read-only); sandhi opt-in; cyrius 5.8.51 toolchain refresh | `src/serve.cyr` | (see Released — 4-ref smoke fixture verified) |
| ~~0.7.3~~ | ✅ shipped — `GET /objects/<hash>` (server) + `wire_http.cyr` end-to-end fetch/clone (client) + `obj_src` abstraction; cyrius 5.8.51 → 5.9.37 toolchain refresh | `src/wire_http.cyr` | (see Released — 100-commit smoke fixture verified at 1.26×) |
| ~~0.7.4~~ | ✅ shipped (scaffold) — `POST /want` server endpoint + ADR 0006 frame format + DCE-stripped client primitives. Per-object GET still the active client path; batching held for v0.7.5+ (gate not met on loopback) | ADR 0006 | (see Released — wire validated; perf gate explicitly deferred) |
| ~~0.7.5~~ | ✅ shipped — walk-side phasing (commit chain → tree-batch → blob-batch) + cache-aware tree walk + frame-decoder fuzz (10M iters clean). Push deferred to v0.7.6+. | — | (see Released — 13% loopback / 42% at 1 ms RTT projected; ≥30%-at-realistic-RTT gate met) |
| ~~0.7.6~~ | ✅ shipped — `POST /objects/<hex>` (server rehashes — trust boundary) + `POST /refs/<refname>` (FF gate) + bearer auth via `~/.sit/serve.token` (0600) + ADR 0007 (no libssl, ever). Client `cmd_push` lights up over `http://`. | ADR 0007 | (see Released — full push roundtrip CI smoke; 401 cases verified; anonymous read against auth-required server works) |
| **0.7.7** | **`dist/sit.cyr` library export + diff primitive cleanup.** Two bound concerns for one release. (1) Land `[lib]` in `cyrius.cyml` and a `dist/sit.cyr` bundle so downstream Cyrius projects (owl first; future agnoshi / cyrius-doom integrations second) can consume sit as a dep. Public API surface decision: namespace under `sit_*` (matches existing `cmd_*` convention but caller-facing) — at minimum `sit_repo_open(cwd)` (returns repo handle or 0; replaces `file_exists(".sit/HEAD")` probe), `sit_repo_close(repo)`, `sit_diff_path(repo, path) → ops_vec` (HEAD-blob vs working-tree, returns the same annotated-ops shape `annotate_ops` already produces), and the existing `ann_kind`/`ann_line`/`ann_old`/`ann_new` accessors as part of the stable surface. Internal-only functions stay `_`-prefixed; `[lib].modules = ["dist/sit.cyr"]` enumerates the export set. ADR slot pending — likely **ADR 0009** to lock the public-API contract (what's stable, what's not, semver discipline going forward). (2) Fix the two diff-primitive correctness gaps owl surfaced while assessing readiness: `cmd_diff` should accept `-U<N>` and thread it through `group_hunks(annotated, ctx)` (today the second arg is hardcoded to 3 at the call site in `print_file_diff`); `print_file_diff` should split into a pure compute layer (`sit_diff_path(repo, path)` returning ops, no I/O) and a thin print layer (existing stdout writes), so library consumers can ask for ops without paying for stringification. Both fixes are mechanical given the existing primitives — `lcs_diff`, `annotate_ops`, `read_blob_content`, `read_head_tree_entries`, `tree_find` already do the load-bearing work. | `dist/sit.cyr` (generated bundle), `[lib]` block in `cyrius.cyml`, ADR 0009 (public-API contract) | downstream consumer (owl) builds against `[deps.sit]` clean and can call `sit_diff_path` to populate its VCS marker gutter without `execve`; existing `cmd_diff` smoke unchanged; `cmd_diff -U0` produces zero-context output matching `git diff -U0` byte-shape; new `tests/sit.tcyr` probes assert `sit_diff_path` returns the expected op count for a synthetic 3-add / 2-mod / 1-del fixture |
| **0.7.8** | SSH — `ssh user@host -- sit serve --stdio`; length-prefixed framing on stdin/stdout. SSH process owns the encryption + auth; sit's wire travels over its stdin/stdout — no crypto in sit's address space, no library link (process boundary, not FFI). Heavy fuzz on URL parser (CVE-2017-1000117 host-component injection). | `src/wire_ssh.cyr` (ADR 0008) | CI sshd loopback clone; `ssh://-oProxyCommand=...` rejected pre-`exec_vec`; round trip works against an OpenSSH server |

**Blocked on first-party Cyrius TLS existing** (not numbered slots; per ADR 0007):

- **HTTPS** — `https://` URL scheme support. The `URL_SCHEME_HTTPS` constant + `https://` validator already exist in `validate.cyr`; `wire_transport_check_*` rejects with `"https transport requires first-party Cyrius TLS (see ADR 0007)"`. Implementation lands when there's a Cyrius TLS stack to drive — not a v0.7.x release.
- **mTLS** — depends on TLS, depends on first-party Cyrius TLS.
- **Bearer auth over the open internet** — depends on TLS for the same reason. v0.7.6's bearer auth is loopback / private-network / behind-tunnel only by design.

**Out of scope for v0.7.x** (deferred to v0.8.x or later):

- **Pack bundles** — batch object transfer with sankoch delta primitives. Ties to sankoch + patra storage shape work that isn't ready.
- **Push to checked-out branch defense** — known footgun (see "Longer horizon" below); a v0.7.x patch may file the check, but it's not gating the release line.
- **HTTP/2** — sandhi has it (`sandhi_h2_*`); whether sit's wire benefits from H/2 streaming over the v0.7.4 batched-stream endpoint is a v0.7.4-time decision.

**Benchmarks** — three bench targets were scoped but deferred from v0.6.0 because they need larger fixtures or a companion algorithm change:

- **LCS diff** at 100×100 / 1000×1000 / 4000×4000 line counts. Shows the cost curve and the 16M-cell cliff; motivates the Myers O((N+M)D) fallback (P-14).
- **`glob_match`** against 10 / 50 / 200-pattern `.sitignore` files. Baseline for the P-13 pattern pre-classification refactor.
- **`hash_file_as_blob` end-to-end** on 1 KB / 64 KB / 1 MB inputs. Measures the true `sit add` floor and maps sigil's software-SHA-256 bottleneck.

Add these alongside the algorithm / transport work that justifies them. v0.7.x bench fixtures will likely include a 100-object HTTP fetch round trip for the wire-protocol releases.

### Longer horizon

- **Reject push to checked-out branch** — git's `receive.denyCurrentBranch = refuse` default. Today `sit push` silently advances the remote's ref while leaving its working tree stale; surprising when the remote is someone's active repo. Check whether the remote's HEAD resolves to the branch being pushed and refuse by default; opt-in escape via a config knob later.
- **`sit fsck` reachability** — walk commit chain and flag dangling objects (current implementation checks integrity but not reachability).
- **Full `.sitignore` semantics** — negation (`!pattern`), double-star (`**`), character classes (`[abc]`), anchored patterns (`/foo`), path patterns (`foo/bar`).
- **`sit log --graph`** — ASCII DAG for merge history.
- **Shallow clone** — `--depth N` limits to N commits back from HEAD.
- **Integration tests in-tree** — promote the shell-level scenarios from `docs/guides/getting-started.md` into `tests/` with fixtures. Current `tests/sit.tcyr` is primitive-assert smoke only.
- **Sandhi co-adds in [deps].stdlib** — when v0.7.2 lands `sit serve`, the inline `[deps].stdlib` list grows by `net`/`tls`/`ws`/`http`/`json`/`sandhi` (sandhi's transitive needs since cyrius still has no transitive stdlib resolution). Watch whether a future cyrius release introduces transitive resolution; if so, sit can drop the explicit transitive entries (`thread`/`freelist`/`bigint`/`ct`/`keccak` + the v0.7.2 network adds) without losing reachability.
