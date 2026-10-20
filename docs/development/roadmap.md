# sit Development Roadmap

**Forward-looking only.** What shipped is in [`CHANGELOG.md`](../../CHANGELOG.md); the live snapshot (version, dependency pins, source layout, commands, consumers) is in [`state.md`](state.md). This file holds what is next and nothing else.

> **How this file is organized.** One section per planned **minor**, in order, then **1.x (unscheduled)** for wanted work not yet committed to a release. Patches between minors (fixes, toolchain bumps, consuming upstream fixes) take the next patch number as they arise and are not pre-slotted. Upstream asks, holds and closed decisions follow the slots.
>
> A slot is a plan, not a promise. When an item ships, **delete it** (the CHANGELOG is the record). When a slot slips, re-slot it. At every release, re-check the line pins the remaining items cite.

---

## SemVer tiers (post-1.0)

- **Patch (`1.x.y`):** no new *observable* surface. Bug fixes, perf, internal refactors, toolchain / dep bumps, consuming upstream fixes.
- **Minor (`1.x.0`):** new *backward-compatible* surface: a command, flag, config key, public-API symbol, or wire capability.
- **Major (`2.0.0`):** reserved for a breaking change to the CLI, `.sit/` layout, wire protocol, or public API. None planned.

Each item ships under the usual test / fuzz / poison / bench gates.

---

## 1.10.0 — storage: pack bundles + `gc` (minor)

The largest measured gap sit has. Measured 2026-08-20 at 1,600 commits, both sides verified:

| | sit `objects.patra` | git packed | git loose | ratio |
|---|---:|---:|---:|---:|
| 1,600 commits | **64.3 MB** | 1.6 MB | 4.3 MB | **39×** |

sit is 15× git's *unpacked* store as well, so page overhead is not the explanation: the fixture's tree content is quadratic in commit count, and successive trees are near-identical, which is exactly what delta compression collapses. Lookups are flat (patra's result-buffer fix); what remains is disk and transfer size.

Delta *generation* exists (`src/delta.cyr`, differential-tested against the read-side interpreter: one byte changed in 8 KiB gives a 35-byte delta). What remains is storage and repack, a storage-format change in four coupled parts:

1. **Schema:** an `objects` column naming the delta base, declared in two places (`object_db.cyr`, `wire.cyr`), plus migration for existing repos.
2. **`read_object`:** reconstruct transparently. It is already the single choke point.
3. **`fsck` integrity:** it re-hashes stored bytes against the object id. For a delta those bytes are not the content, so the pass must reconstruct first, or every deltified object reads `bad`.
4. **Transfer:** `copy_objects` moves raw compressed bytes and verifies each object against its id before storing it (`_object_verify`, CLAUDE.md). A deltified object can only be verified once its base is present, so the base has to travel first (or already be in the target), and verification must reconstruct the same way `fsck` does.

A negotiated wire capability is a further step. **Ride-along: index paths over 255 bytes (B7 rest).** `sit add` and `sit mv` refuse them and `rewrite_index` is transactional. Lifting the limit needs a wider column, an index migration that belongs with this schema change.

## 1.11.0 — serving many repos (minor)

- **HTTP base-path routing.** `sit serve` serves one repo at `/sit/v1/…`. Accepting `http://host/repos/foo` changes what the wire endpoint accepts and needs real routing in `serve.cyr`. It is what serving multiple repos behind one origin requires.
- **Per-repo caches (R6).** The patra object-store handle (`get_object_db`, `object_db.cyr`) and the `.idx` / `.pack` mapping cache (`_git_file_cached`, `git_pack.cyr`, keyed by repo-relative path) live for the process, so a second `sit_repo_open` in one process — owl or thoth switching repos, or a multi-repo server — reads the first repo's objects: two .sit repos A then B showed B's clean files as `N`, and two git repos with a pack of the same name read A's pack. Close and reset both when the root or backend changes, key the mappings by absolute path, and unmap packs that leave the listing. (The last-pack cache, `_git_last_idx`, is already reset per open.)

## 1.12.0 — `.git/` CLI parity (minor)

- **`sit status` / `log` / `diff` and `@{N}` on git repos.** The *library* API already works on git; the CLI commands stay `.sit`-gated. Needs a shared `_compute_status_records()` in `diff.cyr` that both `cmd_status` and `api.cyr` use.
  - Two sites defer to this entry:
    - `resolve_ref_name` (`refs.cyr`): `@{N}` reflog specs are `.sit`-only, because a git repo has no `.sit/logs/`.
    - `resolve_prefix` (`object_db.cyr`): short-prefix disambiguation over a git store would have to walk the loose fanout plus every pack `.idx`.
  - Slot it earlier if a consumer asks for CLI parity.
- **git-mode status on ordinary repos (R2).** The read path applies the write path's rules: `parse_tree` keeps only 100644 / 40000 entries and drops names that fail the checkout-safety rules (`aux.c`, `con/…`, `a:b.txt` on Linux), and `objects/info/alternates` is never read. So `sit_repo_status` calls executable files, symlinks, submodule contents and every file of a `git clone --shared` repo untracked, where `git status` is clean. Keep 100755 entries, compare 120000 against the link target, skip gitlinks (and their directories in the untracked walk), apply the NTFS / `:` rules only when writing a checkout, and read alternates or report their absence as an error. Mode-aware entries are new API surface, which is why this rides with CLI parity.
- **A delta base cache, if `log` / `diff` walks need it.** Chains resolve to depth 4095 without one: git stores the newest version of an object whole, and the read API reads each file's HEAD blob once, so a cache would not pay there (depth-50 repo, all 320 blobs: 459 ms either way). Walks over many versions of one file are what a cache is for, and git mode gains those with this slot. Measure them first.

## 1.x — unscheduled

Wanted, not yet committed to a release. Each earns its own minor when its time comes.

- **A commit-parent cache (commit-graph).** Every history walk reads each commit object afresh, about 75 µs apiece. That makes whole-ancestry walks cost about 150 ms per 2,000 commits: `find_merge_base` on every merge, `rebase`'s pending set, and `describe` when a merge lies between the commit and its nearest tag. git keeps a commit-graph file for the same reason. A parent table in `objects.patra`, filled on write and backfilled once, would cut the walks to table reads. Measure `merge-base` / `describe` / `rebase` on a 100k-commit fixture first.
- **Hooks** (`pre-commit`, `pre-push`, …), if a consumer asks.
- **Per-command parsing through cmdit (ADR 0015's step 2), only if wanted.** 1.9.0 dispatches the top level through cmdit; each `cmd_*` still reads its own arguments by position. Moving them onto cmdit handles would give per-command `--help` and uniform flag errors, at the cost of changing how 35 commands read their arguments. The calls must stay in `src/main.cyr` or a new `src/cli.cyr` outside both `[lib]` profiles (the bundles ship every `cmd_*`). What is hand-rolled today:

  - **Fixed-index flags.** `cmd_*` read `argv(n)` by fixed index, and most flags count only at `argv(2)`:
  
    | flag | location |
    |---|---|
    | `add -f` | `index.cyr:17` |
    | `rm --cached` | `index.cyr:774` |
    | `reset --hard` | `index.cyr:663` |
    | `checkout -b` | `refs.cyr:771` |
    | `branch -d` | `refs.cyr:653` |
    | `tag -d` / `-a` / `-s` | `refs.cyr:473,515,517` |
    | `merge --abort` | `merge.cyr:732`; `-S` / `-m <msg>` are scanned anywhere (`cmd_merge`'s argument loop) |
    | `rebase --abort` / `--continue` | `rebase.cyr:257,292` |
    | `config --global` | `config.cyr:360` |
  - **Option-shaped names are refused** where a name is created (`ref_name_is_option`, `refs.cyr`) and where `commit` takes a bare message (`commit.cyr`); a cmdit table must keep those refusals.
  - **Scanning loops:**
  
    | command | function | notes |
    |---|---|---|
    | `log` | `cmd_log`, `commit.cyr:1013` | |
    | `commit -S` / `-m` | `cmd_commit`, `commit.cyr:1168` | with no message, a merge's saved `-m` (`MERGE_MSG`) |
    | `reflog -n` | `cmd_reflog`, `reflog.cyr:399` | a missing value is ignored; `show` / `expire` / `delete` sub-commands |
    | `fsck --prune` / `--prune-now` | `cmd_fsck`, `object_db.cyr:1186` | everything else is ignored |
    | `clone` | `cmd_clone`, `wire.cyr:1565` | |
    | `serve` | `cmd_serve`, `serve.cyr:1602` | `<repo>` fixed at `argv(2)` |
    | `diff` / `show` | `diff.cyr:1058,1336` | |
  - **Sub-commands:**
    - `stash push | list | pop | drop` (default push): `cmd_stash`, `history.cyr:587`.
    - `key generate | show`: `cmd_key`, `sign.cyr:293`.
    - `remote add | list | remove` (default list): `cmd_remote`, `wire.cyr:1287`.
    - `reflog [show] | expire | delete` (default show): `cmd_reflog`, `reflog.cyr:399`.
    - The `getenv` reads (`SIT_AUTHOR_*`, `SIT_OWL`, `HOME`, …) are not flag fallbacks and stay.

  The plan:

  - **Parsing:** parse each command in `cli.cyr` (a child handle plus `cmdit_parse_verb`), pass the values into `cmd_*`, and regenerate both bundles.
  
    | kind | flags |
    |---|---|
    | bools | `-f --cached -b -a -s -S --abort --continue --global --list --oneline --graph --staged --stat --prune --prune-now --force-absolute --stdio --tls --require-auth` |
    | strings | `-d -m --hard --unset --listen --token --cert --key --expire=` |
    | ints | `-n`, `--depth` (`cmdit_range` ≥ 1) |
  
    stash, key, remote and reflog become nested re-entry (`cmdit_dispatch_argv` on `cmdit_verb_argc` / `_argv`), each keeping its own unknown-sub-command text.
  - **Gap, blocking diff/show only.** `-U<N>` is an *attached* short value, and cmdit rejects `-U3` as `CMDIT_ERR_BUNDLED`.
    - It is pinned by `tests/integration/run.sh:475,480` (`show -U0`, `show -U4611686018427387904`) and CI's "diff -U<N>" smoke (`ci.yml:399`).
    - Keep diff/show hand-rolled, or strip `-U*` before `cmdit_parse_verb`.
    - cmdit's roadmap already records sit's `-U<N>` as demand for an opt-in "attached short value" (its won't-ship-without-cause list).
  - **Caller-side rules (not gaps):**
    - serve's `--stdio` / `--listen` and `--tls` / `--stdio` exclusions, and `--tls` needing `--cert` / `--key` (`serve.cyr:1693-1738`)
    - `merge` taking `-S` / `-m <msg>` before or after its branches
    - config's `--list` / `--unset` / `<key>` exclusivity
  - **Decide, don't drift:**
    - Dash-leading paths and messages will need `--`.
    - `atoi` junk (`-n x`) becomes an int error.
    - Arguments ignored today (fsck, reflog, extras) become errors.
  - **`sit serve <repo> --stdio` is a cross-version contract.** The SSH client builds exactly that remote command line (`wire_ssh.cyr:408`), so it must keep parsing byte for byte.
- **An arena per public-API call (R1, rest).** `sit_repo_status` frees every blob and file it compares; what it still keeps, ~94 KB per call on 200 files, is the flattened HEAD tree, the worktree listing and the result records, all on the bump heap. Running each call on an arena rewound at entry, as `sit serve` does per request, would close it — but the returned vec is the caller's, so the records must be copied out or the contract changed (ADR 0009). Measure with `tests/integration/api_heap_probe.cyr`.

---

## Upstream asks (not sit work)

Blocked on another repo. Per [CLAUDE.md](../../CLAUDE.md), each belongs on the **target repo's** roadmap; each entry says whether it is there.

- **sankoch — DEFLATE match-finder throughput.** Targets the `add-1MB` `zlib_compress` floor (~100 ms, about 6× git and the largest single cost in `sit add`). **On sankoch's roadmap** as its 2.9.1 item; it reaches sit with the cyrius release that folds that sankoch.
- **sankoch — every inflate keeps 32 B: `br_init`'s bit reader.** `br_init` (`src/bitreader.cyr` in sankoch) takes its 32-byte reader from `_sankoch_alloc` on every `_deflate_decompress_inner` / `_deflate_decompress_dict_inner` call and never frees it, so `zlib_decompress` and `zlib_decompress_with_ratio_cap` keep 32 B per call (an `fl_alloc` / `fl_free` round trip keeps 0). It is all `sit serve` and git read mode still keep: a ref push over 2,000 commits keeps 63,968 B, and a git-mode read 32 B per loose object, about 1 KB per packed object at chain depth 33. A stack reader in the two decoders, which own its lifetime, closes both. **Not yet on sankoch's roadmap.**
- **sandhi — an allocator-taking `sandhi_server_content_length`.** It reads the header through `sandhi_server_find_header`, so the value lands on the global heap on every call. `_sandhi_server_recv_request_dl` calls it on every request with a body, so a long-running server keeps about 8 B per such request. `sit serve` parses `Content-Length` itself over its request arena (`_serve_content_length`, differential-fuzzed against sandhi's), but cannot reach the accept loop's call. An `_a` form, or an in-place scan that allocates nothing, closes both. **Not yet on sandhi's roadmap.**
- **patra — `page_write`'s return is ignored inside statements (L12).** `tbl_insert`, `tbl_delete`, `btree_insert` and `_bt_push_up` discard it, so in autocommit a page that never reached the disk is reported as `PATRA_OK` (reproduced with `RLIMIT_FSIZE` standing in for EIO / ENOSPC: `sit add` printed "added" and staged nothing). Inside a transaction the failure is reported, which is why sit writes the index only in transactions. **On patra's own roadmap** (its "Open — patra's own" list, found there at 1.16.2).

## On hold — keep sandhi

Dropping sandhi for a hand-rolled `net`-direct loopback HTTP/1.0 server (surface minimization) is deliberately *not* scheduled. A future cyrius change is expected to make stdlib / lib consumption easier, which changes both the trade-off and the likely implementation. Until then, sit keeps consuming sandhi's `sandhi_server_*` surface.

## Decided — do not re-attempt

Closed by measurement. The reasoning lives where cited; they are listed here only so they are not re-opened blindly.

- **`clone` has no algorithmic defect left** (1.4.9). Its cost is a fixture whose content is quadratic in commit count, plus git's delta compression: the 1.10.0 item above. Phase profile in the 1.4.9 CHANGELOG entry.
- **Memoizing `_wildmatch` is declined** (1.4.9). Both shapes cost 7–18% on `is_ignored` for a benign edge, since budget exhaustion shows a file rather than hiding it. Numbers at the call site in `src/index.cyr`.

---

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). Benchmark snapshots are in [`../benchmarks/`](../benchmarks/); security audit reports in [`../audit/`](../audit/). Audit ids (A5, B7, L12, R1, R2, R6, …) refer to those reports.*
