# sit Development Roadmap

**Forward-looking only.** What shipped is in [`CHANGELOG.md`](../../CHANGELOG.md); the live snapshot (version, dependency pins, source layout, commands, consumers) is in [`state.md`](state.md). This file holds what is next and nothing else.

> **How this file is organized: arcs.**
> - An arc is one minor (`1.N.0`, the new surface), the patches that follow it, and the closeout pass [CLAUDE.md](../../CLAUDE.md) requires before the next minor, which ships as the arc's last patch.
> - Arcs run in order. The patch numbers inside an arc are not promises: a fix or a toolchain bump that has to land first takes the next number, and the rest shift.
> - New work found along the way joins the open arc if it is a fix, or the arc whose theme it shares. What waits on a request sits under **On request**, after the arcs.
> - Upstream asks, holds and closed decisions follow.
>
> A slot is a plan, not a promise. When an item ships, **delete it** (the CHANGELOG is the record). When a slot slips, re-slot it. At every release, re-check the line and count pins the remaining items cite.

---

## SemVer tiers (post-1.0)

- **Patch (`1.x.y`):** no new *observable* surface. Bug fixes, perf, internal refactors, toolchain / dep bumps, consuming upstream fixes.
- **Minor (`1.x.0`):** new *backward-compatible* surface: a command, flag, config key, public-API symbol, or wire capability.
- **Major (`2.0.0`):** reserved for a breaking change to the CLI, `.sit/` layout, wire protocol, or public API. None planned.

Each item ships under the usual test / fuzz / poison / bench gates.

---

## 1.12.x — the closeout arc (before 1.13.0)

1.8.0 through 1.12.0 shipped five minors without the closeout pass CLAUDE.md requires before each minor bump; the last P(-1) was 1.7.6. Those minors added the most attack surface since 1.0:
- packs and `sit gc` (a new on-disk format, a store swap, the store lock),
- `sit serve --repos` (request paths that name directories),
- base-path URLs,
- `.git/` CLI parity (alternates that point outside the repository; trees read with the checkout rules off).

### 1.12.1 — `sit add` takes every path it is given

`sit add a.txt b.txt` stages `a.txt` and **silently ignores `b.txt`** (verified at 1.12.0): `cmd_add` reads one path, `argv(2)` (or `argv(3)` after `-f`). A user who lists several files believes they are staged. Stage each path in order, through the same validation one path gets today, and refuse the whole command (staging nothing) if any path fails, so a typo in the third path does not leave the first two half-done. `-f` keeps its meaning for every path. Integration: several paths, one bad among them, `-f` with several.

### 1.12.2 — closeout P(-1) over 1.8.0–1.12.x

The P(-1) pass (CLAUDE.md § P(-1), § Closeout), its findings in `docs/audit/YYYY-MM-DD-audit.md`:
- **Security review of the new surfaces.**
  - The pack writer and reader under hostile input: a crafted pack in `.sit/packs/` or a file:// remote's.
  - gc's crash points: kill it at each step and check that every object is still readable.
  - The store lock's protocol and its agnos degradation.
  - `--repos` name resolution, including races between `lstat` and open.
  - Base-path URL parsing.
  - Alternates that point anywhere, and git trees read with the relaxed name rules.
- **Dead code and refactor pass.** The 1.10–1.12 additions (gc's helpers, the store contexts, the git-mode branches in diff / status) are where parallel paths accreted.
- **Benchmarks.** Re-take the 1.11.0 command A/B on a quiet host; its table was taken at load ~25 and carries no conclusion. Save the CSV as the new baseline.
- **Downstream.** owl and thoth against the read bundle, which changed in 1.10.0 (packs), 1.11.0 (store sessions, R6) and 1.12.0 (mode-aware status).
- **`sit serve --repos` evictions.** A repository evicted from the 64 keeps its pack mappings for the process (ADR 0017). Decide whether eviction unmaps them (`_git_file_forget_*` by root), or document the bound.

---

## 1.13.x — everyday revisions and paths

Gaps every git user hits on day one, all verified at 1.12.0. The commands exist; the syntax around them does not.

### 1.13.0 — revision syntax, path-limited log, adding directories

- **`<rev>~<n>`, `<rev>^<n>` and `<rev>:<path>`.** None resolve today: `sit log HEAD~1` says "cannot resolve", and `sit cat-file HEAD:a.txt` says "no object matches". Parse them once in the resolver every command uses (`resolve_commit_hash` / `resolve_hash`), on both backends (a `.git/` repository reads the same syntax). `~` follows first parents and `^<n>` the n-th parent. `:` resolves a path in the commit's tree to the blob or tree id. Fuzz the parser; differential against `git rev-parse` in both object formats.
- **`sit log [<rev>] [--] <path>…`.** Today a path is read as a ref ("cannot resolve 'a.txt'"). Show the commits whose tree changes a given path, against their first parent (git's default, without rename following). It shares the tree walk `blame` already does.
- **`sit add <dir>` and `sit add .`.** A directory fails with "cannot stat file". Walk it with `list_working_walk` (so `.sitignore` applies, and `-f` overrides it), then stage each file as 1.12.1 stages a list.

### 1.13.1 — the remaining read commands on `.git/`

`sit blame`, `sit describe` and `sit merge-base` are read-only but still refuse a `.git/` repository (rc 1, verified at 1.12.0). Open them through `cli_read_repo` as 1.12.0 opened status / log / diff. They need the 1.12.0 width fixes (`_id_dup`) on their own paths, plus a differential against `git blame --porcelain`, `git describe` and `git merge-base` in both object formats.

### 1.13.2 — closeout P(-1) over 1.13.x

---

## 1.14.x — git interoperability

Where sit's output or input meets git's.

### 1.14.0 — patches git applies, and git's index in read mode

- **Diffs that round-trip through `git apply`.** sit's `diff` / `show` print `--- a/x` / `+++ b/x` and hunks, but no `diff --git` line, no `new file mode` / `deleted file mode`, and no `/dev/null`. So `git apply` takes a deletion as an edit to an empty file and **leaves an empty `b.txt` instead of removing it** (verified at 1.12.0). Creations go through by luck. In a `.git/` repository the exec bit and symlinks change too, so emit `old mode` / `new mode`. Gate on `git apply --check` plus apply-and-compare for every shape: create, delete, edit, mode change, no trailing newline (the 1.7.2 case).
- **git's index in read mode.** Since 1.12.0 `sit status` and `sit diff` on a `.git/` repository compare HEAD against the working tree, because sit does not read `.git/index` (DIRC v2–v4, with its extensions). A change staged with `git add` therefore shows as a change, and `diff --staged` is refused. A first-party, fuzzed DIRC reader gives git repositories sit's staged / unstaged split, and lifts the `--staged` refusal. Read-only, so no write-back.

### 1.14.1 — the real `Host:` header

The http client sends a literal `Host: 127.0.0.1` on every request. `sit serve` ignores it, but a reverse proxy in front of `sit serve --repos` that routes by name sees the wrong one (ADR 0017), so it needs a default server or a rewrite. Send the URL's host, and the port when it is not the default. The https path knows the name already (SNI and the TOFU pin).

### 1.14.2 — closeout P(-1) over 1.14.x

---

## 1.15.x — transfer and storage cost

### 1.15.0 — packs on the wire, as a negotiated capability

Since 1.10.0 a packed object leaves the store expanded and compressed (level 1), so the wire format is unchanged. But a clone of the packed 1,600-commit fixture takes 6.96 s against 5.79 s for the same history unpacked, and the receiver stores everything loose until its own `sit gc`. Shipping the pack, or a thin pack of what the receiver lacks, needs:
- a capability both ends advertise;
- a receiver-side pass that reconstructs and verifies every object against its id before anything lands: `_object_verify`'s rule applied after delta resolution (CLAUDE.md);
- the received pack installed as gc installs one: named by its trailer, under the store lock.

### 1.15.1 — gc's remaining costs

Measured on the 1,600-commit fixture: the first gc takes 5.3 s, 2.8 s of it reading 63 MB of rows out of patra, and a repeat takes 2.6 s (git: 0.6 s). Commits are not deltified and are 251 KB of the 683 KB pack. Candidates:
- delta commits against their first parent;
- pack incrementally (new objects into a second pack) instead of `repack -a -d` every time.

Measure on a larger, more varied history first.

### 1.15.2 — consume the upstream fixes

When cyrius folds sankoch 2.9.1 (the DEFLATE match-finder, `add-1MB`'s floor), sankoch 2.9.11 (`br_init`'s 32 B per inflate) and sandhi's `content_length` fix (see *Upstream asks*), bump the pin. Wipe `lib/` first, then measure `add-1MB` and the serve heap probes against the previous pin. Tighten the allowance sections 29 and 30 make for sankoch's 32 B per inflate (a git-mode read, a ref push), and give a body-carrying request its own heap probe once sandhi's fix is in. If the folds land earlier, this takes the next patch on whichever arc is open.

### 1.15.3 — closeout P(-1) over 1.15.x

---

## 1.16.x — scale

### 1.16.0 — index paths over 255 bytes

This is a migration of `index.patra` (B7 rest), so it is a minor. `sit add` and `sit mv` refuse such paths, and `rewrite_index` is transactional. It was planned to ride along with 1.10.0's object-store schema change, which did not happen (packs, ADR 0016), so it needs its own migration. patra's STR column is a fixed 256-byte slot and its chain columns (TEXT / BYTES) cannot be indexed, so the `path` index needs a fixed-width key for long paths (a hash of the path) beside the path itself.

### 1.16.1 — a commit-parent cache (commit-graph)

Every history walk reads each commit object afresh, about 75 µs apiece. That makes whole-ancestry walks cost about 150 ms per 2,000 commits: `find_merge_base` on every merge, `rebase`'s pending set, `describe` when a merge lies between the commit and its nearest tag, and since 1.13.0 `log <path>`. git keeps a commit-graph file for the same reason. A parent table in `objects.patra`, filled on write and backfilled once (gc is the natural place), would cut the walks to table reads. Measure `merge-base` / `describe` / `rebase` / `log <path>` on a 100k-commit fixture first.

### 1.16.2 — an arena per public-API call (R1, rest)

`sit_repo_status` frees every blob and file it compares. What it still keeps, ~94 KB per call on 200 files, is the flattened HEAD tree, the worktree listing and the result records, all on the bump heap. Running each call on an arena rewound at entry, as `sit serve` does per request, would close it. But the returned vec is the caller's, so the records must be copied out or the contract changed (ADR 0009). Measure with `tests/integration/api_heap_probe.cyr`.

### 1.16.3 — closeout P(-1) over 1.16.x

---

## On request

Wanted, but each waits for a consumer or a decision before it takes an arc.

- **`sit fsck` on a `.git/` repository.** It refuses one (verified at 1.12.0). Checking integrity there means hashing SHA-1, which [ADR 0011](../adr/0011-git-read-mode.md) deferred: sigil has no general-purpose SHA-1. A decision first (a first-party SHA-1 for verification only), then the command.
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

---

## Upstream asks (not sit work)

Blocked on another repo. Per [CLAUDE.md](../../CLAUDE.md), each belongs on the **target repo's** roadmap; each entry says whether it is there.

- **sankoch — DEFLATE match-finder throughput.** Targets the `add-1MB` `zlib_compress` floor (~100 ms, about 6× git and the largest single cost in `sit add`). **On sankoch's roadmap** as its 2.9.1 item; it reaches sit with the cyrius release that folds that sankoch.
- **sankoch — every inflate keeps 32 B: `br_init`'s bit reader.** `br_init` (`src/bitreader.cyr` in sankoch) takes its 32-byte reader from `_sankoch_alloc` on every `_deflate_decompress_inner` / `_deflate_decompress_dict_inner` call and never frees it, so `zlib_decompress` and `zlib_decompress_with_ratio_cap` keep 32 B per call (an `fl_alloc` / `fl_free` round trip keeps 0). It is all `sit serve` and git read mode still keep: a ref push over 2,000 commits keeps 63,968 B, and a git-mode read 32 B per loose object, about 1 KB per packed object at chain depth 33. A stack reader in the two decoders, which own its lifetime, closes both. **Filed on sankoch's roadmap as 2.9.11** (2026-10-20, checked at 2.8.7); it reaches sit with the cyrius release that folds it.
- **sandhi — an allocator-taking `sandhi_server_content_length`.** It reads the header through `sandhi_server_find_header`, so the value lands on the global heap on every call. `_sandhi_server_recv_request_dl` and `_sandhi_server_tls_recv_request` call it on every request with a body, so a long-running server keeps about 8 B per such request. `sit serve` parses `Content-Length` itself over its request arena (`_serve_content_length`, differential-fuzzed against sandhi's), but cannot reach the accept loop's call. An `_a` form, or an in-place scan that allocates nothing, closes both. **Filed on sandhi's roadmap in its open 1.13.x line** (2026-10-20, checked at 1.13.1); it reaches sit with the cyrius release that folds it.
- **patra — `page_write`'s return is ignored inside statements (L12).** `tbl_insert`, `tbl_delete`, `btree_insert` and `_bt_push_up` discard it, so in autocommit a page that never reached the disk is reported as `PATRA_OK` (reproduced with `RLIMIT_FSIZE` standing in for EIO / ENOSPC: `sit add` printed "added" and staged nothing). Inside a transaction the failure is reported, which is why sit writes the index only in transactions. **On patra's own roadmap** (its "Open — patra's own" list, found there at 1.16.2).

## On hold — keep sandhi

Dropping sandhi for a hand-rolled `net`-direct loopback HTTP/1.0 server (surface minimization) is deliberately *not* scheduled. A future cyrius change is expected to make stdlib / lib consumption easier, which changes both the trade-off and the likely implementation. Until then, sit keeps consuming sandhi's `sandhi_server_*` surface.

## Decided — do not re-attempt

Closed by measurement. The reasoning lives where cited; they are listed here only so they are not re-opened blindly.

- **`clone` has no algorithmic defect left** (1.4.9). Its cost is a fixture whose content is quadratic in commit count, which git's deltas collapse; 1.10.0's packs do that for storage (ADR 0016), and packs on the wire (the 1.15.x arc, above) would do it for transfer. Phase profile in the 1.4.9 CHANGELOG entry.
- **Memoizing `_wildmatch` is declined** (1.4.9). Both shapes cost 7–18% on `is_ignored` for a benign edge, since budget exhaustion shows a file rather than hiding it. Numbers at the call site in `src/index.cyr`.

---

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). Benchmark snapshots are in [`../benchmarks/`](../benchmarks/); security audit reports in [`../audit/`](../audit/). Audit ids (A5, B7, L12, R1, R2, R6, …) refer to those reports.*
