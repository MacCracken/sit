# sit Development Roadmap

**Forward-looking only.** Shipped history lives in [`CHANGELOG.md`](../../CHANGELOG.md) (the tagged-release source of truth); the live snapshot — current version, dependency versions, source layout, command inventory, recent releases — lives in [`state.md`](state.md). This file is only what is *next*.

> **How this file is organized.** Backlog items are grouped by **what kind of work they are**, not by a version number, because version-keyed headings go stale the moment a release ships. Only the *themed minor line* carries version numbers, because those are deliberate scope commitments. When an item ships, **delete it** — the CHANGELOG is the record. Do not leave struck-through entries behind.

**Where we are**: `1.4.5`. The `1.3.x` line went almost entirely to audit work (two security audits, see [`../audit/`](../audit/)); `1.4.0` closed the last two integrity gaps; `1.4.1` found `objects.hash` had no index at all; `1.4.2` profiled the residual curve to patra's result-buffer sizing; `1.4.3` picked up the upstream fix (patra 1.13.8 via cyrius 6.5.28) and **the object-lookup curve is now flat**; `1.4.4` made the benchmark fixture a knob and it immediately exposed **two more superlinear paths** the 100-commit default rated as benign; `1.4.5` fixed one cause (`index_find`'s linear scan) but `status` is still superlinear from something else. Audit backlogs are empty. The themed minor line shifted **+1** when `1.4.0` went to integrity rather than tags.

---

## SemVer tiers (post-1.0)

- **Patch (`1.x.y`)** — no new *observable* surface: bug fixes, perf, internal refactors, toolchain/dep bumps, consuming upstream fixes. Safe to take blindly.
- **Minor (`1.x.0`)** — new *backward-compatible* surface: a command, flag, config key, public-API symbol, or wire capability.
- **Major (`2.0.0`)** — reserved for a breaking change to the CLI, `.sit/` layout, wire protocol, or public API. None planned.

Nothing below blocks anything else; ordering within a section is a recommendation, not a contract. Each ships under the usual test / fuzz / bench gates.

---

## Patch line — correctness & hardening (no new surface)

### `1.4.x` — mapped patch line

Ordered. Nothing here adds observable surface, so each can ship as it lands.

- **`1.4.6` — profile what is still superlinear in `status`.** 1.4.5 gave
  `index_find` the hashmap `tree_find` got in v0.6.6, which removed a genuine
  O(N²) — but only bought **20%** at N=1000 (`status-1000files` 26.64× → 21.35×
  git), so it was not the dominant term at that size. **10× the files still costs
  ~19× the time.** Cause unidentified. Do it the way 1.4.2 did the lookup curve:
  instrument `cmd_status`'s phases (`read_head_tree_entries`, `parse_index`,
  `list_working_files`, the per-entry `hash_file_as_blob`, the three loops) and
  measure at two sizes — **do not guess**. Two guesses were wrong in the 1.4.2
  investigation before profiling settled it in one run.
- **`1.4.7` — fuzz targets for the remaining unfuzzed parsers.** *(From the
  2026-08-17 audit, whose central lesson was that the one module with no fuzz
  target held every serious finding.)* `parse_tree`, `parse_commit_body`,
  `_git_packed_ref_lookup` and `_wildmatch` all parse untrusted bytes and have
  unit tests but no harness. Test-only, so a patch — not a minor.
- **Diagnose `clone`'s superlinear growth.** The 1.4.4 large tier put it at
  **5.17× git at 100 commits and 60.80× at 1000** — 34× growth for 10× the work.
  Plausibly the same `index_find` scan via materialize plus per-object round
  trips, but **unmeasured**; profile before assuming, the way 1.4.2 did.
- **Nested `.gitignore` / `info/exclude`** for `.git/` read-mode. Only the
  top-level `.gitignore` is honoured today (`_ignore_filename`, `git_read.cyr`).
- **Reflog `expire` / `delete` + `@{<date>}` selector** *(carried from 1.1.0)*.
  Entries are unbounded, so `fsck --prune` reclaims reflog-protected objects only
  via `--prune-now`; expiry closes that.

### Test & tooling debt

- **Memoize `_wildmatch`.** 1.3.8 bounded the catastrophic backtracking with a per-match step budget. That fixes the DoS but leaves the matcher worst-case exponential — it simply cannot spend more than the budget proving it. The real fix is memoization over (pattern offset, string offset). The obstacle is cost: the memo table would be allocated and zeroed per (pattern, path) pair on `is_ignored`, which is a measured benchmark (`is_ignored-200pat`). Likely shape — memoize only when the pattern carries ≥3 star groups, so the common 0–2 star patterns keep today's allocation-free fast path.

---

## Structural — object storage size

Promoted out of "heavier / unscheduled" by the 1.4.2 profiling, and still the top
structural item — but for a **narrower reason than first written**.

> ⚠ **Correction.** The original entry argued store size mattered because it
> overshot "patra's ~4 MB page cache". That reasoning was wrong — the page cache
> is opt-in and was never enabled; the real cost was patra sizing a result buffer
> by the whole table, fixed upstream and folded in 1.4.3. **The read-performance
> argument for packing is therefore gone: lookups are now flat regardless of store
> size.** What remains is the plain disk-and-transfer case, which is still strong.

- **Pack bundles + `gc` / repack.** For an identical 1,600-commit history sit's
  store is **62.8 MB** where git packs to **1.1 MB** (git loose, unpacked: 6.4 MB)
  — sit has no delta compression or packing, and every object occupies at least
  one patra page. That is a ~57× disk penalty and it rides on every clone/fetch as
  bytes on the wire.

  The git-delta *read* interpreter already exists (1.2.0, `src/git_pack.cyr`);
  what remains is delta *generation*, on-disk repack, and the negotiated wire
  capability (which makes it a minor, not a patch).

---

## Minor line — themed `1.x.0`

Each is a self-contained minor; the heavier ones earn their own slot. **Next: `1.5.0`** — and it is the first *feature* work since 1.3.0, after five consecutive hardening releases.

- **`1.5.0` — Annotated & signed tags + ref ergonomics** *(light; high git-parity value).* Annotated tags (a real tag object with tagger + message, not just a lightweight ref); **ed25519-signed tags** (reuse the sitsig machinery from signed commits); `sit mv` (rename in working tree + index); `sit describe` (nearest tag + offset). Completes the tag + signing story; low risk — a good cadence-setter after five consecutive hardening releases.
- **`1.6.0` — History tools** *(medium; reflog-backed).* `sit revert` (inverse commit); `sit cherry-pick` (apply a commit onto HEAD via the existing 3-way merge + `merge-base`); `sit stash` (save / restore the working tree). Safe now that the reflog (1.1.0) makes them recoverable.

  ⚠ All three route through `three_way_line_merge`, which 1.3.8 found could not terminate on an insert-only hunk. That is fixed, but this minor is the one that will exercise the merge core hardest — budget for merge-correctness testing, not just command plumbing.
- **`1.7.0` — TLS trust hardening** *(medium).* HTTPS **CA-chain + hostname verification** (opt-in: `http.sslVerify` / `http.caBundle`, system store via `tls_native_set_ca_system`; TOFU stays the default); **mTLS** (client certs — the `tls_native` verify primitives already exist); **non-loopback `sit serve`** (lift the `127.0.0.1` lock, gated on `--tls`, refuse non-loopback plain HTTP); **bearer auth over SSH** (`_ssh_handle_auth_token` stub → real). A cohesive transport-trust minor.
- **`1.8.0` — Wider merge + inspection.** **Octopus / N-way merge** (`cmd_merge` → N branches; `find_merge_base` already walks N parents correctly); **`sit blame`** (per-line last-touch — also a natural `dist/sit.cyr` library export for owl, alongside `sit_diff_path`); **`.sitignore` directory-only (`build/`) enforcement** (closes the last documented git-parity gap).
- **`.git/` CLI parity** *(unscheduled).* `sit status` / `log` / `diff` and `@{N}` on git repos — the 1.2.0 *library* API already works on git; the CLI commands stay `.sit`-gated. Needs a shared `_compute_status_records()` in `diff.cyr` so it doesn't back-reference `api.cyr` in single-pass dist order. A `1.x.0` when a consumer wants CLI parity.

---

## Heavier / unscheduled

Each earns its own minor when its time comes.

- **`sit rebase`** — the heaviest rewrite tool; depends on the reflog (1.1.0) for safety and shares cherry-pick's apply machinery (1.6.0).
- **Hooks** (`pre-commit`, `pre-push`, …) — if a consumer asks.

---

## Upstream asks (not sit work)

These are blocked on another repo. Per [CLAUDE.md](../../CLAUDE.md), cross-project requests go on the **target repo's** roadmap, not an issue tracker — so each needs drafting there.

- **cyrius — ASAN / poisoned-allocator mode for `cyrius fuzz`.** The 127-byte heap overread in `_git_apply_delta` (2026-08-17 audit) was invisible to fuzzing because the read landed in mapped memory: it was found by reading and is pinned only by a deterministic corpus that asserts on the leak. **Every OOB *read* in the tree has that blind spot.** Wanted: redzone poisoning so `cyrius fuzz` fails on overreads, not only on faults.
- **cyrius — per-profile `distlib` dep sidecars.** `cyrius distlib read` writes its sidecar to `dist/sit.deps`, the same path the full profile uses, and emits the whole `[deps].stdlib` list rather than the leaves the `read` profile needs. Both profiles therefore emit a byte-identical sidecar, so a `dist/sit-read.cyr` consumer following it pulls in the network stdlib (`net` / `tls` / `tls_native` / `ws` / `http` / `sandhi`) the lean bundle exists to drop. Harmless today (a superset resolves, and last-writer-wins with identical bytes) — a packaging nit, not a bug. Wanted: `dist/<name>-<profile>.deps` scoped to the profile's own module set.

  ⚠ **Re-verified on cyrius 6.5.28 (2026-08-18): still reproduces** via all three
  paths — `distlib read` alone, `distlib` then `distlib read`, and `distlib --all`
  each leave only `dist/sit.deps` with all 38 leaves. **But one run did emit a
  correctly profile-scoped `dist/sit-read.deps`** (231 bytes, a strictly smaller
  leaf set) and it has not been reproducible since — so the capability may already
  be partly implemented behind some condition, rather than absent. Worth checking
  that path before writing it from scratch.
- **sankoch — match-finder / SIMD.** Targets the `add-1MB` `zlib_compress` floor (~140 ms, the largest single cost in `sit add`). Already on sankoch's roadmap, gated on a wire-identical speedup.

---

## On hold — keep sandhi

Dropping sandhi for a hand-rolled `net`-direct loopback HTTP/1.0 server (surface minimization) is deliberately *not* scheduled: a future cyrius change is expected to make `stdlib` / `lib` consumption easier, which changes both the trade-off and the likely implementation. Until that lands, sit keeps consuming sandhi's `sandhi_server_*` surface.

---

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). Per-release benchmark snapshots are in [`../benchmarks/`](../benchmarks/) — latest [`2026-08-18-v1.4.3.md`](../benchmarks/2026-08-18-v1.4.3.md). Security audit reports are in [`../audit/`](../audit/).*
