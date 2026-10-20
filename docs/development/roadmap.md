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

## 1.x — unscheduled

Wanted, not yet committed to a release. Each earns its own minor when its time comes.

- **A commit-parent cache (commit-graph).** Every history walk reads each commit object afresh, about 75 µs apiece. That makes whole-ancestry walks cost about 150 ms per 2,000 commits: `find_merge_base` on every merge, `rebase`'s pending set, and `describe` when a merge lies between the commit and its nearest tag. git keeps a commit-graph file for the same reason. A parent table in `objects.patra`, filled on write and backfilled once, would cut the walks to table reads. Measure `merge-base` / `describe` / `rebase` on a 100k-commit fixture first.
- **Packs on the wire, as a negotiated capability.** Since 1.10.0 a packed object leaves the store expanded and compressed (level 1), so the wire format is unchanged, but a clone of the packed 1,600-commit fixture takes 6.96 s against 5.79 s for the same history unpacked, and the receiver stores everything loose until its own `sit gc`. Shipping the pack (or a thin pack of what the receiver lacks) needs a capability both ends advertise, and a receiver-side pass that reconstructs and verifies every object against its id before anything lands — `_object_verify`'s rule, applied after delta resolution (CLAUDE.md).
- **gc's remaining costs.** Measured on the 1,600-commit fixture: the first gc takes 5.3 s, 2.8 s of it reading 63 MB of rows out of patra; a repeat takes 2.6 s (git: 0.6 s). Commits are not deltified and are 251 KB of the 683 KB pack. Candidates: delta commits against their first parent, pack incrementally (new objects into a second pack) instead of `repack -a -d` every time. Measure on a larger, more varied history first.
- **Index paths over 255 bytes (B7 rest).** `sit add` and `sit mv` refuse them, and `rewrite_index` is transactional. Planned as a ride-along to 1.10.0's object-store schema change, which did not happen (packs, ADR 0016), so it needs its own `index.patra` migration: patra's STR column is a fixed 256-byte slot, and its chain columns (TEXT / BYTES) cannot be indexed, so the `path` index needs a fixed-width key for long paths (a hash of the path) beside the path itself.
- **git's index in read mode.** Since 1.12.0 `sit status` and `sit diff` on a `.git/` repository compare HEAD against the working tree, because sit does not read `.git/index` (DIRC v2–v4, with its extensions). A change staged with `git add` therefore shows as a change, and `diff --staged` is refused. A first-party, fuzzed DIRC reader would give git repositories sit's staged / unstaged split. Read-only, so no write-back.
- **The real `Host:` header.** The http client sends a literal `Host: 127.0.0.1` on every request. `sit serve` ignores it, but a reverse proxy in front of `sit serve --repos` that routes by name sees the wrong one (ADR 0017), so it needs a default server or a rewrite. Send the URL's host (and port, when it is not the default). The https path knows the name already (SNI and the TOFU pin).
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

- **`clone` has no algorithmic defect left** (1.4.9). Its cost is a fixture whose content is quadratic in commit count, which git's deltas collapse; 1.10.0's packs do that for storage (ADR 0016), and packs on the wire (unscheduled, above) would do it for transfer. Phase profile in the 1.4.9 CHANGELOG entry.
- **Memoizing `_wildmatch` is declined** (1.4.9). Both shapes cost 7–18% on `is_ignored` for a benign edge, since budget exhaustion shows a file rather than hiding it. Numbers at the call site in `src/index.cyr`.

---

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). Benchmark snapshots are in [`../benchmarks/`](../benchmarks/); security audit reports in [`../audit/`](../audit/). Audit ids (A5, B7, L12, R1, R2, R6, …) refer to those reports.*
