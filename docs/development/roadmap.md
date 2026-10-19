# sit Development Roadmap

**Forward-looking only.** Shipped history lives in [`CHANGELOG.md`](../../CHANGELOG.md) (the tagged-release source of truth); the live snapshot — current version, dependency versions, source layout, command inventory, recent releases — lives in [`state.md`](state.md). This file is only what is *next*.

> **How this file is organized.** Backlog items are grouped by **what kind of work they are**, not by a version number, because version-keyed headings go stale the moment a release ships. Only the *themed minor line* carries version numbers, because those are deliberate scope commitments. When an item ships, **delete it** — the CHANGELOG is the record. Do not leave struck-through entries behind.

**Where we are**: `1.6.3`. The `1.3.x` line went almost entirely to audit work
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

- **`sit merge -m <msg>` is accepted and ignored.** It has been since the
  command existed, and CI has passed it since v0.5.x without noticing. git uses
  it to set the merge commit's message. Honouring it is small but changes commit
  text, so it wants its own tests rather than riding along with a fix — 1.6.2
  restored the tolerance rather than expanding scope.


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

---

## Adopting cmdit (CLI parsing)

Surveyed 2026-10-14 against cmdit 1.2.6 (1.3.0 has the same API). Demand-gated, not a forced
sweep. sit has the most hand-rolled CLI of the tier-2 verb tools — 35 commands, ~100
`argc()`/`argv()` sites in 16 `src/` files — but **no global flags**, so the before-or-after-verb
fix behind `cmdit_dispatch` buys it nothing. The gain is one verb table, `--help`/`--version`,
completions and uniform errors, in two independent steps.

**Hand-rolled today**

- `src/main.cyr:84-134`: `streq(argv(1), …)` over 35 commands, no aliases. No args →
  `print_usage` (`main.cyr:42-82`, stderr) + exit 1; unknown → "sit: unknown command" + usage,
  exit 1. No `--help`/`--version` anywhere; every usage error exits **1**.
- `cmd_*` read `argv(n)` by fixed index, and most flags count **only at `argv(2)`**: `add -f`
  (`index.cyr:16`), `rm --cached` (`:639`), `reset --hard` (`:540`), `checkout -b`
  (`refs.cyr:643`), `branch -d` (`:529`), `tag -d`/`-a`/`-s` (`:339,380-382`),
  `merge --abort`/`-S` (`merge.cyr:715,742`), `rebase --abort`/`--continue`
  (`rebase.cyr:151,183`), `config --global` (`config.cyr:299`). So a dash-leading path or
  message is a positional today.
- Scanning loops: `log` (`commit.cyr:824-845`), `commit -S`/`-m` (`:977-990`), `reflog -n`
  (`reflog.cyr:386-389`, missing value ignored), `fsck --prune`/`--prune-now`
  (`object_db.cyr:1073-1075`, all else ignored), `clone` (`wire.cyr:1256-1280`), `serve`
  (`serve.cyr:1357-1425`, `<repo>` fixed at `argv(2)`), `diff`/`show`
  (`diff.cyr:941-975,1209-1230`).
- Sub-commands: `stash push|list|pop|drop` (default push, `history.cyr:439-446`),
  `key generate|show` (`sign.cyr:271-279`), `remote add|list|remove` (default list,
  `wire.cyr:999-1006`).
- Silent tolerance is load-bearing: `merge <branch> -m <msg>` ignores `-m` (`merge.cyr:693-711`,
  the patch-line item above); `tests/integration/run.sh:784` and `ci.yml:545` both pass it.
  The `getenv` reads (`SIT_AUTHOR_*`, `SIT_OWL`, `HOME`, …) are not flag fallbacks and stay.

**Placement constraint.** Every `cmd_*` is in a `[lib]` module and ships in `dist/sit.cyr` (40
`fn cmd_`) and `dist/sit-read.cyr` (22). `cmdit_*` calls must stay out of `[lib]`/`[lib.read]` —
in `src/main.cyr` or a new `src/cli.cyr` neither profile lists — or owl and thoth inherit an
unresolved dependency. That is also why a `[deps.cmdit]` git block is safe despite
[ADR 0012](../adr/0012-deps-pinned-through-the-toolchain.md): the ADR covers the stdlib-folded
modules, cmdit is not folded, and `distlib` leaving it out of `dist/sit.deps` is harmless when no bundled module calls
it.

**Step 1 — top level only (no `cmd_*` or dist change)**

- [ ] 35 `cmdit_verb` rows + `cmdit_dispatch` in `main.cyr`; switch on `cmdit_verb_matched` and
  call the existing `cmd_*()`. Handlers still index raw argv, so check the verb is `argv(1)` — a
  pre-verb `--` (consumed by cmdit) would shift every index.
- [ ] `CMDIT_HELP` → keep `print_usage` (generated help has no synopsis column; named-positional
  help is cmdit v2 backlog). `CMDIT_VERSION` → `cmdit_version(h, sit_version_string())`
  (`src/version.cyr:11`). Unknown verb → `cmdit_error(h) == CMDIT_ERR_UNKNOWN_VERB`, today's
  text, exit 1. Optional `completions` verb via `cmdit_completions`, as stiva does.

**Step 2 — per-command handles (only if wanted)**

- [ ] Parse each command in `cli.cyr` (child handle + `cmdit_parse_verb`), pass values into
  `cmd_*`, regenerate both dist bundles. Bools: `-f --cached -b -a -s -S --abort --continue
  --global --list --oneline --graph --staged --stat --prune --prune-now --force-absolute --stdio
  --tls --require-auth`; strings: `-d -m --hard --unset --listen --token --cert --key`; ints:
  `-n`, `--depth` (`cmdit_range` ≥ 1). stash/key/remote as nested re-entry
  (`cmdit_dispatch_argv` on `cmdit_verb_argc`/`_argv`), each keeping its own
  unknown-sub-command text.
- **Gap — blocks diff/show only:** `-U<N>` is an *attached* short value (`diff.cyr:949,1215`);
  cmdit rejects `-U3` as `CMDIT_ERR_BUNDLED`. Pinned by `run.sh:434-440` (`show -U0`,
  `show -U4611686018427387904`) and the `ci.yml:383` "diff -U<N>" smoke. Keep diff/show
  hand-rolled or strip `-U*` before `cmdit_parse_verb`. This is concrete demand for cmdit's
  v2-backlog "attached short value" as an opt-in per-flag modifier.
- Caller-side, not gaps: serve's `--stdio`/`--listen` and `--tls`/`--stdio` exclusions and
  `--tls` needing `--cert`/`--key` (`serve.cyr:1430-1477`); `merge` registering `-m` (accept,
  ignore) and keeping "any flag → single-branch path" (`merge.cyr:703-711`); config's
  `--list`/`--unset`/`<key>` exclusivity.
- Decide, don't drift: dash-leading paths/messages will need `--`; `atoi` junk (`-n x`) becomes
  an int error; arguments ignored today (fsck, reflog, extras) become errors.
- `sit serve <repo> --stdio` is a cross-version contract — the SSH client builds exactly that
  remote command line (`wire_ssh.cyr:403-407`) — so it must keep parsing byte-for-byte.

**cyrius.cyml, tests, identity**

- [ ] No stdlib `flags` to drop; `args` + `io` already in `[deps] stdlib`. No pin bump: cmdit's
  dist compiles on 6.6.20 (1.3.0 and 1.4.0 both checked 2026-10-19). cmdit is tagged through
  1.4.0 as of 2026-10-19.
  ```
  [deps.cmdit]
  git = "https://github.com/MacCracken/cmdit.git"
  tag = "1.3.0"
  modules = ["dist/cmdit.cyr"]
  ```
- [ ] `tests/sit.tcyr`/`tests/sit.fcyr` don't touch CLI parsing. The bar is
  `tests/integration/run.sh` + the CI smoke steps in `.github/workflows/ci.yml` (and
  `scripts/benchmark.sh`'s invocations), stdout/stderr byte-identical.
- [ ] `docs/architecture/001` and `merge.cyr:1079-1088` describe `args_init` reading into a stack
  buffer; the 6.6.20 stdlib heap-allocates it (`lib/args.cyr:138-149`), so `cmdit_argv`'s stored
  pointers are safe. Update both notes when this lands.

References: cmdit `README.md` and `docs/adr/0002-verb-dispatch.md` (identify-and-return,
nesting as re-entry); stiva `src/main.cyr` is the worked verb tool.
