# sit Development Roadmap

**Forward-looking only.** Shipped history lives in [`CHANGELOG.md`](../../CHANGELOG.md) (the tagged-release source of truth); the live snapshot — current version, dependency versions, source layout, command inventory, recent releases — lives in [`state.md`](state.md). This file is only what is *next*.

> **How this file is organized.** Backlog items are grouped by **what kind of work they are**, not by a version number, because version-keyed headings go stale the moment a release ships. Only the *themed minor line* carries version numbers, because those are deliberate scope commitments. When an item ships, **delete it** — the CHANGELOG is the record. Do not leave struck-through entries behind.

**Where we are**: `1.6.1`. The `1.3.x` line went almost entirely to audit work
(two security audits, see [`../audit/`](../audit/)) and `1.4.x` to correctness
and growth curves — `status` is no longer superlinear (4.98× git at 1,000 files,
was 26.64×), the last four unfuzzed parsers have harnesses, every deferral
comment in `src/` was swept, and an HFS dot-directory spoofing hole
(CVE-2014-9390 class) is closed. `1.4.9` emptied the patch line, closing three
items by measuring them rather than coding them. `1.5.0`–`1.5.1` are the first
feature work since 1.3.0: annotated + signed tags, `sit mv`, `sit describe`,
then `cherry-pick`, `revert` and `stash`. **33 commands.** Audit backlogs are
empty. Next up: `1.6.0` (TLS trust hardening).

⚠ **Three data-loss bugs were found in that feature work, all one root cause** —
the fsck reachability walk not knowing about an edge. S-27 missing referents
(1.4.0), tag objects walked as leaves (1.5.0), and `.sit/refs/stash` not being a
root (1.5.1). Each was A/B-verified against a pre-fix build with the reflog
removed, and each would have been deleted by `fsck --prune-now`. **Any new
object kind or new ref location needs a matching root/edge in
`fsck_collect_roots` / `fsck_walk_reachable`, and a test that drops
`.sit/logs` first so reflog protection cannot mask it.**

---

## SemVer tiers (post-1.0)

- **Patch (`1.x.y`)** — no new *observable* surface: bug fixes, perf, internal refactors, toolchain/dep bumps, consuming upstream fixes. Safe to take blindly.
- **Minor (`1.x.0`)** — new *backward-compatible* surface: a command, flag, config key, public-API symbol, or wire capability.
- **Major (`2.0.0`)** — reserved for a breaking change to the CLI, `.sit/` layout, wire protocol, or public API. None planned.

Nothing below blocks anything else; ordering within a section is a recommendation, not a contract. Each ships under the usual test / fuzz / bench gates.

---

## Patch line — correctness & hardening (no new surface)

### Closed by measurement — kept as decisions, not tasks

The patch line is **empty**. These two are recorded so they are not
re-attempted blindly; neither is work.

- **`clone` — nothing left on the patch line; the remaining work is packing.**
  *(1.4.8 diagnosed the phases; 1.4.9 finished the job and found no defect.)*

  Phase profile inside `walk_reachable_phased`, the phase that dominates clone:

  | phase | N=100 | N=1000 | growth |
  |---|---:|---:|---:|
  | p1 — commit chain | 7,796 µs | 78,113 µs | **10.0× (exactly linear)** |
  | p2 — batch prefetch | 1 µs | 1 µs | no-op for a local source |
  | p3 — tree walk | 29,471 µs | 1,873,566 µs | 63.6× |

  ⚠ **63.6× is sub-linear here, and 1.4.8's "2.3× residual" was an artefact of
  the wrong denominator.** p3's work is tree entries visited, not store bytes:
  the fixture adds one file per commit, so tree `i` carries `i+1` entries and
  the history holds `N(N+1)/2` of them — **5,050 → 500,500, a 99.1× increase**
  (verified against the fixtures, not just derived). Against that, p3 grew 63.6×
  and **per-entry cost improved, 5.83 → 3.74 µs**. 1.4.8 compared against store
  bytes (22×), which mixes in blobs that grow only linearly, and reported a
  residual that does not exist.

  So the entire `clone` row is (a) a fixture whose content is quadratic in commit
  count and (b) git's delta compression — see **Pack bundles + `gc` / repack**
  under *Structural*. There is no algorithmic defect left to chase, and this item
  is closed rather than carried.

### Test & tooling debt

- **~~Memoize `_wildmatch`~~ — built, measured, and declined in 1.4.9.**
  Kept here as a decision, not a task, so it is not re-attempted blindly.

  Two shapes were implemented and benchmarked against `is_ignored-10/50/200pat`:

  | shape | cost |
  |---|---|
  | arm the memo when the pattern has ≥3 star groups | **+14% / +15.6% / +18.4%** |
  | escalate on demand (plain first, memoized retry only on budget exhaustion) | **+7% / +7.3% / +8.8%** |

  Untouched controls moved −2% to −7% in the same runs, so the gap is real, not
  machine drift. Even the escalating shape pays, because the memo check lands in
  the `*` branch — which *is* the inner loop.

  What it buys does not justify that. Budget exhaustion returns "no match", so
  the only wrong answer possible is a file **appearing** in `sit status` that
  should have been ignored — the safe direction, and benign. The threshold is
  real but pathological (4 star groups over 32 chars completes in 41,448 steps;
  6 over 48 exhausts), and `is_ignored` runs per file per pattern on every
  `status` and `add`.

  If revisited: the only shape that can win is splitting the recursive core into
  plain and memoized copies so the hot path carries zero memo code — at the cost
  of ~80 duplicated lines of matcher, which is its own correctness hazard. The
  reasoning and numbers are also recorded at the call site in `src/index.cyr`.

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

- **Pack bundles + `gc` / repack.** Remeasured 2026-08-20 at 1,600 commits,
  both sides verified at 1,600 commits — **the previous figures were stale**:

  | | previously claimed | measured |
  |---|---:|---:|
  | sit `objects.patra` | 62.8 MB | **64.3 MB** |
  | git packed | 1.1 MB | **1.6 MB** |
  | git loose | 6.4 MB | **4.3 MB** |
  | ratio | ~57× | **39×** |

  Still the largest measured gap sit has. Note sit is **15× larger than git's
  *unpacked* store** as well, so patra page overhead is not the explanation:
  the fixture's tree content is quadratic in commit count and successive trees
  are near-identical — exactly what delta compression collapses.

  **Delta *generation* shipped in 1.6.1** (`src/delta.cyr`), differential-tested
  against the 1.2.0 interpreter: one byte changed in 8 KiB → a 35-byte delta;
  808 bytes appended to 8 KiB → 842 bytes. What remains is **storage and
  repack**, which is a storage-format change with four coupled parts:

  1. **Schema** — an `objects` column naming the delta base (declared in *two*
     places: `object_db.cyr` and `wire.cyr`), plus migration for existing repos.
  2. **`read_object`** — reconstruct transparently. It is already the documented
     single choke point, so this part is contained.
  3. **`fsck` integrity** — it re-hashes stored bytes against the object id.
     For a delta those bytes are not the content, so the pass must reconstruct
     first or it will report every deltified object as `bad`.
  4. **`copy_objects`** — wire transfer copies raw compressed bytes DB-to-DB by
     design (CLAUDE.md forbids re-hashing on the hot path). A delta's base has
     to travel with it, and "the base is reachable anyway" needs proving, not
     assuming.

  A negotiated wire capability is a further step beyond those four. Large.

---

## Minor line — themed `1.x.0`

Each is a self-contained scope commitment. **The themed line is empty** — `1.6.0` (TLS trust hardening) shipped, and nothing below is scheduled. Next scope commitment is an open choice; the strongest candidate is **pack bundles + `gc`** under *Structural*, which is the largest measured gap left.

> ⚠ **Numbering note.** `1.5.2` and `1.5.3` add commands and flags, which this
> file's own SemVer tiers call *minor* surface. They are numbered as patches at
> the maintainer's direction; each CHANGELOG entry records the discrepancy so
> the policy and the version number do not silently disagree. The convention
> started at `1.5.1` and is applied consistently rather than re-argued per
> release.

- **Reflog `expire` / `delete` + `@{<date>}` selector, and HTTP base-path
  routing** *(unscheduled; moved off the patch line in 1.4.9).* Both were filed
  under "Patch line — no new surface", and both plainly add surface: `expire` /
  `delete` are new subcommands and `@{<date>}` is new selector syntax, while
  accepting `http://host/repos/foo` changes what the wire endpoint accepts and
  needs real routing in `serve.cyr`. Per this file's own SemVer tiers those are
  **minors**. Substance unchanged: reflog entries are unbounded, so
  `fsck --prune` reclaims reflog-protected objects only via `--prune-now`, and
  expiry closes that; base-path routing is what serving multiple repos behind
  one origin requires.
- **`.git/` CLI parity** *(unscheduled).* `sit status` / `log` / `diff` and `@{N}` on git repos — the 1.2.0 *library* API already works on git; the CLI commands stay `.sit`-gated. Needs a shared `_compute_status_records()` in `diff.cyr` so it doesn't back-reference `api.cyr` in single-pass dist order. A `1.x.0` when a consumer wants CLI parity.

  Two source sites defer to this entry (cross-referenced there since the 1.4.7 sweep): `resolve_ref_name` (`refs.cyr`) — `@{N}` reflog specs are `.sit`-only, because a git repo has no `.sit/logs/`; and `resolve_prefix` (`object_db.cyr`) — short-prefix disambiguation over a git store would have to walk the loose fanout plus every pack `.idx`, so a git object must be named by full oid or a ref.

---

## Heavier / unscheduled

Each earns its own minor when its time comes.

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

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). Per-release benchmark snapshots are in [`../benchmarks/`](../benchmarks/) — latest [`2026-08-19-v1.4.8.md`](../benchmarks/2026-08-19-v1.4.8.md). Security audit reports are in [`../audit/`](../audit/).*
