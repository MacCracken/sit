# sit Development Roadmap

**Forward-looking only.** Shipped history lives in [`CHANGELOG.md`](../../CHANGELOG.md), the tagged-release source of truth. The live snapshot (current version, dependency versions, source layout, command inventory, recent releases) lives in [`state.md`](state.md). This file is only what is *next*.

> **How this file is organized.** Work is slotted by **target version**:
> - the **1.7.x** patch line (no new surface, in suggested order)
> - one section per planned **minor**, 1.8.0 onwards
> - **1.x (unscheduled)** for work that is wanted but not yet committed to a release
>
> A slot is a plan, not a promise. When a release ships, **delete its items** (the CHANGELOG is the record) and re-slot anything that slipped. Do not leave struck-through entries behind. Upstream asks, holds and closed decisions sit at the end, outside the version slots.

**Where we are:** `1.7.5`, on cyrius 6.7.15. The 1.6.x line closed with a P(-1) audit ([`../audit/2026-10-19-audit.md`](../audit/2026-10-19-audit.md); 16 HIGH, all fixed). 1.7.0 bound bearer tokens to remotes ([ADR 0014](../adr/0014-bearer-tokens-bound-to-remotes.md)) and refuses commits of unresolved conflicts. 1.7.1 took patra 1.16.x and makes a refused object insert or commit fail before any ref moves; 1.7.2 finished that sweep and shipped the audit's small fixes; 1.7.3 made `rebase` and `describe` walk every parent and see nested ref names; 1.7.4 bounded `sit serve` (nothing kept per read request, nor per TLS connection) and lifted git read mode's 64 MiB pack and depth-64 delta limits; 1.7.5 took the residuals 1.7.4 measured: a git-mode object read and a `sit serve` ref push keep nothing of sit's, and what each still keeps is sankoch's 32 bytes per inflate (upstream asks). **35 commands.** No 1.7.x patch is slotted; the rest is the long-standing structural and CLI work.

---

## SemVer tiers (post-1.0)

- **Patch (`1.x.y`):** no new *observable* surface. Bug fixes, perf, internal refactors, toolchain / dep bumps, consuming upstream fixes. Safe to take blindly.
- **Minor (`1.x.0`):** new *backward-compatible* surface: a command, flag, config key, public-API symbol, or wire capability.
- **Major (`2.0.0`):** reserved for a breaking change to the CLI, `.sit/` layout, wire protocol, or public API. None planned.

Each item ships under the usual test / fuzz / poison / bench gates.

---

## 1.7.x — patch line (no new surface)

Audit ids (C1, D6, …) refer to [`../audit/2026-10-19-audit.md`](../audit/2026-10-19-audit.md).

Nothing is slotted for the 1.7.x line.

---

## 1.8.0 — history ergonomics (minor)

New behaviour on existing commands, which is minor-level surface under the tiers above.

- **`stash pop` with a three-way apply (A5 follow-on).** Since 1.6.4, pop refuses once HEAD has moved past the stash's base (it used to roll every later commit back). Applying the stash onto a moved HEAD is cherry-pick of the stash commit without committing: `_apply_one_commit` minus the commit, through `_apply_conflicted_merge` on a conflict.
- **Honour `sit merge -m <msg>`.** Accepted and ignored since the command existed; CI has passed it since v0.5.x without noticing. git uses it to set the merge commit's message. It changes commit text, so it wants its own tests. The tolerance is pinned at `merge.cyr:729`, `tests/integration/run.sh:797` and `.github/workflows/ci.yml:561`.
- **Reflog `expire` / `delete` and the `@{<date>}` selector.**
  - Reflog entries are unbounded, so `fsck --prune` reclaims reflog-protected objects only via `--prune-now`; expiry closes that.
  - `expire` / `delete` are new subcommands, and `@{<date>}` is new selector syntax.
  - Any new ref or log location needs a matching root in `fsck_collect_roots` and a test that drops `.sit/logs` first (CLAUDE.md).

## 1.9.0 — storage: pack bundles + `gc` (minor)

The largest measured gap sit has. Remeasured 2026-08-20 at 1,600 commits, both sides verified:

| | sit `objects.patra` | git packed | git loose | ratio |
|---|---:|---:|---:|---:|
| 1,600 commits | **64.3 MB** | 1.6 MB | 4.3 MB | **39×** |

sit is 15× git's *unpacked* store as well, so page overhead is not the explanation: the fixture's tree content is quadratic in commit count, and successive trees are near-identical, which is exactly what delta compression collapses. The read-performance argument is gone (lookups have been flat since patra's result-buffer fix, folded in 1.4.3); what remains is disk and transfer size.

**Delta *generation* shipped in 1.6.1** (`src/delta.cyr`, differential-tested against the read-side interpreter: one byte changed in 8 KiB gives a 35-byte delta). What remains is storage and repack, a storage-format change in four coupled parts:

1. **Schema:** an `objects` column naming the delta base, declared in two places (`object_db.cyr`, `wire.cyr`), plus migration for existing repos.
2. **`read_object`:** reconstruct transparently. It is already the single choke point.
3. **`fsck` integrity:** it re-hashes stored bytes against the object id. For a delta those bytes are not the content, so the pass must reconstruct first, or every deltified object reads `bad`.
4. **`copy_objects`:** wire transfer copies raw compressed bytes DB-to-DB by design (CLAUDE.md forbids re-hashing on the hot path). A delta's base has to travel with it, and "the base is reachable anyway" needs proving, not assuming.

A negotiated wire capability is a further step. **Ride-along: index paths over 255 bytes (B7 rest).** 1.6.4 refuses them at `sit add` and makes `rewrite_index` transactional. Lifting the limit needs a wider column, an index migration that belongs with this schema change.

## 1.10.0 — serving many repos (minor)

- **HTTP base-path routing.** `sit serve` serves one repo at `/sit/v1/…`. Accepting `http://host/repos/foo` changes what the wire endpoint accepts and needs real routing in `serve.cyr`. It is what serving multiple repos behind one origin requires.

## 1.11.0 — `.git/` CLI parity (minor)

- **`sit status` / `log` / `diff` and `@{N}` on git repos.** The 1.2.0 *library* API already works on git; the CLI commands stay `.sit`-gated. Needs a shared `_compute_status_records()` in `diff.cyr` that both `cmd_status` and `api.cyr` use.
  - Two sites defer to this entry, cross-referenced there since the 1.4.7 sweep:
    - `resolve_ref_name` (`refs.cyr`): `@{N}` reflog specs are `.sit`-only, because a git repo has no `.sit/logs/`.
    - `resolve_prefix` (`object_db.cyr`): short-prefix disambiguation over a git store would have to walk the loose fanout plus every pack `.idx`.
  - Slot it earlier if a consumer asks for CLI parity.
- **A delta base cache, if `log` / `diff` walks need it.** 1.7.4 resolves chains to depth 4095 without one: git stores the newest version of an object whole, and the read API reads each file's HEAD blob once, so a cache would not pay there (depth-50 repo, all 320 blobs: 459 ms, the same as 1.7.3's recursion). Walks over many versions of one file are what a cache is for, and git mode gains those with this slot. Measure them first.

## 1.12.0 — CLI parsing via cmdit (minor)

Re-checked 2026-10-19 against **cmdit 1.4.0** (latest tag; its own pin is cyrius 6.7.9). Its `dist/cmdit.cyr` compiles on sit's cyrius 6.7.15. Demand-gated, not a forced sweep.

**Why it's worth it, and why it's modest.** sit has the most hand-rolled CLI of the tier-2 verb tools: 35 commands and ~100 `argc()` / `argv()` sites in 17 `src/` files. But it has **no global flags**, so cmdit's before-or-after-verb fix buys it nothing. The gain is:
- one verb table
- `--help` and `--version` (new surface, hence a minor)
- completions
- uniform errors

**Hand-rolled today**

- **Top-level dispatch:** `src/main.cyr:98-134` is `streq(cmd, …)` over 35 commands, with no aliases.
  - No args → `print_usage` (`main.cyr:44-84`, stderr) and exit 1. An unknown command prints "sit: unknown command" plus usage and exits 1.
  - There is no `--help` / `--version`, and every usage error exits **1**.
- **Fixed-index flags.** `cmd_*` read `argv(n)` by fixed index, and most flags count only at `argv(2)`, so a dash-leading path or message is treated as a positional:

  | flag | location |
  |---|---|
  | `add -f` | `index.cyr:17` |
  | `rm --cached` | `index.cyr:738` |
  | `reset --hard` | `index.cyr:637` |
  | `checkout -b` | `refs.cyr:724` |
  | `branch -d` | `refs.cyr:607` |
  | `tag -d` / `-a` / `-s` | `refs.cyr:428,470,472` |
  | `merge --abort` / `-S` | `merge.cyr:751,779` |
  | `rebase --abort` / `--continue` | `rebase.cyr:257,292` |
  | `config --global` | `config.cyr:302` |
- **Scanning loops:**

  | command | function | notes |
  |---|---|---|
  | `log` | `cmd_log`, `commit.cyr:983` | |
  | `commit -S` / `-m` | `cmd_commit`, `commit.cyr:1138` | |
  | `reflog -n` | `cmd_reflog`, `reflog.cyr:379` | a missing value is ignored |
  | `fsck --prune` / `--prune-now` | `cmd_fsck`, `object_db.cyr:1106` | everything else is ignored |
  | `clone` | `cmd_clone`, `wire.cyr:1420` | |
  | `serve` | `cmd_serve`, `serve.cyr:1542` | `<repo>` fixed at `argv(2)` |
  | `diff` / `show` | `diff.cyr:1029,1299` | |
- **Sub-commands:**
  - `stash push | list | pop | drop` (default push): `cmd_stash`, `history.cyr:472`.
  - `key generate | show`: `cmd_key`, `sign.cyr:293`.
  - `remote add | list | remove` (default list): `cmd_remote`, `wire.cyr:1153`.
- **Silent tolerance is load-bearing.** `merge <branch> -m <msg>` ignores `-m` (1.8.0 above), and both the integration suite and CI pass it.
  - The `getenv` reads (`SIT_AUTHOR_*`, `SIT_OWL`, `HOME`, …) are not flag fallbacks and stay.

**Placement constraint.**
- Every `cmd_*` is in a `[lib]` module and ships in the bundles: `dist/sit.cyr` has 40 `fn cmd_` and `dist/sit-read.cyr` has 22.
- So `cmdit_*` calls must stay out of `[lib]` / `[lib.read]`. Put them in `src/main.cyr` or a new `src/cli.cyr` that neither profile lists, or owl and thoth inherit an unresolved dependency.
- That is also why a `[deps.cmdit]` git block is safe despite [ADR 0012](../adr/0012-deps-pinned-through-the-toolchain.md). The ADR covers the stdlib-folded modules; cmdit is not folded, and `distlib` leaving it out of `dist/sit.deps` is harmless when no bundled module calls it.

**Step 1 — top level only (no `cmd_*` or dist change)**

- **Dispatch:** 35 `cmdit_verb` rows plus `cmdit_dispatch` in `main.cyr`. Switch on `cmdit_verb_matched` and call the existing `cmd_*()`.
  - Handlers still index raw argv, so check the verb is `argv(1)`: a pre-verb `--` (consumed by cmdit) would shift every index.
- **Help:** `CMDIT_HELP` keeps `print_usage`. Generated help has no synopsis column, and named-positional help is on cmdit's v2 backlog.
- **Version:** `CMDIT_VERSION` → `cmdit_version(h, sit_version_string())` (`src/version.cyr:12`).
- **Unknown verb:** `cmdit_error(h) == CMDIT_ERR_UNKNOWN_VERB`, today's text, exit 1.
- **Optional:** a `completions` verb via `cmdit_completions`, as stiva does.

**Step 2 — per-command handles (only if wanted)**

- **Parsing:** parse each command in `cli.cyr` (a child handle plus `cmdit_parse_verb`), pass the values into `cmd_*`, and regenerate both bundles.

  | kind | flags |
  |---|---|
  | bools | `-f --cached -b -a -s -S --abort --continue --global --list --oneline --graph --staged --stat --prune --prune-now --force-absolute --stdio --tls --require-auth` |
  | strings | `-d -m --hard --unset --listen --token --cert --key` |
  | ints | `-n`, `--depth` (`cmdit_range` ≥ 1) |

  stash, key and remote become nested re-entry (`cmdit_dispatch_argv` on `cmdit_verb_argc` / `_argv`), each keeping its own unknown-sub-command text.
- **Gap, blocking diff/show only.** `-U<N>` is an *attached* short value, and cmdit rejects `-U3` as `CMDIT_ERR_BUNDLED`.
  - It is pinned by `tests/integration/run.sh:442,447` (`show -U0`, `show -U4611686018427387904`) and CI's "diff -U<N>" smoke (`ci.yml:399`).
  - Keep diff/show hand-rolled, or strip `-U*` before `cmdit_parse_verb`.
  - This is concrete demand for cmdit's v2-backlog "attached short value" as an opt-in per-flag modifier.
- **Caller-side rules (not gaps):**
  - serve's `--stdio` / `--listen` and `--tls` / `--stdio` exclusions, and `--tls` needing `--cert` / `--key` (`serve.cyr:1633-1680`)
  - `merge` registering `-m` and keeping "any flag → single-branch path"
  - config's `--list` / `--unset` / `<key>` exclusivity
- **Decide, don't drift:**
  - Dash-leading paths and messages will need `--`.
  - `atoi` junk (`-n x`) becomes an int error.
  - Arguments ignored today (fsck, reflog, extras) become errors.
- **`sit serve <repo> --stdio` is a cross-version contract.** The SSH client builds exactly that remote command line (`wire_ssh.cyr:410`), so it must keep parsing byte for byte.

**cyrius.cyml, tests, identity**

- **Deps:** there is no stdlib `flags` module to drop, and `args` + `io` are already in `[deps] stdlib`. Take the latest cmdit tag at the time:

  ```
  [deps.cmdit]
  git = "https://github.com/MacCracken/cmdit.git"
  tag = "1.4.0"
  modules = ["dist/cmdit.cyr"]
  ```
- **Tests:** `tests/sit.tcyr` / `tests/sit.fcyr` don't touch CLI parsing. The bar is `tests/integration/run.sh` plus CI's smoke steps (and `scripts/benchmark.sh`'s invocations), with stdout / stderr byte-identical.
- **argv safety:** `lib/args.cyr` (cyrius 6.7.15, `args_init` at `:167-173`) reads the command line into a heap buffer, so `cmdit_argv`'s stored pointers are safe. The old stack-buffer hazard ([architecture 001](../architecture/001-args-stack-buffer-lifetime.md), and the octopus comment at `merge.cyr:1361`) no longer applies.

## 1.x — unscheduled

Wanted, not yet committed to a release. Each earns its own minor when its time comes.

- **A commit-parent cache (commit-graph).** Every history walk reads each commit object afresh, about 75 µs apiece. That makes whole-ancestry walks cost about 150 ms per 2,000 commits: `find_merge_base` on every merge, `rebase`'s pending set, and `describe` when a merge lies between the commit and its nearest tag (1.7.3). git keeps a commit-graph file for the same reason. A parent table in `objects.patra`, filled on write and backfilled once, would cut the walks to table reads. Measure `merge-base` / `describe` / `rebase` on a 100k-commit fixture first.
- **Hooks** (`pre-commit`, `pre-push`, …), if a consumer asks.

---

## Upstream asks (not sit work)

Blocked on another repo. Per [CLAUDE.md](../../CLAUDE.md), cross-project requests go on the **target repo's** roadmap.

- **sankoch — DEFLATE match-finder throughput.** Targets the `add-1MB` `zlib_compress` floor (~100 ms, about 6× git and the largest single cost in `sit add`). sankoch has adopted it as its own **2.9.1** item ("the trigger has fired"). sit's pin is sankoch 2.8.7 at cyrius 6.7.15, so it arrives with the cyrius release that folds sankoch 2.9.1.

- **sandhi — an allocator-taking `sandhi_server_content_length`.** It reads the header through `sandhi_server_find_header`, so the value lands on the global heap on every call. `_sandhi_server_recv_request_dl` calls it on every request with a body, so a long-running server keeps about 8 B per such request. `sit serve` parses `Content-Length` itself over its request arena since 1.7.4 (`_serve_content_length`, differential-fuzzed against sandhi's), but cannot reach the accept loop's call. An `_a` form, or an in-place scan that allocates nothing, closes both.
- **sankoch — every inflate keeps 32 B: `br_init`'s bit reader.** `br_init` (`lib/sankoch.cyr`, sankoch 2.8.7 at cyrius 6.7.15) takes its 32-byte reader from `_sankoch_alloc` on every `_deflate_decompress_inner` / `_deflate_decompress_dict_inner` call and never frees it, so `zlib_decompress` and `zlib_decompress_with_ratio_cap` keep 32 B per call after warm-up (an `fl_alloc` / `fl_free` round trip keeps 0). Since 1.7.5 it is all `sit serve` and git read mode still keep:
  - `sit serve`'s fast-forward check inflates every commit it walks, so a ref push over 2,000 commits keeps 63,968 B, all of it this.
  - A git-mode read keeps 32 B per loose object and about 1 KB per packed object at an average chain depth of 33, once per inflate in the chain.

  A stack reader in the two decoders, which own its lifetime, closes both.

## On hold — keep sandhi

Dropping sandhi for a hand-rolled `net`-direct loopback HTTP/1.0 server (surface minimization) is deliberately *not* scheduled. A future cyrius change is expected to make stdlib / lib consumption easier, which changes both the trade-off and the likely implementation. Until then, sit keeps consuming sandhi's `sandhi_server_*` surface (sandhi 1.13.1 at cyrius 6.7.15).

## Decided — do not re-attempt

Closed by measurement. The reasoning lives where cited; they are listed here only so they are not re-opened blindly.

- **`clone` has no algorithmic defect left** (1.4.9). Its cost is a fixture whose content is quadratic in commit count, plus git's delta compression: the 1.9.0 item above. Phase profile in the 1.4.9 CHANGELOG entry.
- **Memoizing `_wildmatch` is declined** (1.4.9). Both shapes cost 7–18% on `is_ignored` for a benign edge, since budget exhaustion shows a file rather than hiding it. Numbers at the call site in `src/index.cyr`; the `**` scan has been charged to the budget since 1.6.4.

---

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). Per-release benchmark snapshots are in [`../benchmarks/`](../benchmarks/), latest [`2026-10-19-v1.7.4.md`](../benchmarks/2026-10-19-v1.7.4.md). Security audit reports are in [`../audit/`](../audit/), latest [`2026-10-19-audit.md`](../audit/2026-10-19-audit.md).*
