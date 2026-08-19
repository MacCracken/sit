# sit Development Roadmap

**Forward-looking only.** Shipped history lives in [`CHANGELOG.md`](../../CHANGELOG.md) (the tagged-release source of truth); the live snapshot — current version, dependency versions, source layout, command inventory, recent releases — lives in [`state.md`](state.md). This file is only what is *next*.

> **How this file is organized.** Backlog items are grouped by **what kind of work they are**, not by a version number, because version-keyed headings go stale the moment a release ships. Only the *themed minor line* carries version numbers, because those are deliberate scope commitments. When an item ships, **delete it** — the CHANGELOG is the record. Do not leave struck-through entries behind.

**Where we are**: `1.4.7`. The `1.3.x` line went almost entirely to audit work
(two security audits, see [`../audit/`](../audit/)); `1.4.0` closed the last two
integrity gaps; `1.4.1`–`1.4.3` flattened the object-lookup curve; `1.4.4` made
the benchmark fixture a knob and exposed two superlinear paths; `1.4.5`–`1.4.6`
fixed all three causes and **`status` is no longer superlinear** (4.98× git at
1,000 files, was 26.64× at 1.4.4). `1.4.7` closed the last four unfuzzed parsers
and swept every deferral comment in `src/` for staleness. Audit backlogs are
empty. The themed minor line shifted **+1** when `1.4.0` went to integrity
rather than tags.

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

- **Diagnose `clone`'s superlinear growth.** The 1.4.4 large tier put it at
  **5.17× git at 100 commits and 60.80× at 1000** — 34× growth for 10× the work.
  Still **unmeasured**; profile before assuming, the way 1.4.2 and 1.4.6 did.
  ⚠ Note 1.4.6 removed the index write amplification and the `ORDER BY`, so
  `clone` may have moved on its own — **re-measure before profiling**, and do not
  assume the remaining growth has the same cause `status` did. `clone`'s
  materialize step writes the index through `rewrite_index`, which is still a
  whole-table DELETE + re-insert (correct there: it runs once per operation, not
  once per file) — that is the first thing to check.
- **Nested `.gitignore` / `info/exclude`** for `.git/` read-mode. Only the
  top-level `.gitignore` is honoured today (`_ignore_filename`, `git_read.cyr`).
- **Tree-name validation: HFS-ignorable Unicode codepoints.** `validate.cyr`'s
  `tree_flat_path_valid` rejects `.sit` / `.git` / `.ssh` case-folded, NTFS
  reserved names, and over-long names — but HFS-ignorable codepoints need a
  check over *decoded* Unicode, not bytes, so they are unhandled. Carried in the
  source as a "v0.7 follow-up" from v0.7 to v1.4.6 without moving; re-filed here
  in the 1.4.7 deferral sweep so it has a real home instead of a dead version tag.
- **Batched `WHERE hash IN (...)` pre-filter in `copy_objects`** (`wire.cyr`).
  v0.6.5 P-03 already collapses the insert loop into one patra transaction; the
  remaining win is replacing per-object existence SELECTs with chunked batch
  probes. Needs 60-hash chunking to stay inside patra's SQL parser limits.
- **Generate the `/sit/v1/capabilities` version banner from `VERSION`.**
  `serve_build_capabilities()` (`serve.cyr`) hardcodes the version string, so it
  is bumped by hand at every tag. It silently drifted to `0.8.10` from v0.8.x
  through v1.0.3, and was **missed again at 1.4.6** — caught only by the CI
  version-consistency gate that exists solely to catch it.

  ⚠ Already recorded as a known footgun in the **v0.8.2 CHANGELOG** (2026-05-13,
  "a future cleanup release … wires this to the version constant") and never
  carried onto this file, so it sat for three months somewhere that does not
  drive work. That is the argument for it living here: CHANGELOG is the shipped
  record, this file is the backlog.

  **Not blocked on cyrius.** `cyrius build` has no value-injection flag
  (`--features` is conditional compilation, not a define) and the manifest's
  `${file:VERSION}` is build metadata that does not reach source — but sit does
  not need either. Generate `src/version.cyr` from `VERSION` as a build step and
  gate it in CI the same way `dist/` sync is gated. The 1.4.7 sweep first filed
  this as a cyrius upstream ask, which was wrong: it would have parked a
  solvable sit task behind another repo.
- **HTTP base-path routing** (`wire_http.cyr`). Only `""` and `"/"` are accepted
  as the URL path today, so `http://host/repos/foo` is refused rather than
  silently mis-routed. Serving multiple repos behind one origin needs real
  server-side routing in `serve.cyr`.
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

  Two source sites defer to this entry (cross-referenced there since the 1.4.7 sweep): `resolve_ref_name` (`refs.cyr`) — `@{N}` reflog specs are `.sit`-only, because a git repo has no `.sit/logs/`; and `resolve_prefix` (`object_db.cyr`) — short-prefix disambiguation over a git store would have to walk the loose fanout plus every pack `.idx`, so a git object must be named by full oid or a ref.

---

## Heavier / unscheduled

Each earns its own minor when its time comes.

- **`sit rebase`** — the heaviest rewrite tool; depends on the reflog (1.1.0) for safety and shares cherry-pick's apply machinery (1.6.0).
- **Hooks** (`pre-commit`, `pre-push`, …) — if a consumer asks.

---

## Upstream asks (not sit work)

These are blocked on another repo. Per [CLAUDE.md](../../CLAUDE.md), cross-project requests go on the **target repo's** roadmap, not an issue tracker — so each needs drafting there.

- **cyrius — ASAN / poisoned-allocator mode for `cyrius fuzz`.** The 127-byte heap overread in `_git_apply_delta` (2026-08-17 audit) was invisible to fuzzing because the read landed in mapped memory: it was found by reading and is pinned only by a deterministic corpus that asserts on the leak. **Every OOB *read* in the tree has that blind spot.** Wanted: redzone poisoning so `cyrius fuzz` fails on overreads, not only on faults.

  ⚠ **1.4.7 demonstrated this concretely rather than arguing it.** With the four
  new parser targets in place, `parse_tree`'s `alloc_or_die(name_len + 1)` was
  changed to `alloc_or_die(8)` — a straight heap overflow on every entry whose
  name exceeds 8 bytes, hit ~200,000 times per run — and the fuzz suite **still
  reported `no crashes` and exited 0**. The allocator has enough slack that the
  overflow never leaves mapped memory. So the three buffer-parser targets pin
  *faults and hangs*, not memory errors, and no amount of additional rounds
  changes that. The `_wildmatch` target does have teeth by construction (see the
  A/B in the 1.4.7 CHANGELOG entry) because its failure mode is non-termination,
  which is observable without ASAN. **This is the single highest-leverage thing
  cyrius could give sit's test suite.**
- **patra — `ORDER BY` is an insertion sort; `DELETE` never reclaims pages.**
  Filed 2026-08-19 as
  [`2026-08-19-sit-order-by-insertion-sort.md`](https://github.com/MacCracken/patra/blob/main/docs/development/requests/2026-08-19-sit-order-by-insertion-sort.md).
  `ORDER BY` costs **3.9× per doubling** against the unordered scan's 1.96×
  (831 ms vs 7.4 ms at 2,000 rows) because `_sort_result_multi` shifts whole
  result rows; and a table's file grows with total rows ever inserted (~0.57 KB
  per insert, reclaiming nothing across three delete patterns). **sit is not
  blocked** — 1.4.6 sorts in-process and no longer churns the index — but sit
  would hand the sort back to patra once it is O(N log N), since patra can sort
  before materializing.
- **sankoch — match-finder / SIMD.** Targets the `add-1MB` `zlib_compress` floor (~140 ms, the largest single cost in `sit add`). Already on sankoch's roadmap, gated on a wire-identical speedup.

---

## On hold — keep sandhi

Dropping sandhi for a hand-rolled `net`-direct loopback HTTP/1.0 server (surface minimization) is deliberately *not* scheduled: a future cyrius change is expected to make `stdlib` / `lib` consumption easier, which changes both the trade-off and the likely implementation. Until that lands, sit keeps consuming sandhi's `sandhi_server_*` surface.

---

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). Per-release benchmark snapshots are in [`../benchmarks/`](../benchmarks/) — latest [`2026-08-18-v1.4.3.md`](../benchmarks/2026-08-18-v1.4.3.md). Security audit reports are in [`../audit/`](../audit/).*
