# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.1.0] — 2026-06-25 — Reflog + recovery

The first post-1.0 minor: a git-compatible reflog, `@{N}` recovery resolution, the `sit reflog` command, and a reflog-aware `fsck --prune` grace period. Foundational — the recovery net that de-risks the history-rewrite tools (revert / cherry-pick / stash / rebase) queued on the roadmap. Design + invariants: [ADR 0010](docs/adr/0010-reflog-and-recovery.md), [architecture note 005](docs/architecture/005-reflog-two-line-invariant.md).

### Added

- **Reflog (`.sit/logs/`).** Every ref movement appends a git-format line — `<old64> <new64> <name> <email> <unixts> +0000\t<message>` — to a per-ref log mirroring the ref tree (`logs/HEAD`, `logs/refs/heads/<b>`, `logs/refs/remotes/<r>/<b>`). Creation uses a 64-zero old-oid; append-only, newest last. A HEAD-on-branch move logs **twice** (the branch log and `logs/HEAD`); tags are not logged (git parity). Recorded across `commit`, `reset --hard`, `merge` (fast-forward + merge commit), `checkout`, branch / `-b` create, `clone`, `pull`, and `fetch` (remote-tracking). New module `src/reflog.cyr` (in `[lib].modules`, ordered before `object_db.cyr`).
- **`<ref>@{N}` / `HEAD@{N}` resolution.** The ordinal selector resolves anywhere a revision is accepted (via `resolve_ref_name`), so `sit reset --hard HEAD@{1}` undoes the last reset and `sit log HEAD@{2}` inspects an earlier tip. Integer ordinal form only — the `@{<date>}` time form is rejected in 1.1.0.
- **`sit reflog [-n <count>] [<ref>]`.** Prints a ref's movement history newest-first (`<short-oid> <ref>@{N}: <message>`), defaulting to HEAD. Brings the command inventory to **27**.
- **`fsck --prune` grace period + `--prune-now`.** Reflog entry oids become reachability roots, so a reset-discarded tip is protected while its reflog entry exists; plus a **90-day** age window (git's `gc.reflogExpire` default) on still-dangling objects — commits dated by author timestamp, undatable trees/blobs kept. `--prune-now` forces the legacy immediate sweep (grace 0).

### Changed

- **`fsck --prune` is no longer immediate/unrecoverable.** It now honours reflog reachability plus the 90-day grace window instead of `git gc --prune=now` semantics. **Migration**: for the old immediate behaviour, use `sit fsck --prune-now`.

### Security

A pre-release multi-agent adversarial review hardened the new reflog surface before ship (11 findings confirmed, all addressed):

- **Identity sanitization** — `name`/`email` in a reflog line are now scrubbed of control bytes (LF/TAB/…) exactly like the message, so an LF in `SIT_AUTHOR_NAME` or a hand-edited config can no longer forge a second, attacker-shaped reflog entry whose new-oid `@{N}` would resolve.
- **Ref-label validation** — `sit reflog <label>` and `<base>@{N}` run the label through `refname_valid` (rejecting `..`, leading `/`, control chars, `@{`), closing a path-traversal arbitrary-file read out of `.sit/logs/`.
- **Output sanitization** — `sit reflog` scrubs the echoed short-oid and message (terminal-escape injection from a crafted/corrupt log; the S-21 class).
- **`branch -d` deletes the branch's reflog** — no orphaned log left to pin the branch's objects against `--prune` forever or corrupt a recreated branch's `@{N}`.
- **Corrupt-roots prune tripwire** — `--prune` decides "no roots" from the refs/HEAD set alone, so a stale `.sit/logs/` can't mask a wiped HEAD/refs and let prune delete a ref-only-reachable branch.

### Notes

- Build / **273 unit** / **40 integration** / fuzz (7 harnesses incl. `reflog_index` at 200k rounds, no crashes) / lint green. A new CI smoke step exercises reflog + `@{N}` recovery + the prune grace window end-to-end. DCE binary **2.375 MB** (+~126 KB vs 1.0.4 — the reflog module plus fsck/refs/wire wiring), static (`ldd` → not a dynamic executable). No toolchain/dep change.
- **Deferred** (per ADR 0010): `reflog expire` / `delete` — reflog entries are currently unbounded, so reflog-protected objects persist until the log is cleared (`--prune` reclaims them only via `--prune-now` or after a manual log clear); and the `@{<date>}` selector. The same unsanitized-identity pattern exists in `commit.cyr` / `merge.cyr` object framing and is flagged for a follow-up hardening pass.

## [1.0.4] — 2026-06-25 — Ed25519 server certs + 1.0.x hygiene

First post-1.0.3 patch. No new observable surface — consumes a now-fixed upstream gap and clears accumulated drift / stale references. Headlined by Ed25519 `sit serve --tls` support, which the 1.0.3 dep bumps unblocked.

### Added

- **Ed25519 server certificates for `sit serve --tls`.** The parked `tls_native` gap (issue 2026-06-10) is fixed upstream: the root cause was sigil's X.509 parser being ECDSA/RSA-only — the server's `load_creds` rejected the Ed25519 cert (`x509_parse → CERT_INVALID`) before the handshake. Fixed in sigil 3.9.x, folded into cyrius 6.x. sit needed **no code change** (`sit serve --tls` and the https client are cert-algorithm-agnostic). Verified end-to-end: Ed25519 **and** ECDSA P-256 https clones both complete, TOFU-pin, and fsck clean. The https CI smoke now exercises both algorithms; getting-started drops the "ECDSA P-256 only" caveat; the issue is archived.
- **CI guard: serve capabilities banner must equal VERSION.** The `/sit/v1/capabilities` `"sit"` field had silently drifted to `0.8.10` through v1.0.3 (no automated check). The version-consistency step now asserts the banner literal == VERSION (with a clear message if the literal can't be located), so it can't drift again.

### Fixed

- **serve capabilities banner** corrected from `0.8.10` to track VERSION (now `1.0.4`).
- **clone default-target host scan** (`cmd_clone`, http(s) without `<dir>`): replaced a `break`-after-in-loop-`var` (a CLAUDE.md-flagged unreliable pattern) plus two dead `host_end = host_end` no-ops with a flag-driven loop. The derived dir is the bare host (port/path dropped) across all URL shapes.

### Notes

- Comment/doc accuracy sweep on touched files: `_wire_http_post` "dead code" note (now has live callers); stale version headers in `wire_http.cyr` / `wire_https.cyr` / `serve.cyr` (keep-alive v0.8.9, https v0.8.8, push v0.7.6, mTLS → 1.5.0); and `v0.7.3` dropped from two user-facing error strings.
- Still parked (verified not yet consumable against the current pins): patra `or_ignore` for **P-11** (landed only on the SQL path, can't serve the BYTES `content` column), sankoch `zlib_decompress_with_ratio_cap` + SIMD match-finder (not landed), sigil strict-fail `hex_decode` (predates the pin; nothing to consume).
- Build / **230 unit** / **40 integration** / fuzz / bench / lint green; Ed25519 + ECDSA P-256 https clones verified; `dist/sit.cyr` regenerated (`serve.cyr` + `wire_http.cyr` are `[lib].modules`). DCE binary **2.249 MB**, static (`ldd` → not a dynamic executable). No toolchain/dep change.

## [1.0.3] — 2026-06-25 — cyrius 6.2.44 toolchain refresh + dep bumps

Toolchain + dependency refresh (same shape as the v1.0.2 / v0.8.11 refreshes). No public-surface change — the full 1.0 git-parity surface stands and the CLI / `.sit/` layout / `/sit/v1/...` wire protocol / `sit_*`/`ann_*` public API remain SemVer-governed. One small required source change: the cyrius 6.2.44 stdlib retired `fl_free`'s second (size) argument, so 30 call sites were updated to the one-arg form (see below).

### Changed

- **Cyrius toolchain `6.2.25 → 6.2.44`** (pinned in `cyrius.cyml [package].cyrius`).
- **Dependencies** — sakshi `2.4.0 → 2.4.2` (minor-line), sigil `3.9.1 → 3.9.4` (minor-line within major 3 — **audit clean**, sit calls only `hash_data` / `hex_encode` / `hex_decode` / ed25519 verbs; keygen → signed-commit → `verify-commit` confirmed end-to-end), patra `1.12.0 → 1.12.4` (minor-line; no public-surface impact). **sankoch held at `2.4.4`** (already the latest tag).
- **`fl_free` arity (cyrius 6.2.44 stdlib)** — the freelist API dropped its second `size` parameter; `fl_free(ptr)` is now canonical (the allocator tracks block size internally). Updated **30 call sites** across `src/serve.cyr`, `src/wire_http.cyr`, and `src/wire_ssh.cyr` from `fl_free(ptr, cap)` to `fl_free(ptr)`. No behavior change (the size argument was already redundant); clears 30 `'fl_free' expects 1 argument, got 2` build warnings.

### Notes

- Build / test / lint / fuzz / bench green: **230/230 unit**, lint clean (only the pre-existing advisory long-line / TODO-deferral warnings), fuzz clean (6 harnesses — `zlib_decompress`, `hash_data`, `hex_decode`, `url_validators`, `ssh_url_parser`, `want_frame_decoder` 10M rounds, no crashes), bench flat. DCE binary **2.249 MB** (+~4 KB vs 1.0.2 — 6.2.44 stdlib/dep heft); `ldd` → *not a dynamic executable*.
- Remaining benign upstream build warnings, DCE-stripped: the `async_*` undefined-function refs (sandhi's async server variant, which sit's synchronous `cmd_serve` never reaches) and the large-static-data note — both originate in vendored stdlib / `lib/sandhi.cyr`, neither reachable from sit.
- `dist/sit.cyr` regenerated — `serve.cyr` and `wire_http.cyr` are `[lib].modules` source files, so the `fl_free` edits propagate into the bundle (verified no 2-arg `fl_free` remains). No public-API change.

## [1.0.2] — 2026-06-19 — cyrius 6.2.25 toolchain refresh + dep bumps

Toolchain + dependency refresh (same shape as the v0.8.11 / v0.8.6 refreshes). No `src/*.cyr` changes and no public-surface change — the full 1.0 git-parity surface stands and the CLI / `.sit/` layout / `/sit/v1/...` wire protocol / `sit_*`/`ann_*` public API remain SemVer-governed. One required manifest change: the `random` stdlib module is now declared (see below).

### Changed

- **Cyrius toolchain `6.2.2 → 6.2.25`** (pinned in `cyrius.cyml [package].cyrius`).
- **Dependencies** — sakshi `2.3.0 → 2.4.0` (minor-line), sankoch `2.3.1 → 2.4.4` (minor-line; the larger 2.x match-finder / SIMD work is still queued), sigil `3.7.13 → 3.9.1` (minor-line within major 3 — **audit clean**, sit calls only `hash_data` / `hex_encode` / `hex_decode` / ed25519 verbs; signed-commit verify confirmed end-to-end), patra `1.11.1 → 1.12.0` (minor-line; no public-surface impact).
- **`[deps].stdlib` gains `random`** — sigil 3.9.1 reworked ed25519 keypair generation to source entropy through the cyrius stdlib `random_bytes` (`lib/random.cyr`) rather than calling `getrandom` itself. Without `random` declared, that symbol is unresolved and `sit key generate` jumps to a bad address and crashes (**SIGILL**, exit 132) — caught by the signed-commit-round-trip CI smoke. Declaring `random` resolves it; the 43-line module adds `random_bytes` only and stays well under the 256-global cap.

### Fixed

- **`sit key generate` crash under sigil 3.9.1** (SIGILL / exit 132). The new sigil routes `ed25519_generate_keypair` entropy through stdlib `random_bytes`; sit's manifest didn't declare the `random` stdlib module, so the call resolved to nothing. Adding `random` to `[deps].stdlib` restores keygen; verified `key generate` → signed commit → `verify-commit` end-to-end (good signature).

### Notes

- Build / test / lint / fuzz green: **230/230 unit**, lint clean, fuzz clean (6 harnesses — `zlib_decompress`, `hash_data`, `hex_decode`, `url_validators`, `ssh_url_parser`, `want_frame_decoder` 10M rounds, no crashes). DCE binary **2.245 MB** (+~38 KB vs 1.0.1 — 6.2.25 stdlib/dep heft).
- Remaining benign upstream build warnings, DCE-stripped: the four `async_*` undefined-function refs (sandhi's async server variant, which sit's synchronous `cmd_serve` never reaches) and a `duplicate symbol 'SANDHI_CONN_OFF_FD'` (last-definition-wins) — both originate in the vendored `lib/sandhi.cyr`, neither reachable from sit. (The `random_bytes` undefined warning is gone now that `random` is declared.)
- `dist/sit.cyr` regenerated — version-stamp bump only (no `[lib].modules` source file changed). No public-API change.

## [1.0.1] — 2026-06-13 — diff: large-file Myers fallback + minimality fix

First 1.0.x patch. No new surface (per the SemVer commitment) — a diff correctness fix, a large-file capability, and a test. The headline started as the Myers fallback and ended up uncovering a latent bug in the existing DP.

### Fixed

- **`lcs_diff` produced non-minimal diffs on the 2nd+ diff in a process** (`src/diff.cyr`). The LCS dynamic-programming table relied on its base row/column being zero, but never zeroed them — true only for fresh mmap-backed pages (large tables). A small table served from the recycled `fl_alloc` freelist carried stale non-zero values, so the DP computed a too-short LCS and emitted a non-minimal diff (e.g. `delete c` + `insert c` instead of `keep c`). A single `sit diff` in a fresh process was usually fine; `sit show` of a multi-file commit, or any command diffing several files, could hit it. Now the base row/column are explicitly zeroed. Surfaced by the new Myers differential test.

### Added

- **Myers O((N+M)D) diff fallback (P-14)** (`src/diff.cyr`). Files past the LCS DP cap (>8192 lines/dim) previously refused with `diff table exceeds cap; file too large`; they now diff via a bounded greedy Myers algorithm (forward search + trace backtrack) that needs only O(N+M) working space. A large-but-similar file (small edit distance) diffs cheaply where the DP would allocate 100+ MB. Output is a valid minimal edit script in the same op-tuple format, so `cmd_diff` / `cmd_show` / `sit_diff_path` are unchanged. Bounded at edit distance 4096 (~67 MB trace ceiling); a pathologically-rewritten huge file still refuses, preserving the old behavior for that case.
- **Tests** — a `tests/sit.tcyr` differential group (**10 cases**, +50 assertions → **230**) checks `myers_diff` against the DP on minimality (equal edit distance) and reconstruction (the script rebuilds the new file); an integration gate (`tests/integration/run.sh`, **40 assertions**) diffs a 9000-line file through the fallback. Plus the **ADR-0003 no-upward-discovery** regression test (a subdir of a repo refuses `status` / `log` / `commit` with `not a sit repository`).

### Notes

- Build / test / lint / fuzz / bench green; 230 unit / 40 integration; bench flat (the base-zeroing is O(N+M) on an O(N·M) path). DCE binary 2.20 MB. `dist/sit.cyr` regenerated (`diff.cyr` is `[lib].modules`). No public-API, toolchain, or dep change. Surface-minimization (dropping sandhi) stays on hold pending an easier cyrius `stdlib`/`lib` consumption path.

## [1.0.0] — 2026-06-13 — Sovereign version control, 1.0

The first stable release. A ceremonial cut on a green [v0.9.0](#090--2026-06-13--v100-closeout--stabilization) — **no code changes from 0.9.0**, only the version stamp. sit owns the "track a codebase over time" job on AGNOS end-to-end, with every layer first-party Cyrius — no libgit2, no C, no FFI ([ADR 0001](docs/adr/0001-no-ffi-first-party-only.md)).

### What 1.0 is

- **Local VCS loop** — `init` / `add` / `rm` / `commit` / `branch` / `checkout` / `tag` / `merge` (3-way, diff3 conflict markers) / `merge-base` (full-DAG LCA) / `reset` / `log` (`--oneline`, `--graph`) / `status` / `diff` / `show` / `cat-file` / `owl-file` / `config`. **26 commands.**
- **Integrity & trust** — `fsck` (integrity + reachability + `--prune`); ed25519-signed commits + `verify-commit` (sitsig, [ADR 0002](docs/adr/0002-sitsig-not-gpgsig.md)); SHA-256 only, git-byte-compatible object framing ([ADR 0004](docs/adr/0004-sha256-only.md)).
- **Git-parity `.sitignore`** — `*` / `?` / `[...]` char classes / `**` / `!` negation / anchoring.
- **Network sync** — clone / fetch / push over `file://` / `http://` / `https://` (first-party TLS 1.3, TOFU-pinned, **no libssl**, [ADR 0007](docs/adr/0007-network-transport-security.md)) / `ssh://` (system `ssh` as a process boundary, [ADR 0008](docs/adr/0008-ssh-transport.md)); shallow clone (`--depth N`); `sit serve` host side.
- **Library export** — consumable as a Cyrius dep via `dist/sit.cyr`; the `sit_*` / `ann_*` public surface is **stable and SemVer-governed** from 1.0 on ([ADR 0009](docs/adr/0009-public-api-contract.md)).

### Stability

From 1.0.0, the CLI surface, on-disk `.sit/` layout, wire protocol (`/sit/v1/...`), and the `dist/sit.cyr` public API follow SemVer — breaking changes require a major bump with a migration note. Single statically-linked binary, **no dynamic dependencies** (`ldd` reports *not a dynamic executable*).

### Verification

Unchanged from v0.9.0: 180 unit + 33 integration assertions, fuzz clean (6 harnesses), bench flat vs the v0.8.12 baseline, lint clean, clean-from-scratch DCE build **2.204 MB**. `dist/sit.cyr` regenerated (version stamp only). Cyrius 6.2.2; sakshi 2.3.0 / sankoch 2.3.1 / sigil 3.7.13 / patra 1.11.1.

## [0.9.0] — 2026-06-13 — v1.0.0 closeout / stabilization

The stabilization pass before the v1.0.0 cut: an independent adversarial review of the v0.8.x additions (`log --graph`, `--depth` shallow clone, `merge_base`, `fsck --prune`), a whole-tree dead-code / lint / security re-scan, and one consolidation refactor. Three HIGH findings fixed; no new features. Full report: [`docs/audit/2026-06-13-audit.md`](docs/audit/2026-06-13-audit.md).

### Security

- **`sit log --graph` out-of-bounds write (memory safety)** — `_graph_join_connector` (`src/commit.cyr`) wrote the collapse seam at `buf + 2*rcol - 1`, which underflows to `buf-1` when the collapsing lane is column 0. Reachable whenever a merge's second parent (feature lane) is *strictly* newer than its first (main lane) — a common real-history shape. Guarded `if (rcol > 0)`; the same `2*x-1` seam in `_graph_merge_connector` is guarded defensively (analysis shows it can't underflow, but the invariant is now explicit). Regression test added.
- **`sit fsck --prune` data loss behind a corrupt object** — the reachability walk silently skips unreadable objects, so a single corrupt interior commit/tree orphaned its whole subgraph into the `dangling` set, and `--prune` (running before the `bad > 0` check) would permanently delete those genuinely-reachable objects. Now refuses to prune when any object is bad/unreadable, and when *every* object is unreachable (the signature of a corrupt/missing HEAD that would otherwise wipe the store).

### Fixed

- **`find_merge_base` on a cyclic/corrupt store** (`src/merge.cyr`) — falls back to a real candidate instead of reporting "no common ancestor" if a parent cycle makes `is_ancestor` mark every candidate redundant (only reachable on a corrupt store; defense-in-depth).

### Changed

- **Refactor** — extracted `commit_parents_of(hex)` (`src/commit.cyr`), consolidating the `read_object → parse_commit_body → iterate out+48 parents` boilerplate shared by `is_ancestor` and both BFS loops in `find_merge_base` (~30 lines removed). The walkers that also need the tree/timestamp/body (`walk_reachable_phased`, `print_graph`, `cmd_fsck`) keep their inline reads.
- **Dead code** — removed the unused `_ssh_handle_batch_known` / `_ssh_handle_carry` getters (reserved SSH-handle slots with no readers; zero-init setters retained). Remaining unreachable-from-binary floor is the intentional set: the `sit_*` public API (live in `dist/sit.cyr`) and the `build_commit` / `build_merge_commit` wrappers.

### Notes

- No feature changes, no public-API changes (`src/api.cyr` + the `ann_*` accessors are byte-identical, so the owl downstream needs no adaptation). No toolchain or dep change.
- **Verification**: 180 unit + **33 integration** assertions (the v0.8.x gates + the new lane-0-join graph regression), fuzz clean (6 harnesses), bench flat vs the v0.8.12 baseline ([snapshot](docs/benchmarks/2026-06-13-v0.9.0.md)), lint clean, clean-from-scratch DCE build. DCE binary **2.204 MB** (−336 B vs v0.8.14). `dist/sit.cyr` regenerated. **Next: the v1.0.0 cut.**

## [0.8.14] — 2026-06-13 — `sit fsck --prune`

Completes the v0.8.5 fsck reachability work by letting it remove what it finds. Deferred from v0.8.5 pending a safety story.

### Added

- **`sit fsck --prune`** (`src/object_db.cyr`) — removes the dangling (unreachable) objects the v0.8.5 reachability walk already identifies. The walk's roots are unchanged (refs/heads, tags, remotes, detached HEAD, and every staged index blob), so only objects referenced by no ref and no staged entry are deleted. New `db_object_delete(db, hex)` helper (`DELETE FROM objects WHERE hash = '<hex>'`, hex validated 64-char before interpolation). After deleting, `patra_flush` makes the removal durable across process exit (the `main` trailer flushes only stdout). Reports `pruned <n> objects` after the usual `checked … dangling` line.
- **Safety guard** — `--prune` is **refused while a merge is in progress** (`.sit/MERGE_HEAD` present), so a half-finished operation's objects can't be dropped out from under it.

### Notes

- **No grace period / no reflog**: `--prune` is immediate and unrecoverable — sit has no reflog yet, so this matches `git gc --prune=now`, not git's default 2-week grace. Without `--prune`, `fsck` behavior is unchanged (it reports dangling but deletes nothing; dangling never sets a non-zero exit — only integrity errors do). A reflog (which would enable a real grace period) is a separate future feature.
- **Verification**: integration gate in `tests/integration/run.sh` — two commits, `reset --hard` to the first → the second's commit/tree/blob go dangling; `--prune` reports 3 removed; a **fresh fsck process** sees `0 dangling` with the first commit's 3 objects intact and the working tree preserved; `--prune` refused under `MERGE_HEAD`. **30 integration assertions** (was 22).
- Build / test / lint / fuzz / bench green; 180 unit / 30 integration; fuzz clean; bench flat vs the v0.8.12 baseline. `dist/sit.cyr` regenerated (`object_db.cyr` is `[lib].modules`). DCE binary **2.20 MB** (flat). No toolchain or dep change.

## [0.8.13] — 2026-06-13 — `merge_base` full-DAG LCA + `sit merge-base`

Corrects the merge base across merges and exposes it as a plumbing command. Closes the last of the v0.8.7-era single-parent-walk footguns.

### Fixed

- **`find_merge_base` walks the full DAG** (`src/merge.cyr`) — it previously followed only the single first-parent chain (`out+8`) on *both* sides, so for any history containing a merge it returned a too-high common ancestor. Concretely, in a diamond where one tip reaches the true base only through a merge commit's second parent, it fell back to the repository root. The rewrite computes a real lowest common ancestor over the `out+48` parent graph: (1) full-DAG ancestor set of *a*; (2) prune-BFS from *b* for the frontier of common ancestors; (3) reduce redundant candidates (a candidate that is an ancestor of another is dropped, via the v0.8.7 full-DAG `is_ancestor`), returning the newest maximal base. Verified on a diamond fixture: the new base is the true LCA `B`; the old code returned root `R`. Self (`merge-base X X = X`) and ancestor (`merge-base anc desc = anc`) identities hold. This makes `sit merge`'s 3-way base correct across merge-bearing history.

### Added

- **`sit merge-base <a> <b>`** — git-parity plumbing that prints the lowest common ancestor of two commits (resolved via branch / tag / hex-prefix). Exposes the LCA so it's testable independently of a full merge. **26 commands total.**
- **Diamond integration gate** — `tests/integration/run.sh` gains a diamond fixture (first-parent LCA = root, true LCA = the feature base) asserting `merge-base` returns the true base, plus the self identity. **22 integration assertions** (was 19).

### Notes

- **Documented simplification**: criss-cross histories can have several equally-valid merge bases; sit returns one (newest by author timestamp) where git would do a recursive merge. Octopus (3+ parent) bases are handled correctly by the walk but aren't creatable via sit's 2-way `merge` yet.
- Build / test / lint / fuzz / bench green; 180 unit / 22 integration; fuzz clean; bench flat vs the v0.8.12 baseline (no perf-touching change). `dist/sit.cyr` regenerated (`merge.cyr` is `[lib].modules`). DCE binary **2.20 MB** (flat). No toolchain or dep change.

## [0.8.12] — 2026-06-13 — `log --graph` + `--depth N` shallow clone + bench/test infrastructure

Two git-parity features plus the long-deferred bench-fixture refresh and an in-tree integration suite. The two features share the full-DAG commit walk that `parse_commit_body`'s out+48 parents vec (v0.8.7) unlocked.

### Added

- **`sit log --graph`** (`src/commit.cyr`) — an ASCII commit-DAG renderer. Unlike the default log (which follows only the first-parent chain via out+8), `--graph` walks the **full DAG** so merge topology is visible. Layout uses a position grid (lane *k* at column 2*k*, seams at odd columns): a commit row shows `*` at its lane and `|` elsewhere; a merge is followed by a `|\` connector; a commit whose parent rejoins an existing lane is followed by a `|/` connector. Linear history degrades to a clean column of `*`. Emission is reverse-topological (a commit before its parents), newest-first by author timestamp, leftmost-lane tiebreak (deterministic even when timestamps tie). New helpers: `_graph_build_node`, `_graph_lane_find`, `_graph_commit_row`, `_graph_merge_connector`, `_graph_join_connector`, `_graph_write_subject`, `print_graph`.
- **`sit clone --depth <n>`** (`src/wire.cyr`) — shallow clone. `walk_reachable_phased` gains a per-commit depth cap (`_wire_clone_depth`, a module global so the four walk call sites stay unchanged); the phase-1 commit walk stops *n* commits back from the tip but still pulls each kept commit's complete tree + blobs. A `--depth 1` clone of a 10-commit repo pulls exactly 3 objects (1 commit + tree + blob); `--depth 3` pulls 9. Depth is exact for linear history; for merges the boundary is approximate (first-pop-wins via `seen`), matching git's own shallow fuzziness.
- **`.sit/shallow` boundary marker** — a shallow clone writes the boundary commit hexes (present commits whose parents were not fetched), one per line, mirroring git's `.git/shallow`. `sit log` reads it and stops cleanly at the boundary instead of erroring on the absent parent. `fsck` was already boundary-tolerant (its reachability walk skips unreadable objects), so a shallow clone stays fsck-clean.
- **Bench-fixture refresh** (`tests/sit.bcyr`) — the three targets scoped during the 0.6.0 audit but never landed: **LCS diff** (`compute_file_diff`) at 100×100 / 1000×1000 / 4000×4000; the **`.sitignore` matcher** (`is_ignored`) against 10 / 50 / 200 patterns; **blob hashing** (`hash_blob_of_content`) at 1 KB / 64 KB / 1 MB. Also fixed the stale `bench_copy_objects_per_row` (was calling the pre-v0.7.3 3-arg `copy_objects` — its number was noise; now uses `obj_src_for_db` + `raw_cache`). Baseline snapshot at [`docs/benchmarks/2026-06-13-v0.8.12.md`](docs/benchmarks/2026-06-13-v0.8.12.md). `cyrius bench` is a per-release gate again.
- **In-tree integration suite** (`tests/integration/run.sh`) — promotes the `docs/guides/getting-started.md` end-to-end scenarios into a versioned, locally-runnable test with explicit assertions (19 checks: core loop, branch+merge, `log --graph` hash-independent snapshot, full clone round-trip, `--depth 1`/`--depth 3` shallow gates, push dispatch). New CI step `Smoke — integration suite (v0.8.12)`.

### Changed

- `cmd_log` arg parser accepts `--graph`; usage strings for `log` and `clone` updated in `src/main.cyr`.

### Notes

- **Documented simplifications** (consistent with the v0.8.10 `.sitignore` approach): `--graph` spacing is sit-native, not byte-identical to git (git pads a merge commit row with extra lane spaces; sit uses a single space before the commit info). A commit that simultaneously opens a new lane and rejoins an existing one in one step renders best-effort. Shallow `--depth` is clone-only this release (fetch/pull leave the walk unlimited); `fetch --deepen` is a future slot.
- Build / test / lint / fuzz / bench green; **180** unit assertions, **19** integration assertions, fuzz clean across all six harnesses, no new lint warnings. `dist/sit.cyr` regenerated (commit.cyr + wire.cyr are `[lib].modules`). DCE binary **2.20 MB** (+~8 KB vs v0.8.11). No toolchain or dep change.

## [0.8.11] — 2026-06-13 — cyrius 6.2.2 toolchain refresh + dep bumps

A toolchain + dependency refresh release (same shape as v0.8.6). No sit source changes — pins only.

### Changed

- **Toolchain** — cyrius `6.1.30 → 6.2.2` (6.2.x line). No new stdlib surface consumed; the `[deps].stdlib` list is unchanged. The four `async_*` build warnings remain benign dead-code refs DCE strips (sit's `cmd_serve` uses the synchronous `sandhi_server_run`).
- **Dependencies** — all four git-tag pins bumped to current:
  - **sakshi** `2.2.10 → 2.3.0` (minor-line; tracing/error-handling — no public-surface impact for sit)
  - **sankoch** `2.3.0 → 2.3.1` (patch-line; LZ4/DEFLATE/zlib/gzip)
  - **sigil** `3.7.8 → 3.7.13` (patch-line within major 3; sit calls only `hash_data` / `hex_encode` / `hex_decode` / ed25519 verbs — audit clean, signed-commit verify confirmed e2e)
  - **patra** `1.11.0 → 1.11.1` (patch-line; B+ tree / WAL object store — no public-surface impact)

### Notes

- Build / test / lint / fuzz green; no new lint warnings. **180/180 tests** pass; fuzz clean across all six harnesses (incl. the 10M-round `want_frame_decoder`). DCE binary **2.19 MB** (up from 2.15 MB — 6.2.x stdlib + dep heft). `dist/sit.cyr` regenerated (version-stamp bump only; no module change).

## [0.8.10] — 2026-06-10 — Full `.sitignore` semantics (git-parity)

`.sitignore` matching gains negation, `**`, char classes, and anchoring — the gaps that separated sit's matcher from git's.

### Added

- **`_wildmatch`** (`src/index.cyr`) — a gitignore-style glob with `WM_PATHNAME` semantics replacing the old single-segment `glob_match`: `*` / `?` (a run / one char, neither crossing `/`), **char classes** `[abc]` / `[a-z]` / `[!…]` (with a leading `]` as a literal member), **`**`** (crosses `/`; `**/` collapses zero dirs so `**/foo` matches `foo` at any depth, `/**` trails), and **directory-exclusion** (a matched dir-prefix excludes its contents, so `foo/bar` matches `foo/bar/baz`).
- **`!pattern` negation** — `is_ignored` now evaluates patterns in order with **last-match-wins**, so `!keep.log` after `*.log` re-includes the file (git semantics).
- **Anchoring** — `load_sitignore` flags a pattern as anchored when it has a leading `/` or a middle `/`; anchored patterns match against the full path from the repo root, non-anchored (no `/`) patterns match at any level. `\!` / `\#` escape a literal first char.
- **Tests** — `tests/sit.tcyr` gains two groups (`_wildmatch` glob core + `is_ignored` negation/anchoring): globs, char classes, `**`, dir-exclusion, negation re-include, anchored-vs-nested, path patterns. **180 assertions** (was 146).
- **CI smoke** `Smoke — .sitignore semantics` — a fixture (`*.log` / `!keep.log` / `/root-only` / `**/build/*` / `[Tt]emp`) asserting `sit add` ignores / re-includes / anchors / char-class-matches correctly.

### Changed

- Pattern storage is now a struct vec (`[text, len, negated, anchored]`) instead of plain cstrings; `is_ignored` / `load_sitignore` callers (`cmd_add`, `cmd_status`) are unaffected (they pass `patterns` opaquely).
- Capabilities banner `0.8.9 → 0.8.10`.

### Notes

- **Simplifications** (documented in-code): `**` crosses `/` even when not a whole path segment (git only crosses for segment-bounded `**`; `a**b` is rare and the real cases `**/x` / `x/**` / `a/**/b` are exact). Trailing-`/` (`build/`) is still stripped, not enforced as directory-only (unchanged, and not in scope). A `!` can re-include a file under an excluded directory (git can't) — a minor, friendlier divergence.
- Build / test / lint / fuzz green; no new lint warnings. DCE binary **2.15 MB**. Toolchain pin unchanged at 6.1.30.

## [0.8.9] — 2026-06-10 — HTTPS followups: push, keep-alive, read-timeout, CI smoke

Followups to the v0.8.8 HTTPS transport. `https://` is now a full read **+ write** transport with persistent (one-handshake) connections.

### Added

- **https push** — `sit push origin main` works over `https://`. The push primitives (`http_remote_push_object` / `_ref` via `_wire_http_post_xhdr`) were already TLS-aware (v0.8.8); this lights up `wire_transport_check_writable` for https and routes `cmd_push`'s dispatch through `_url_is_http_family`. Validated e2e: clone https → commit → push https → origin advances, fsck-clean. Same request-size bound as http push (the ~64 KiB server request buffer).
- **HTTPS keep-alive** — the http handle now holds ONE persistent socket + `tls_native` ctx (`_wire_https_acquire` / `_wire_https_teardown`) reused across every request of a clone / fetch / push, so a clone does **one TLS handshake instead of one-per-object** (verified: a 15-object clone made exactly 1 handshake). New `_wire_https_exchange` reads each response by exact Content-Length (via sandhi's `body_offset` / `content_length` / `find_header` parsers) so the reused connection stays framed; `_wire_http_request` / `_wire_http_post` / `_wire_http_post_xhdr` delegate to it when `is_tls`. Server: `_serve_run_tls` loops requests per connection until the client closes (recv 0) or the 30s timeout fires; TLS responses now advertise `Connection: keep-alive`. Plain http keeps its proven per-request path (the sandhi server closes per response). Handle grows 64 → 80 bytes.
- **Socket read-timeout** — 30s `SO_RCVTIMEO` on the client TLS socket (`_wire_https_connect`) and the server's accepted connections (`_serve_run_tls`), so a stalled / hostile peer can't pin a clone or a serve worker indefinitely (slowloris bound; mirrors sandhi's plain-http path).
- **CI smoke** `Smoke — https transport` — `sit serve --tls` (ECDSA P-256 cert) + `clone https://` + content + fsck, plus TOFU **pin-recorded** and **tampered-pin-refused** assertions.
- **Filed** [`docs/development/issues/2026-06-10-tls-native-ed25519-server-cert-accept-fails.md`](docs/development/issues/2026-06-10-tls-native-ed25519-server-cert-accept-fails.md) — `tls_native_accept` fails with an Ed25519 server cert (ECDSA P-256 works); upstream cyrius gap, workaround documented.

### Changed

- `wire_transport_check_writable` accepts `https://`; `cmd_push` dispatch uses `_url_is_http_family`.
- **Toolchain pin `6.1.29 → 6.1.30`** — the validated cycc (same chase-the-drift reasoning as v0.8.8: keeps CI building the tested toolchain; the followups add no new `tls_native` surface beyond v0.8.8's).
- Capabilities banner `0.8.8 → 0.8.9`.

### Notes

- Build / test / lint / fuzz green; **146 assertions**; DCE binary **2.14 MB** (flat). No new lint warnings. Plain http clone re-verified (no regression). https clone + push both validated over keep-alive (1 handshake/clone).

## [0.8.8] — 2026-06-10 — HTTPS transport (clone/fetch over `https://`, first-party TLS 1.3, TOFU-pinned)

**Closes the HTTPS slot that was blocked on first-party Cyrius TLS for the whole v0.8.x line.** cyrius 6.x shipped `lib/tls_native.cyr` — a sovereign pure-Cyrius TLS 1.3 stack on sigil primitives (no fdlopen, no libssl), satisfying [ADR 0007](docs/adr/0007-network-transport-security.md)'s gate. `sit clone https://...` and `sit fetch` now work end-to-end against `sit serve --tls`, both ends first-party Cyrius. Read-only this release; https push is queued for 0.8.9.

**Trust model: TOFU / pinned** (ADR 0008 SSH host-key parity). sit pins the peer's SubjectPublicKeyInfo SHA-256 (survives cert renewal) in `~/.sit/known_certs`; the first connection records, a later mismatch refuses (MITM signal). CA-chain + hostname verification is a post-v1 opt-in.

### Added

- **`src/wire_https.cyr`** (new, 244 lines) — TOFU pin store (`known_certs_path`, `_tofu_find_pin`, `_tofu_record_pin`, `tofu_check_pin`) + TLS transport helpers: `_wire_https_connect` (handshake → `set_verify(NONE)` → SPKI pin), `_wire_io_send` / `_wire_io_recv` (TLS-or-plain I/O with 16 KB record fragmentation + post-handshake-record skipping), `_url_is_http_family`.
- **Client** (`src/wire_http.cyr`, `src/wire.cyr`): the http handle carries `is_tls` + hostname; `wire_http_open` accepts `https://` (default port 443); `_wire_http_request` + both POST variants do a per-request TLS handshake and route I/O through the helpers; `wire_transport_check_readable` accepts `https://`; clone/fetch dispatch + target-derive handle the https scheme.
- **Server** (`src/serve.cyr`): `sit serve --tls --cert <file> --key <file>` (cert PEM via sigil `pem_decode_certs`, or DER; key PEM/DER). New TLS accept loop `_serve_run_tls` (accept → `tls_native_new_server` → `tls_native_server_load_creds` → `tls_native_accept` → recv-request-over-TLS → dispatch → close) + `_serve_tls_recv_request`. The response path routes through TLS-aware `_serve_send_status` / `_serve_send_response` wrappers (67 call sites) gated on a per-connection `_serve_tls_ctx` global (safe — the serve loop is single-threaded); plain http stays byte-identical.
- **`tests/sit.tcyr`** — TOFU pin-lookup group (exact match, wrong port/host, empty store, prefix-collision). **146 assertions** (was 138).

### Changed

- **`cyrius.cyml`**: `tls_native` added to `[deps].stdlib` (fits the build — no 256-global cap overflow, unlike `async`). **Toolchain pin `6.1.27 → 6.1.29`** — the toolchain the HTTPS arc was actually validated on. The 6.1.27 pin had drifted from the locally-active cycc; bumping ensures CI builds the same `tls_native` that was tested (the scaffold→working transition in cyrius 6.0.x makes the exact version load-bearing).
- **[ADR 0007](docs/adr/0007-network-transport-security.md)** gained a 2026-06-10 Update recording the `tls_native` unblock — the ruling stands (no libssl / libcrypto / fdlopen, ever), its precondition is now met. The cross-repo blocker `docs/development/issues/archived/2026-05-13-sandhi-first-party-tls-surface-needed.md` is archived **RESOLVED**.
- **Capabilities banner** (`src/serve.cyr`) `0.8.7 → 0.8.8`.

### Validated

- Full e2e: `sit clone https://127.0.0.1:<port>` against `sit serve --tls` (ECDSA P-256 cert) — TOFU-pinned, fetched every object over TLS 1.3, fsck-clean, content correct. The `tls_native` handshake interops with OpenSSL 3.6.2 (`s_client` / `s_server` cross-checks during development). TOFU paths exercised: first-use pins; re-clone matches silently; a tampered pin refuses with a `SECURITY: certificate pin MISMATCH` error and no data transfer.

### Notes / deferred to 0.8.9

- **https push** — `wire_transport_check_writable` still rejects `https://`; the server's 64 KiB TLS request buffer can't take 16 MiB push bodies without streaming.
- **Per-request handshake** (no keep-alive) and a **socket read-timeout** (against a server that holds the connection open, like `openssl s_server -www`) are perf / hardening followups.
- **Ed25519 server certs** fail `tls_native_accept` (ECDSA P-256 works) — use ECDSA P-256 for `sit serve --tls`; a likely upstream `tls_native` gap worth filing.
- Build / test / lint / fuzz green. DCE binary **2.14 MB** (+~14 KB vs v0.8.7).

## [0.8.7] — 2026-06-10 — Wire-walker multi-parent fix

**Closes the wire-walker single-parent footgun surfaced in v0.8.5.** `parse_commit_body` captured only the *last* `parent` header, so the three commit-graph traversals that consumed it followed just one edge per merge commit. Cloning / fetching / pushing a merge-bearing repo could silently drop every object reachable only through a non-last parent — and the resulting clone still passed `sit fsck` ("0 dangling") while missing data. Reproduced on a 3-commit + merge fixture: a clone dropped 2 objects (the first-parent commit + its tree), 11 → 9, with no error surfaced.

### Fixed

- **`parse_commit_body` (`src/commit.cyr`)** now collects *every* `parent` line into a vec at the previously-unused struct slot `out+48` (in body order). `out+8` is left unchanged (still the last parent) so single-parent-chain readers — `cmd_log`, `merge_base` — keep their exact prior behavior; only the traversals below switch to the vec.
- **`walk_reachable_phased` (`src/wire.cyr`)** — the clone / fetch / push object enumerator — enqueues all parents from `out+48` instead of the single `out+8`. This is the load-bearing fix that makes merge-bearing clones complete.
- **`is_ancestor` (`src/commit.cyr`)** rewritten from a naive single-parent chain walk into a BFS over the full commit DAG (queue + seen-set) enqueuing all parents. A first-parent-only walk would falsely report "not an ancestor" across a merge, skewing fast-forward / merge-base decisions.
- **`is_ancestor_in_db` (`src/wire.cyr`)** — the server-side / push fast-forward gate — same fix; it was already a BFS, just enqueuing a single parent.

### Added

- **`tests/sit.tcyr` multi-parent group** (`test_parse_commit_multiparent`): asserts `parse_commit_body` exposes both parents of a synthesized merge body in body order, exactly one for a single-parent commit, and none for a root commit, plus the `out+8` last-parent back-compat invariant. The test file now `include`s `src/lib.cyr` (the `tests/sit.fcyr` pattern) so `parse_commit_body` is in scope; DCE strips everything else. **138 assertions** (was 127).

### Changed

- **Capabilities banner version literal** (`src/serve.cyr:89`) bumped `0.8.5` → `0.8.7` (v0.8.6 skipped the banner bump).

### Out of scope (tracked)

- `merge_base` (`src/merge.cyr`) and `cmd_log` (`src/commit.cyr`) still follow the single `out+8` parent chain. For `cmd_log` that's the intended single-chain log behavior; for `merge_base` it's a latent limitation — correct lowest-common-ancestor across diamond / octopus merges wants a full DAG walk. Queued, not in this slot's scope.

### Notes

- Build / test / lint / fuzz green. DCE binary **2.12 MB** (+672 bytes vs v0.8.6). Lint clean apart from the pre-existing >120-character `eprintln` at `src/commit.cyr:642`.

## [0.8.6] — 2026-06-10 — cyrius 6.1.27 toolchain refresh + dep bumps + stdlib reorg

**Major toolchain line bump.** cyrius `5.11.55 → 6.1.27` (6.x major). No sit source changes — the work was absorbing the cyrius 6.x stdlib reorganization in `cyrius.cyml`.

### Changed

- **cyrius pin** `5.11.55 → 6.1.27` in `cyrius.cyml [package].cyrius`.
- **Dependency bumps**: sakshi `2.2.4 → 2.2.10`, sankoch `2.2.5 → 2.3.0`, sigil `3.1.1 → 3.7.8`, patra `1.9.4 → 1.11.0`. sit's consumed surface (sigil `hash_data` / `hex_*` / ed25519, sankoch zlib, patra object store) is unchanged — build / test / fuzz confirm, end-to-end smoke verifies signed-commit verify against sigil 3.7.8.
- **Stdlib list reorg for cyrius 6.x** (`cyrius.cyml [deps].stdlib`):
  - `bigint` / `base64` / `json` removed — cyrius 6.x folded all three into the new omnibus bundle **`bayan`** (functions gained a `bayan_` prefix; back-compat aliases keep sigil's `u256_*` crypto path working). Replaced the three entries with `bayan`.
  - Added **`slice`** — cyrius 6.x's `agnosys` stdlib module now requires it (`_slice_idx_get_*` helpers).

### Notes

- **Known benign build warning**: `lib/sandhi.cyr` (1.4.10) gained a concurrent server variant `sandhi_server_run_async` that calls `lib/async.cyr`. sit's `cmd_serve` uses the *synchronous* `sandhi_server_run`, so the async path is dead code DCE strips — but the compile emits four `undefined function 'async_*'` warnings. Adding `async` to the stdlib list overflows the 256-initialized-globals cap and hard-fails the build, so the warnings are accepted (same shape as v0.8.5's retired-`hashmap_*` wart).
- **`tls_native` unblock noted** (not consumed this release): cyrius 6.x ships `lib/tls_native.cyr`, a sovereign pure-Cyrius TLS 1.3 stack on sigil primitives (ChaCha20-Poly1305 / AES-GCM / HKDF / X25519 / ECDSA / X.509; no fdlopen, no libssl; interops with OpenSSL 3.x). This clears [ADR 0007](docs/adr/0007-network-transport-security.md)'s gate for the long-blocked HTTPS slot — wiring deferred to a later v0.8.x release.
- DCE binary **2.12 MB** (up from 1.39 MB at v0.8.5 — cyrius 6.x stdlib / sandhi is heavier). 127/127 tests; lint / fuzz green.
- Shipped undocumented (the tag changed only `VERSION` + `cyrius.cyml` + `dist/sit.cyr`); this entry is the retroactive record, written during v0.8.7 prep.

## [0.8.5] — 2026-05-15 — `sit fsck` reachability walk + cyrius 5.11.55 toolchain refresh

**Closes the second v0.7.6 footgun.** `sit fsck` now distinguishes integrity (objects whose stored bytes don't re-hash to their stored key) from reachability (objects no ref / index entry points at). Output gains a third counter and a per-object dangling line:

```
$ sit fsck
dangling tree 497a926fc6e399...
dangling commit a870bbd76ced31...
checked 6 objects, 0 bad, 2 dangling
```

**Toolchain refresh.** cyrius `5.11.34 → 5.11.55` (21 patches; binaries are byte-identical to 5.11.54 so the bump is mostly a tag-line refresh). One known upstream wart: the bundled `lib/sandhi.cyr` calls retired `hashmap_*` symbols (renamed to `map_*` in 5.11.x stdlib). The four "undefined function" warnings during build / test / fuzz are TLS session-cache code (sandhi 1.3.4) that sit doesn't reach — DCE strips them and the binary is clean. Filed upstream as a follow-up to the v0.8.4 `tls_policy/` cross-repo issue.

### Added

- **`fsck_walk_reachable(root, seen)`** in `src/object_db.cyr` — BFS over the object graph from one root hex, marking each visited cstr in `seen` (map_new). Reads each object via the existing `read_object` framing decode, classifies by prefix (`commit `/`tree `/`blob `), and enqueues every referenced hex: for commits, the `tree` line + **every** `parent` line via `fsck_collect_commit_parents` (distinct from `parse_commit_body` which captures only the last parent — a pre-existing limitation that fetch/clone inherits but fsck explicitly does not). For trees, every entry hash via `parse_tree` + `tree_entry_hash`. Blobs are leaves.
- **`fsck_collect_roots()`** — enumerates `.sit/refs/heads/<*>`, `.sit/refs/tags/<*>`, `.sit/refs/remotes/<*>/<*>` (via `dir_walk` — recurses into the per-remote namespaces automatically), plus `.sit/HEAD` when it's a raw hex (detached). Symbolic HEADs are skipped because the matching ref file is already a root. Malformed ref files (non-hex content, length != 64) are silently dropped — they surface in the integrity report as unreachable objects.
- **`fsck_collect_commit_parents(body, body_len, parents)`** — pushes every `parent <hex>\n` header into `parents` as a fresh 65-byte cstring. Stops at the first blank line (end of headers). Validates each candidate via `hex_prefix_valid` so a corrupt commit body doesn't enqueue garbage.
- **`fsck_extract_commit_tree(body, body_len)`** — pulls the `tree <hex>\n` header off the very first line (git always emits tree first); returns 0 on missing / malformed.
- **`fsck_read_ref_tip(path)`** + **`fsck_walk_refs_dir(dir, roots)`** — file-level ref readers that share the same trim-trailing-CR/LF logic as `serve_read_ref_file` but skip the JSON-emit step. Kept in `object_db.cyr` so `cmd_fsck` doesn't pull in `serve.cyr`.
- **Staging-index roots** — every entry from `parse_index()` contributes its blob hex as a root via `hex_encode(entry_hash(e), 32)`. Without this, a `sit add file` that hasn't been committed yet would look dangling. Mirrors git's implicit `git ls-files` keep during fsck.
- **CI smoke step `Smoke — fsck reachability (v0.8.5)`**: builds a 2-commit linear history, asserts `0 bad, 0 dangling`; rewinds `main` to the root commit, asserts `0 bad, 2 dangling` plus `^dangling commit ` and `^dangling tree ` lines; then builds a merge commit (base → feature + main → merge), deletes `refs/heads/feature` so the only path to the on-feature commit is via the merge's second `parent` line, and asserts `0 bad, 0 dangling` — proving the walker follows both parent edges.

### Changed

- **`cmd_fsck` output** gains a third counter:
  - Old: `checked N objects, M bad\n`
  - New: `checked N objects, M bad, D dangling\n`
  - The `0 bad` substring is preserved verbatim so the existing `grep -q "0 bad"` assertions across CI keep working unchanged.
- **`cmd_fsck` integrity SELECT** widens from `SELECT hash FROM objects` to `SELECT hash, ty FROM objects` so dangling lines can emit the git-shaped `dangling <blob|tree|commit> <hex>` form without paying for a second read per dangling object. The `ty_map` (cstr-hex → ty + 1; the +1 keeps `map_get`'s 0 sentinel distinct from `ty==0` blobs) is consulted only on the dangling pass.
- **Dangling does not fail the command.** Matches git's policy: integrity errors set non-zero exit; dangling objects are normal after resets, rewinds, or aborted merges. The exit code is governed solely by `bad > 0`.
- **`cyrius` pin**: `5.11.34 → 5.11.55` in `cyrius.cyml [package].cyrius`. Lib snapshot is identical to 5.11.54 (verified `diff -rq`). No dep bumps in this release.
- **Capabilities banner version literal** (`src/serve.cyr:89`) bumped `0.8.4` → `0.8.5`.

### Fixed

- **v0.7.6 footgun #2: dangling-object detection.** `sit fsck` previously only surfaced rehash failures; objects rendered unreachable by `sit reset`, manual ref rewrites, or `sit merge --abort` would persist in `.sit/objects.patra` without any signal. They still persist (sit doesn't GC yet — that's a future slot), but they're now reported, which is the prerequisite for a future `sit gc` to know what to drop.

### Sit-side impact

- Build: clean. DCE binary **1.39 MB** (up from 1.36 MB at v0.8.4; ~30 KB delta — the fsck additions are ~300 lines of Cyrius and the integrity-pass widening to `SELECT hash, ty FROM objects` keeps a per-object `ty_map` entry alive for the dangling pass).
- Tests: 127/127 pass. Lint clean (1 pre-existing diagnostic in `src/object_db.cyr:122` — `ERR_BUFFER_TOO_SMALL` enum reference predates this release). Fuzz: 6 harnesses, all `fuzz: no crashes`.
- End-to-end verified locally: clean 2-commit history → 0 dangling; ref-rewind → 2 dangling (commit + tree, blob stays reachable via staging index); merge commit + delete-feature → 0 dangling (both parent edges followed).

### Out of scope (queued for v0.8.6+)

- **`sit gc`** — actually drop the dangling objects. Needs a grace period (don't drop objects newer than N seconds) and probably reflog support first.
- **Multi-parent walk for fetch/clone/push** — `parse_commit_body` still captures only the last `parent` line, so wire-protocol walkers (`walk_reachable_phased`) inherit the same single-parent limitation. CI fixtures are linear so this doesn't manifest, but cloning a merge-heavy history would miss objects reachable only via first-parent edges. Filed for v0.8.6 — `parse_commit_body` needs to return a parents vec, and `walk_reachable_phased`'s queue needs to enqueue all of them.
- **Broken ref reporting** — `fsck_collect_roots` silently skips ref files that fail `hex_prefix_valid` or have unexpected length. Surfacing those as a third class of fsck finding (`broken ref refs/heads/foo: ...`) is a small follow-up.
- **HTTPS / mTLS** — still blocked on sandhi's `tls_policy/` being libssl-via-fdlopen (cross-repo issue `2026-05-13-sandhi-first-party-tls-surface-needed.md` carries upstream). v0.8.6 expected to slot fsck multi-parent walk or `.sitignore` semantics next, depending on what unblocks first.

## [0.8.4] — 2026-05-13 — `denyCurrentBranch` default refuse + HTTPS/mTLS slots blocked upstream

**Closes the v0.7.6 documented footgun.** Pushes to a remote whose `HEAD` is the same branch are now refused by default — mirrors git's `receive.denyCurrentBranch=refuse`. Previously, `sit push` silently advanced the remote's `refs/heads/<branch>` while leaving its working tree stale, surprising whoever was editing on the remote side. **All three transports** (file://, http://, ssh://) gate the same way.

**Upstream block surfaced for HTTPS/mTLS.** Verified during v0.8.4 prep: sandhi's `tls_policy/` is libssl-via-fdlopen at the transport layer (composes `lib/tls.cyr`'s FFI bridge); consuming it from sit would punch [ADR 0007](docs/adr/0007-network-transport-security.md)'s no-libssl wall. Filed upstream at [`docs/development/issues/2026-05-13-sandhi-first-party-tls-surface-needed.md`](docs/development/issues/2026-05-13-sandhi-first-party-tls-surface-needed.md). v0.8.4 and v0.8.5 slots (originally HTTPS + mTLS) re-targeted to `denyCurrentBranch` + `sit fsck` reachability; HTTPS/mTLS slot in when the upstream gate clears.

### Added

- **Server-side `denyCurrentBranch` check** in `src/serve.cyr`'s `serve_handle_put_ref` (right after the namespace check, before the FF gate). When the incoming refname matches the server's checked-out HEAD branch (read via `read_head_ref_path`) AND the ref already exists (so it's not an initial push to an empty remote), respond `423 Locked` with body `"refusing to update checked-out branch (denyCurrentBranch)"`. 423 distinguishes this from 409 Conflict (non-FF) on the wire so the client can surface the right error.
- **`_remote_current_branch(repo_path)`** helper in `src/wire.cyr` — reads `<repo_path>/.sit/HEAD`, returns the branch name if it's a symbolic ref ("ref: refs/heads/<name>"), or 0 for detached HEAD / unreadable. Used by the file:// push path to enforce the same denyCurrentBranch gate as the http:// / ssh:// path.
- **CI smoke step extension** in the SSH smoke block: build a SECOND origin with HEAD attached to main + an initial commit; clone, second commit, push — assert REJECTED with the `denyCurrentBranch` message and origin's ref unchanged. Then detach HEAD on origin and assert the same push now succeeds.
- **Cross-repo issue** at `docs/development/issues/2026-05-13-sandhi-first-party-tls-surface-needed.md` documenting the HTTPS/mTLS upstream block — sandhi's `tls_policy` wraps libssl-via-fdlopen (verified against sandhi 1.3.4 + cyrius 5.11.34); sit can't consume it without violating ADR 0007. Three proposed fixes (cyrius `lib/tls.cyr` becomes first-party; sandhi grows a parallel native surface; ADR 0007 amendment). User carries upstream.

### Changed

- **`http_remote_push_ref` / `ssh_remote_push_ref` return convention**: gained a third success code:
  - `0` — HTTP 200 (success)
  - `1` — HTTP 409 (non-fast-forward)
  - `2` — HTTP 423 (denyCurrentBranch) — **new in v0.8.4**
  - `-1` — any other failure
- **`_do_push_http` / `_do_push_ssh`** surface the new return code as a distinct user-visible message:
  - `1` → `"sit: server rejected ref update (non-fast-forward)"`
  - `2` → `"sit: server refuses to update its checked-out branch (denyCurrentBranch)"`
  - other → `"sit: server rejected ref update"`
- **File:// push path** (`cmd_push` else-arm) gains the same `denyCurrentBranch` check before the FF check; emits the user-facing message `"sit: remote refuses to update its checked-out branch (denyCurrentBranch)"`.
- **CI smoke: file:// wire smoke, ssh:// smoke, http:// push smoke** all detach ORIG's HEAD right after setup (`cp .sit/refs/heads/main .sit/HEAD`) so the existing assertions that push to main still succeed. A "real server-shaped remote" is either bare or has a non-current branch checked out; detached HEAD is the simplest stand-in for both.
- **Capabilities banner version literal** (`src/serve.cyr:87`) bumped `0.8.3` → `0.8.4`.

### Fixed

- **v0.7.6 documented footgun**: `sit push` no longer silently advances a remote's `refs/heads/<branch>` while leaving its working tree stale. Push to a checked-out branch fails loudly at the server with a clear error; the operator either detaches HEAD on the remote, points HEAD at a different branch, or accepts the rejection. Initial pushes to an empty remote (no ref file yet) still succeed, matching git's behavior.

### Sit-side impact

- Build: clean. DCE binary 1.36 MB (essentially flat from v0.8.3 — denyCurrentBranch is ~25 lines server-side + ~30 lines in wire.cyr's file:// arm + the helper).
- Tests: 127/127 pass. Lint clean. Fuzz: 6 harnesses, all `fuzz: no crashes`.
- End-to-end verified locally across all three transports:
  - file:// push to checked-out branch → REJECTED with denyCurrentBranch message
  - ssh:// push to checked-out branch → REJECTED (different message body, same outcome)
  - Detached-HEAD origin → push succeeds
  - Empty remote with HEAD on main → initial push succeeds (bypass)
- Known-footgun-tracked: this is the first item from the v0.7.6 "Known footguns" list to land a fix.

### Cross-repo issue filed (carry upstream)

- [`docs/development/issues/2026-05-13-sandhi-first-party-tls-surface-needed.md`](docs/development/issues/2026-05-13-sandhi-first-party-tls-surface-needed.md) — High severity. Blocks sit's HTTPS (was v0.8.4) and mTLS (was v0.8.5) roadmap slots. Sandhi's `tls_policy/` wraps stdlib `lib/tls.cyr` which is libssl-via-fdlopen; ADR 0007 forbids consumption. Three fix paths documented; preference: cyrius `lib/tls.cyr` becomes first-party Cyrius.

## [0.8.3] — 2026-05-13 — Push over SSH

**Closes the v0.8.2 read-only gap.** `sit push origin main` works over `ssh://` URLs:

```sh
sit clone ssh://user@host/path/to/repo
# edit, add, commit
sit push origin main   # ← works as of 0.8.3
```

Mirrors the v0.7.6 HTTP push pipeline (capabilities probe → FF preflight → walk reachable → per-object POST → ref POST → up-to-date short-circuit), but layered onto v0.8.2's persistent SSH stdio session. One ssh handshake per push, many HTTP/1.1 requests through the same pipe. Server-side handlers (`POST /sit/v1/objects/<hex>` rehash-verify + `POST /sit/v1/refs/<refname>` FF gate, both shipped in v0.7.6) are transport-agnostic — they consume `buf+n` the same way over a TCP socket or the stdio pipe — so the entire trust-boundary story (sigil rehash on every uploaded object, FF gate on every ref update) carries over unchanged from HTTP.

### Added

- **`_wire_ssh_post_xhdr(h, sub_path, body, body_len, extra_hdr, out_body)`** in `src/wire_ssh.cyr`: send a POST request over the persistent ssh pipe with an arbitrary extra header (used for `X-Sit-Type` on object pushes). Speaks HTTP/1.1 with no `Connection: close` — the ssh session lives across requests, so signaling close after each POST would defeat pipelining.
- **`_wire_ssh_recv_response(rfd, out_body)`** extracted from `_wire_ssh_request` so GET and POST share the response-parse logic in one place (status-line + `\r\n\r\n` body-offset + Content-Length + X-Sit-Type extraction + body-copy).
- **`ssh_remote_push_object(h, hex, ty, compressed, clen)`**: POST one compressed object via `/sit/v1/objects/<hex>` with the `X-Sit-Type: <ty>\r\n` extra header. Returns `1` for newly-inserted (HTTP 201), `0` for already-present (HTTP 200, idempotent retry-safe), `-1` for any failure. Same shape as `http_remote_push_object`.
- **`ssh_remote_push_ref(h, refname, hex)`**: POST the new tip via `/sit/v1/refs/<refname>` with body `<64-hex>\n`. Returns `0` for HTTP 200, `1` for HTTP 409 (non-FF conflict), `-1` for any other failure. Same shape as `http_remote_push_ref`.
- **`_do_push_ssh(name, branch, url, src_db, local_tip)`** in `src/wire.cyr`: full SSH push pipeline. Mirrors `_do_push_http` — capabilities probe (via `wire_ssh_open`) → FF preflight via `ssh_remote_resolve_branch` → walk reachable + raw-cache → per-object POST → ref POST → "everything up-to-date" short-circuit when `remote_tip == local_tip`. Counts only fresh inserts (201) in the summary, not idempotent already-present (200).
- **`_ssh_handle_auth_token(h)` stub** returning 0. Bearer-auth on top of SSH is reserved for a v0.8.3.x patch — SSH already authenticates the user end-to-end via key exchange + authorized_keys, so an extra server-side `--require-auth` token doesn't add a meaningful trust boundary for the canonical case. `_wire_ssh_post_xhdr` already injects `Authorization: Bearer <token>` headers when the handle has a token loaded; flipping that on is one accessor away.
- **CI smoke step extended** (`Smoke — ssh clone (v0.8.2)` retitled in spirit): after the v0.8.2 clone + CVE injection assertions, the step now runs a full ssh push round trip — clone, second commit, push, assert origin advances + log shows the new commit. Plus a re-push asserting "everything up-to-date" and a non-FF rejection (rewind clone to parent, divergent commit, push must fail with the non-fast-forward error and leave origin's ref intact).

### Changed

- **`wire_transport_check_writable`** now accepts `URL_SCHEME_SSH`. The v0.8.2 placeholder error (`"push over ssh requires sit 0.8.3+ (read-only ssh is available now)"`) is gone — push over ssh is live.
- **`cmd_push` URL-scheme dispatch** gains a third arm: `URL_SCHEME_SSH` → `_do_push_ssh`. The HTTP and file:// branches are unchanged.
- **Capabilities banner version literal** (`src/serve.cyr:87`) bumped `0.8.2` → `0.8.3`. Same closeout-time check until a derive-from-VERSION mechanism lands.

### Fixed

- (none — v0.8.3 is purely additive over v0.8.2.)

### Sit-side impact

- Build: clean. DCE binary 1.36 MB (essentially flat from v0.8.2 — DCE strips the unused `_ssh_handle_auth_token` branch in the post path; `_do_push_ssh` was DCE-reachable from `cmd_push` and added ~140 lines net).
- Tests: 127/127 pass. Lint clean. Fuzz: 6 harnesses, all `fuzz: no crashes`.
- End-to-end smoke verified locally: clone → second-commit → push → origin advanced; re-push → "everything up-to-date"; rewind + divergent commit → push fails with non-fast-forward error and origin's ref unchanged.

### Downstream

- Any consumer that wants encrypted-over-internet push can now use `ssh://` everywhere `http://` worked before, without sit-side config. Auth + key selection happens via standard ssh ergonomics (`~/.ssh/config` `IdentityFile` / `IdentitiesOnly`).

### Out of scope (queued for v0.8.4+)

- **HTTPS via sandhi first-party Cyrius TLS** — next slot. Sandhi's TLS arc shipped in v1.3.2+; sit-side wire-up pending a sandhi-consumable surface review (gate prerequisite per ADR 0007: verify it's first-party Cyrius, not a libssl-via-fdlopen shim).
- **mTLS** — builds on HTTPS in v0.8.4.
- **Bearer auth over SSH** (belt-and-suspenders) — the `_wire_ssh_post_xhdr` code path already supports it; just needs the handle to learn the token from capabilities + load `~/.sit/serve.token`. Slot whenever a consumer asks.
- **`/sit/v1/want` batching over SSH** — same `obj_src_batch_prefetch` no-op for `OBJ_SRC_SSH` as in v0.8.2. The win is smaller over SSH (no per-request handshake) but still real on high-RTT links.

## [0.8.2] — 2026-05-13 — SSH transport (`ssh://`), read-only

**Closes ADR 0007's encrypted-over-internet gap on the read side.** Sit clones and fetches over `ssh://` work end-to-end:

```sh
sit clone ssh://user@host/path/to/repo
sit fetch origin   # if origin was added with an ssh:// URL
```

SSH owns the encryption + auth handshake; sit's wire is the same HTTP/1.1 it speaks over TCP, riding the SSH-managed stdin/stdout pipes. Process boundary, not FFI — sit consumes the `ssh` binary, no crypto in sit's address space, no library link. Matches git's `ssh://` design. Push over SSH lands in v0.8.3+ — it mirrors the v0.7.6 HTTP push pipeline but over the persistent stdio session.

### Added

- **`sit serve --stdio`** mode in `src/serve.cyr` (~80 lines). Reads HTTP/1.1 requests from STDIN, writes responses to STDOUT, no TCP socket. Pipelining-safe via `_stdio_recv_request` — preserves any trailing bytes from request N that belong to request N+1 (memcpy carryover to front of buffer, parse on next iteration). Reuses sandhi's `sandhi_server_recv_request` / `sandhi_server_send_response` directly since `sock_send` / `sock_recv` are just `sys_write` / `sys_read` (see `lib/net.cyr`) — they work unchanged on pipe fds.
- **`src/wire_ssh.cyr`** (~530 lines). Spawns `ssh user@host -- sit serve <repo-path> --stdio` via raw `sys_execve` (after walking `$PATH` to find ssh's absolute path; raw execve has no PATH lookup). Bidirectional pipes via `sys_pipe` × 2. Public surface mirrors `wire_http.cyr`'s shape: `wire_ssh_open`, `wire_ssh_close`, `ssh_remote_read_refs`, `ssh_remote_resolve_branch`, `ssh_remote_read_raw`, `ssh_remote_read_both`. Capabilities probe at open time surfaces ssh-config / auth failures as clean errors rather than mid-clone confusion.
- **`obj_src` extension**: `OBJ_SRC_SSH = 2` tag + `obj_src_for_ssh(handle)` constructor; `obj_src_read_raw` / `obj_src_read_both` dispatch to the SSH path. `walk_reachable_*` and `copy_objects` are transport-agnostic — the same code paths that handled file:// and http:// now handle ssh:// without modification.
- **`do_fetch` SSH branch**: third arm alongside file:// and http://. Calls `wire_ssh_open(url)` → `ssh_remote_resolve_branch(handle, branch)` → fold into `obj_src_for_ssh` → standard walk + copy. Closes `wire_ssh_close(ssh_handle)` on every exit path.
- **[ADR 0008 — SSH transport: process boundary, not FFI](docs/adr/0008-ssh-transport.md)**: documents the architecture choice (fork+exec on the system's `ssh`, not libssh-link), the CVE-2017-1000117 three-layer defense, the env-curation rationale (only `HOME` / `USER` / `LOGNAME` / `SSH_AUTH_SOCK` / `TERM` / `PATH` cross the trust boundary), the SSH-handshake-amortization via one-session-many-requests, and the four rejected alternatives (libssh2 link, native Cyrius SSH, libssh-via-fdlopen, no-SSH-just-wait-for-HTTPS).
- **CI `Smoke — ssh clone (v0.8.2)` step** in `.github/workflows/ci.yml`. Stands up a loopback `sshd` on `127.0.0.1:22422` with a passphrase-less ed25519 key, exposes the built `sit` binary on `/usr/local/bin/sit`, configures the client's `~/.ssh/config` for the `sit-test` host alias, runs `sit clone ssh://sit-test<repo-path>`, asserts content matches and `sit fsck` is clean. Plus: asserts `sit clone ssh://-oProxyCommand=touch+/tmp/PWNED/host/repo` exits non-zero before any exec and `/tmp/PWNED` is never created (CVE-2017-1000117 defense).
- **`fuzz_ssh_url_parser` harness** in `tests/sit.fcyr` (100,000 rounds). Drives pseudo-random bytes through `_ssh_parse_url`. Exercises leading-dash rejection (CVE-2017-1000117 class), the user@host `@` separator, the host:port colon detection, and general malformed-input survival. Clean — no crashes / OOB reads / infinite loops.

### Changed

- **CVE-2017-1000117 three-layer defense.** (1) `remote_url_valid` (v0.7.1) whitelists URL body characters; (2) `_ssh_parse_url` (new in v0.8.2) explicitly rejects any user / host / first-path-segment component starting with `-`; (3) the spawned `ssh` argv includes the `--` sentinel between flags and positional args, so even a hypothetical leading-dash byte slipping through both prior layers couldn't be interpreted as an ssh option. `sys_execve` builds argv from explicit elements with no shell interpolation — no path for metacharacter injection either.
- **`wire_transport_check_readable`** accepts `URL_SCHEME_SSH` (was rejected with `"requires sit 0.7.8+"` pointer). **`wire_transport_check_writable`** still rejects SSH with `"push over ssh requires sit 0.8.3+ (read-only ssh is available now)"` — push over SSH is the next slot.
- **Capabilities banner version literal** (`src/serve.cyr:87`) bumped `0.7.6` → `0.8.2`. Still hardcoded; tracked as a closeout-time check until a derive-from-VERSION mechanism lands.

### Sit-side impact

- Build: clean on `cyrius build src/main.cyr build/sit`; DCE binary **1.36 MB** x86_64, up from v0.8.1's 1.30 MB. Growth concentrated in `src/wire_ssh.cyr` (~530 lines) + the `--stdio` dispatch in `serve.cyr` (~80 lines).
- Tests: 127/127 pass. Lint clean. Fuzz: 6 harnesses (added `ssh_url_parser`), all `fuzz: no crashes`.
- End-to-end smoke verified locally: `sit clone ssh://localhost/tmp/<fixture>` succeeds, `cat <clone>/a.txt` returns the seed repo's content, `sit fsck` clean (0 bad), 3 objects copied over a single ssh session.

### Downstream

- Owl's `src/vcs.cyr` library-call swap (the v0.8.1 work) continues to work unchanged — `sit_diff_path` is repo-local; SSH only affects clone/fetch.
- Sit consumers that want encrypted-over-internet clones can now use `ssh://` URLs everywhere `http://` worked before, with no sit-side config changes. Identity selection happens via `~/.ssh/config` (`IdentityFile` / `IdentitiesOnly`) — standard ssh ergonomics.

### Out of scope (queued for v0.8.3+)

- **Push over SSH** — same pipeline as the v0.7.6 HTTP push but layered onto the persistent stdio session. Server-side `_serve_run_stdio` already handles POST methods via the existing dispatch.
- **`/sit/v1/want` batching over SSH** — `obj_src_batch_prefetch` is a no-op for `OBJ_SRC_SSH` today. The win is smaller over SSH (no per-request handshake) but still real on high-RTT links; queued.
- **mTLS** — depends on first-party Cyrius TLS in sandhi, blocked at the sandhi level for now.

### Known footguns (tracked)

- **Capabilities-version literal drift**: `src/serve.cyr:87`'s `"sit":"0.8.2"` is bumped by hand each release. Closeout pass before tag asserts the literal matches `VERSION`. A future cleanup release (likely alongside an automation pass) wires this to the version constant.
- **Remote PATH dependency**: the SSH client invokes `sit` on the remote without a path. Production consumers need `sit` on the remote shell's non-interactive PATH (just like git users need `git-upload-pack`). The CI smoke uses `/usr/local/bin/sit` symlink; documented in ADR 0008 and the SSH troubleshooting guide.

## [0.8.1] — 2026-05-13 — Library export (`dist/sit.cyr`) + diff primitive cleanup (owl-blocker resolved)

**Closes owl's library-call swap precondition.** Sit is now consumable as a Cyrius dep:

```toml
[deps.sit]
git = "https://github.com/MacCracken/sit.git"
tag = "0.8.1"
modules = ["dist/sit.cyr"]
```

Originally slotted v0.7.7 before the v0.7.x line ended at v0.7.6 ahead of the v0.8.x line-opener (v0.8.0). owl's `src/vcs.cyr` `execve("git", "diff", …)` → library-call swap unblocks at this release.

### Added

- **`dist/sit.cyr`** — generated library bundle for downstream consumers (9,765 lines at v0.8.1). Tracked in-repo per the sandhi / cyim convention so consumers pin sit by tag and find the bundle at the pinned commit without re-running `cyrius distlib`. Generated from `cyrius.cyml`'s new `[lib].modules` block enumerating the source modules in dependency order (mirrors `src/lib.cyr`'s include chain).
- **`[lib]` block in `cyrius.cyml`** — drives `cyrius distlib`. Order: util / validate / config / object_db / index / refs / tree / diff / commit / merge / sign / wire / wire_http / serve / **api** (last; public surface). Single-pass compiler means each module can only reference symbols defined in earlier modules — order matters.
- **`src/api.cyr`** — sit's stable public-API surface (93 lines, all `sit_*`-prefixed):
  - **`sit_repo_open(cwd)`** — chdirs to `cwd`, verifies `.sit/HEAD`. Returns `1` on success, `0` on failure. The returned handle is opaque in v0.8.1 (chdir-based; single-repo-per-process); will gain real semantics in a future release.
  - **`sit_repo_close(repo)`** — no-op in v0.8.1, reserved for forward compatibility. Consumers should still call it.
  - **`sit_diff_path(repo, path)`** — HEAD-blob vs working-tree diff for `path`. Returns a vec of annotated-op records (use `ann_kind` / `ann_line` / `ann_old` / `ann_new` to inspect each), or `0` if both sides are empty. Handles add-only / delete-only / both-present cases uniformly via empty-buffer convention.
- **`compute_file_diff(old_buf, old_len, new_buf, new_len)`** in `src/diff.cyr` — pure-compute layer extracted from `print_file_diff`. Returns the annotated-ops vec without I/O; `print_file_diff` now calls it and emits stdout in a thin wrapper. Public surface (`sit_diff_path` is a thin wrapper over `compute_file_diff` + HEAD/working-tree resolution).
- **[ADR 0009 — Public API contract](docs/adr/0009-public-api-contract.md)** — names `sit_*` / `ann_*` as the stable, SemVer-governed surface; everything else in `dist/sit.cyr` is internal (existence-in-bundle is a build artifact of concatenation, not a promise). Renaming / removing / arity-changing a `sit_*` or `ann_*` fn is a major bump; adding new ones is a minor; internal refactors are patch. Pre-1.0 caveat: sit commits to the contract _as if_ post-1.0 — breaking changes will be flagged explicitly in **Breaking** sections. Operational gate: every release diff `dist/sit.cyr` against the prior tag, filter `^[+-]fn (sit_|ann_)`, cross-reference against CHANGELOG.
- **CI `Verify dist/sit.cyr is in sync` step** — runs `cyrius distlib` and asserts no diff against the tracked bundle (prevents the "public-API change forgot to regenerate dist" trap). Asserts the bundle contains the documented public symbols (`sit_repo_open`, `sit_repo_close`, `sit_diff_path`, `compute_file_diff`, `ann_kind`, `ann_line`, `ann_old`, `ann_new`) so the `[lib]` block can't silently drop a module.
- **CI `Smoke — diff -U<N> context width` step** — asserts byte-shape of `sit diff -U0` / `-U1` / default `-U3` against the canonical unified-diff `@@` header layout on a controlled fixture; matches `git diff -U<N>` behavior.

### Changed

- **`cmd_diff` / `cmd_show`** parse `-U<N>` (hunk context width). Was hardcoded to 3 at the `group_hunks(annotated, 3)` call site in `print_file_diff` and ignored from CLI args. Now: `-U<N>` argument flows from the CLI through a `ctx` parameter on `print_file_diff` to `group_hunks(annotated, ctx)`. Default stays at 3 to match prior behavior. `cmd_show` also gained `-U<N>` parsing to mirror `git show -U<N>`. Owl's `git diff -U0` shell-out → `sit diff -U0` library call needs this for byte-shape parity.
- **`print_file_diff` signature** gained a trailing `ctx` parameter. All 13 callers across `cmd_diff` and `cmd_show` updated; `print_file_stat` (the diffstat path) is unchanged — it doesn't emit hunks.
- **`src/lib.cyr`** — `include "src/api.cyr"` appended last in the chain.

### Fixed

- **`src/config.cyr:176`** — consecutive blank lines collapsed. Pre-existing lint warning the v0.8.0 CI `Lint` step started surfacing; mechanical fix.

### Sit-side impact

- Build: clean. DCE binary stays at **1.30 MB** x86_64 (sit_repo_close / sit_diff_path show as "dead" in main builds — DCE strips them since `main()` doesn't call them; they're for library consumers).
- Tests: 127/127 pass. Lint clean. Fuzz: `fuzz: no crashes` across all five harnesses.
- New CI smoke verified end-to-end: `sit diff -U0` emits `@@ -2 +2 @@` (no comma, single-line range; matches git's `-U0` shape); `-U1` emits `@@ -1,3 +1,3 @@`; default emits `@@ -1,5 +1,5 @@`.
- `dist/sit.cyr` regenerated; CI guard prevents drift.

### Downstream

- **owl** can now drop the `execve("git", "diff", "-U0", "--", path)` shell-out in `src/vcs.cyr` for a `sit_diff_path(repo, path)` library call returning the same annotated-ops shape. owl pin: `[deps.sit] tag = "0.8.1" modules = ["dist/sit.cyr"]`.

### Out of scope (queued for v0.8.2+)

- **`line_ptr` / `line_len` accessor naming** — currently bare names; ADR 0009 commits them to stability via the contract but the `ann_`-prefix convention would surface this binding more clearly. Rename slotted for a future cleanup release.
- **Multi-repo concurrent handles** — v0.8.1 `sit_repo_open` chdirs the process; a single handle at a time. Real repo-handle struct deferred until a consumer needs it.

## [0.8.0] — 2026-05-12 — Line opener: cyrius 5.11.34 toolchain refresh + dep major bumps + CI lint/fuzz

**Minor-line opener.** Toolchain + dep refresh + small CI / repo-hygiene wins; no new feature work. v0.7.6 shipped 2026-05-08; the v0.7.x line ended there ahead of the v0.7.7 (`dist/sit.cyr` lib export + diff cleanup) and v0.7.8 (SSH) slots, which now move into the v0.8.x slot table. The cap raise (cyrius v5.11.33, `PP_IFDEF_PASS` 2 MB → 8 MB) was the load-bearing precondition for this bump — sit-on-stock-`[deps].stdlib` expansion measured 2,099,593 bytes against the prior 2 MB cap mid-investigation, blocking the move forward until the cyrius side widened. Issue filed + resolved same-day: [`cyrius/.../archived/2026-05-12-pp-2mb-cap-blocks-sit-on-sandhi-fold.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/archived/2026-05-12-pp-2mb-cap-blocks-sit-on-sandhi-fold.md). No sit source changes other than one cosmetic lint fix.

### Toolchain

- **cyrius `5.9.37` → `5.11.34`.** Spans 100+ patches across the v5.10.x and v5.11.x lines. Load-bearing pickups: **v5.10.x SLOT 19** transitive `[deps]` include (sit can simplify its stdlib list when sandhi exposes the right transitive edges), **v5.10.21 / .27 / .34** the TLS 1.3 0-RTT primitive trio sandhi v1.3.2 composes (only relevant once sit consumes Cyrius-native TLS — currently sandhi-side only), **v5.11.0 onward** the `: i64` return-type annotation surface (sandhi's v1.3.4 ran a mechanical sed pass; sit's annotation pass is queued for a follow-on v0.8.x patch, not this release), and **v5.11.33** the cap raise. v5.11.29 / .30 / .31 / .32 / .34 are the ELF section-header table fixes (`e_shoff = 0` on every emitter path; `readelf -S` / `objdump -d` / IDE indexers now see real section info on every sit binary).

### Dep bumps

| dep | pin | from → to | notes |
|---|---|---|---|
| sakshi | `2.2.4` | 2.1.0 → 2.2.4 | annotation pass + CI/release fixes; no public-surface impact for sit |
| sankoch | `2.2.5` | 2.1.0 → 2.2.5 | annotation pass + CI/release fixes; the larger 2.x match-finder / ring-buffer / SIMD work queued upstream is still pending — `add-1MB`'s `zlib_compress` floor is unmoved |
| sigil | `3.1.1` | 2.9.3 → 3.1.1 | **major bump.** sigil 3.0.0 retired `ct_eq` in favor of cyrius stdlib `ct_eq_bytes_lens` (paired with cyrius v5.9.20's lift); `TRUST_COMMUNITY` enum slot 2 retired (kept unassigned for ABI); `-D SIGIL_BATCH_PARALLEL` cmdline flag retired. **Audit clean** — sit calls `hash_data` / `hex_encode` / `hex_decode` / ed25519 verbs only; none of the retired surfaces touched |
| patra | `1.9.4` | 1.8.3 → 1.9.4 | patch-line bumps; no public-surface impact for sit |

### Added

- **`.gitignore`**: `/lib/`, `/src/lib/`, `/cyrius.lock` added. `lib/` is a build artifact populated by `cp -rL "$HOME/.cyrius/lib/"* lib/` (stdlib snapshot from the toolchain install) + `cyrius deps` ([deps.X] git crates); `src/lib/` is a compiler scratch directory cc5 5.11.x creates adjacent to the entry point; `cyrius.lock` is `cyrius deps` output. None belong in tracked source. Mirrors the sandhi / cyim convention.
- **Stdlib list grew**: added `bigint` / `ct` / `keccak` (sigil 3.x transitive needs — `u256_*` / `ct_eq_bytes_lens` / `_keccak_*` / `shake256`; the cyrius v5.10.x SLOT 19 transitive `[deps]` include doesn't follow enum / constant references through sigil's crypto primitives) and `base64` / `mmap` / `dynlib` / `fdlopen` (sandhi's TLS-shim transitives — sandhi v1.3.2's TLS 1.3 0-RTT path references `TLS_EARLY_DATA_*` constants and `fdlopen_*` verbs that aren't auto-pulled). Without these explicit entries, `cyrius test` exits 132 (SIGILL on cyrius's `ud2` for undefined-fn callsites the test runner reaches but DCE didn't strip). `bigint` / `ct` / `keccak` were briefly trimmed during v0.8.0 prep on the transitive-resolution-will-cover-it assumption; CI surfaced the gap, restored same release.
- **CI `Lint` step** (`.github/workflows/ci.yml`): runs `cyrius lint` per `src/*.cyr` with the 120-char rule whitelisted (cosmetic divider lines); hard-fails on any other warning. Matches the cyim CI shape.
- **CI `Fuzz` step**: runs `cyrius run tests/sit.fcyr` (sit keeps the single-file harness layout rather than cyim's `fuzz/*.fcyr` discovery shape). Bounded harnesses: `sigil hash_data` (5K rounds), `sankoch zlib_decompress` (10K), `hex_decode` (10K), URL validators (10K), `want_frame_decoder` (10M). Total ~60s on the bench host.

### Changed

- **`git rm --cached`** on 40 `lib/*.cyr` files + `cyrius.lock` — these were tracked from a pre-`.gitignore` era; new `.gitignore` entries now exclude them. Build artifacts only; no source loss.
- **CI install step** (both `ci.yml` and `release.yml`) switched to the modern `install.sh` one-liner pattern (matches sigil / sandhi CI), which lays out `$HOME/.cyrius/versions/$CYRIUS_VERSION/{bin,lib}` plus the flat symlinks at `$HOME/.cyrius/{bin,lib}` and writes `$HOME/.cyrius/current`. Replaces the previous hand-rolled `curl + tar + cp` step that landed stdlib at the wrong path for cyrius 5.11.x's version-pinned resolution.
- **CI "Resolve dependencies" step** now runs `cp -rL "$HOME/.cyrius/lib/"* lib/` to populate `./lib/` from the install.sh-laid stdlib (cc5's preprocessor reads from `./lib/` specifically), then `cyrius deps` adds `[deps.X]` git crates. Bypasses `cyrius update` entirely — direct cp is more reliable across CI `$HOME` shapes; `cyrius update`'s "cannot find Cyrius stdlib" error mode was the symptom that surfaced the original bug.
- **`src/config.cyr:176`** — collapsed consecutive blank lines (single lint warning surfaced by adding the new lint CI step).

### Fixed

- **CI build break** when stdlib doesn't ship to the version-pinned cyrius install path. Local dev environments with prior cyrius installs masked this until the 5.11.x bump exposed it — `cyrius deps` always resolved 5 entries (the 4 `[deps.X]` crates + `agnosys` implicit) and reported 24 errors for every stdlib entry, but the build succeeded locally because `~/.cyrius/versions/<old-version>/lib/` was still around. CI runners get fresh installs, so the bug surfaced there immediately.

### Cross-repo cascade

- **cyrius v5.11.33** — `PP_IFDEF_PASS` 2 MB → 8 MB cap raise. Filed by sit at 2026-05-12 ([cyrius issue](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/archived/2026-05-12-pp-2mb-cap-blocks-sit-on-sandhi-fold.md)) when the toolchain bump surfaced sandhi-fold accretion (TLS 1.3 0-RTT + HTTP/2 + RPC + retry + SSE pushed `lib/sandhi.cyr` to 11,729 lines; sit's expansion went 2,441 bytes over). Fix shipped same day; consumer expansion now well under the new ceiling.

### Sit-side impact

- Build: clean on `cyrius build src/main.cyr build/sit`; DCE binary **1,368,248 bytes (~1.30 MB)** x86_64, essentially flat from v0.7.6's 1.30 MB (no source-level adds).
- Tests: `cyrius test tests/sit.tcyr` passes (sigil SHA-256, git-SHA-256 blob framing, hex roundtrip, sankoch zlib, patra COL_BYTES small + overflow, ed25519 sign/verify, validator suite).
- Lint: clean (after `src/config.cyr:176` fix; pre-existing >120-char divider warning at `src/commit.cyr:609` still tolerated by the new CI step's whitelist).
- Fuzz: clean — `fuzz: no crashes` across all five harnesses.

### Out of scope (queued for v0.8.x patches)

- **`: i64` return-type annotation pass** across sit's public fn surface (sandhi v1.3.4 ran a mechanical sed pass on 703 fns; sit has ~80 candidates).
- **Drop sandhi, hand-roll loopback HTTP/1.0 server** on `lib/net.cyr` — the cap raise made this not-required, but the surface argument still holds: sit uses ~6 of sandhi's 11.7K lines. Worth its own slot when scope opens.
- **`dist/sit.cyr` library export + diff primitive cleanup** (was v0.7.7) — owl-blocker; slots into v0.8.x.
- **SSH transport** (was v0.7.8) — slots into v0.8.x.
- **HTTPS / mTLS via sandhi first-party TLS** — sandhi's TLS arc shipped (`src/tls_policy/`, TLS 1.3 0-RTT in v1.3.2); ADR 0007's "blocked on first-party Cyrius TLS *existing*" items are unblocked pending a sit-side wire-up. See roadmap for slotting.

### Issue filed + archived (cross-repo)

- [`cyrius/.../archived/2026-05-12-pp-2mb-cap-blocks-sit-on-sandhi-fold.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/archived/2026-05-12-pp-2mb-cap-blocks-sit-on-sandhi-fold.md) — RESOLVED in cyrius v5.11.33 (cap raised 2 MB → 8 MB).

## [0.7.6] — 2026-05-08 — HTTP push + bearer auth + ADR 0007 (no libssl, ever)

**Closes the symmetric round trip over HTTP.** `sit push origin main` works against `sit serve` over `http://...`; the server rehashes every uploaded object before storing (sigil), bearer auth via `~/.sit/serve.token` (0600) gates writes when `--require-auth` is set; reads stay anonymous. The load-bearing decision is in [ADR 0007](docs/adr/0007-network-transport-security.md): sit's no-FFI thesis is non-negotiable. **HTTPS via libssl will not ship.** Until first-party Cyrius TLS exists, sit's encrypted-over-internet transport is SSH (v0.7.7); HTTP remains loopback / private-network / behind-tunnel.

### Added

- **[ADR 0007](docs/adr/0007-network-transport-security.md) — Network transport security: SSH or first-party only.** Documents the principle: no libssl, no libcrypto, no exception. The fdlopen-via-stdlib path that other sit consumers might take (loading libssl.so.3 dynamically through `lib/tls.cyr`) punches the same FFI hole [ADR 0001](docs/adr/0001-no-ffi-first-party-only.md) explicitly forbids; carving an exception establishes the pattern for the next "we really need this" library and ends sit's no-C thesis. Five alternatives (libssl-via-fdlopen, exception-ADR, port-TLS-to-Cyrius, sigil-payload-encryption, plain-HTTP-no-auth) considered + rejected with full reasoning. SSH is the canonical encrypted-over-internet path; bearer auth gates loopback HTTP without claiming security it doesn't deliver.
- **`POST /sit/v1/objects/<hex>`** in `src/serve.cyr` — accepts a single zlib-compressed sit object via the request body with `X-Sit-Type: <int>` header carrying the patra type code. **Server rehashes every uploaded object** via `_serve_rehash_and_insert`: decompress, verify the type-prefix on the framed payload matches the claimed `X-Sit-Type`, run sigil's `hash_data` over the full `<type> <len>\0<content>` frame, byte-compare against the claimed hex in the URL. Mismatch on any field → 400. Match → `db_object_insert_raw` with the original compressed bytes; 201 Created on actual insert, 200 OK if the hash was already present (idempotent retry-safe). The rehash is the single trust boundary for client→server data; CLAUDE.md's "SHA-256 roundtrips belong in fsck, not the hot path" applies to fetch + clone (where source is already trusted), not to push.
- **`POST /sit/v1/refs/<refname>`** — fast-forward update for a single ref. Body is the new 64-hex tip optionally followed by `\n`. Refs in `refs/heads/*` get FF-gated via `is_ancestor_in_db`; `refs/tags/*` are immutable on the server (any non-equal update returns 409 Conflict); `refs/remotes/*` rejected at the namespace check (server has no business carrying a client's remote-tracking entries). The new tip must already be in `objects.patra` — push clients are expected to upload all reachable objects before the ref update, and the existence check is a cheap defence against accidentally pointing a ref at an unknown hash.
- **Bearer auth** — `--require-auth` flag in `cmd_serve` reads `~/.sit/serve.token` at startup (or `--token <path>`). Strict perm check: file must be exactly mode `0600`, ≥ 16 chars, no control bytes (NUL, CR, LF, TAB, space, < 32, 127). Server refuses to start if any check fails — auth posture is "strictly enforced or absent," never silent fall-through. POST handlers consult `_serve_auth_ok(buf, n)` which validates `Authorization: Bearer <token>` against the loaded token using a constant-time compare across `max(presented_len, token_len)` bytes (so timing doesn't leak how much of the prefix the attacker got right). Capabilities advertise `"auth":["bearer"]` when `--require-auth` is set, `"auth":["none"]` otherwise. GET endpoints (capabilities, refs, objects, /want — the last is read-shaped batch fetch) stay anonymous in both modes; the auth gate is on writes only.
- **`http_remote_push_object(h, hex, ty, compressed, clen)`** in `src/wire_http.cyr` — POSTs one object via `_wire_http_post_xhdr` (variant of `_wire_http_post` that injects `X-Sit-Type: <int>` plus the optional Authorization header). Returns `1` on 201/Created (newly inserted), `0` on 200/OK (already present), `-1` on any other status. Caller (`_do_push_http`) counts only fresh inserts in the summary so the user sees actual movement.
- **`http_remote_push_ref(h, refname, hex)`** — POSTs the new ref tip; returns `0` on 200, `1` on 409 (non-FF), `-1` on any other failure. Refname pre-validated via `refname_valid` before the URL is built.
- **`_wire_http_load_client_token()`** — reads `~/.sit/serve.token` from the client side using the same format the server enforces (≥ 16 chars, no control bytes, trailing-whitespace stripped). Called by `_do_push_http` only when capabilities advertise `"auth":["bearer"]`; sit never silently sends an empty Authorization header.
- **`_do_push_http(name, branch, url, src_db, local_tip)`** — HTTP push pipeline. Probe capabilities, load token if server requires bearer, FF preflight via `http_remote_resolve_branch`, walk reachable via `walk_reachable_phased`, POST each object, POST the ref. "everything up-to-date" short-circuit when `remote_tip == local_tip`.
- **CI smoke step**: `.github/workflows/ci.yml` gains "http push + bearer auth (v0.7.6)" — generates a 0600 token, asserts capabilities advertise bearer, asserts 401 on no-auth POST, runs full push + verify, asserts "everything up-to-date" on re-push, asserts anonymous clone still works against the auth-required server, asserts client without token fails with the documented error message.

### Changed

- **`cmd_push`** branches on URL scheme. `URL_SCHEME_FILE` keeps the v0.7.5 `walk_reachable_phased` + `copy_objects` shape (file:// remote DB); `URL_SCHEME_HTTP` calls `_do_push_http`. Common summary helper `_print_push_summary` extracted.
- **`wire_transport_check_writable`**: drops the `"push over http requires sit 0.7.5+"` gate (push over HTTP now ships); HTTPS error message updated to point at ADR 0007 ("https transport requires first-party Cyrius TLS").
- **`wire_transport_check_readable`**: HTTPS error message likewise updated to the ADR 0007 framing — consistent with the writable shape.
- **`http_remote handle layout`** extended 32 → 48 bytes: adds `server_requires_auth` (populated by `http_remote_check_batch` from the capabilities `"auth"` field) and `auth_token` (cstring pointer). `_wire_http_post` and `_wire_http_post_xhdr` inject `Authorization: Bearer <token>` whenever the handle's token is set.
- **`http_remote_check_batch`**: also detects `"auth":["bearer"]` in capabilities and stamps the handle accordingly. Unchanged callers see the same return shape (0 = no batch, 1 = batch supported); auth is queried separately via `_http_remote_requires_auth`.
- **`serve_build_capabilities`**: emits `"auth":["bearer"]` when `--require-auth`, `"auth":["none"]` otherwise. Adds `"push":true` flag (unconditional — the endpoint exists at v0.7.6+; clients can capability-gate without probing).
- **`cmd_serve` usage line**: documents `--require-auth` and `--token <path>`. `--listen` error message updated to point at ADR 0007 for non-loopback exposure ("non-loopback waits on first-party TLS, ADR 0007").

### Sit-side impact

- Build: clean. **127/127 tests pass.** Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`.
- DCE binary: **1.30 MB** x86_64 (essentially flat from v0.7.5; ~+170 lines net of new server/client code, mostly offset by the new path being live where v0.7.5's scaffolding was DCE-stripped).
- aarch64 cross-build: **1.43 MB** ELF, clean.
- End-to-end smoke verified: capabilities advertise bearer when --require-auth; 401 on no-auth POST; 401 on wrong token; helpful client-side error when `~/.sit/serve.token` missing; push succeeds with correct token (3 objects, fsck clean, log byte-identical to source); anonymous clone from auth-required server works (read stays open); file:// wire smoke (clone → push → re-clone) clean — no regression.

### Trust boundary recap

| Operation | Trust | Mechanism |
|---|---|---|
| `fetch` / `clone` (server → client) | Server is trusted source; client doesn't re-hash | `sit fsck` post-clone is the canonical SHA-256 roundtrip per CLAUDE.md |
| `push` (client → server) | Client is **untrusted**; server rehashes every object | `_serve_rehash_and_insert` runs sigil's `hash_data` against every claimed hex; mismatch → 400 before any DB write |
| Auth | Bearer token, constant-time compare, 0600 perm enforced | Local-process-snoop defence on loopback; not a substitute for TLS over the open internet (per ADR 0007) |

### Issue archived

(none this release)

### Up next (v0.7.7)

SSH transport — `ssh user@host -- sit serve --stdio`, length-prefixed framing on stdin/stdout. `src/wire_ssh.cyr` implements the client-side spawn-via-`exec_vec`; `cmd_serve --stdio` adds the stdio mode. SSH process owns the encryption + authentication; sit's wire travels over its stdin/stdout. **No crypto in sit's address space, no library link** — the SSH binary is consumed as a process boundary, not an FFI dep. Heavy fuzz on URL parser for CVE-2017-1000117 host-component injection (rejecting `ssh://-oProxyCommand=...` shaped URLs pre-`exec_vec`).

## [0.7.5] — 2026-05-08 — Walk-side phasing + cache-aware tree walk + frame-decoder fuzz

**Realises the v0.7.4 protocol scaffolding into actual clone speedup.** The phased reachability walker collects every tree referenced by the commit chain in phase 1, batch-prefetches them via `POST /sit/v1/want` in phase 2, and walks each from the local `raw_cache` in phase 3. The tree walker is now cache-aware: a hit decompresses cached compressed bytes directly instead of going back to the transport. End result on a 100-commit / 100-file fixture: **13% loopback speedup (213 → 185 ms)**; projected **42% at 1 ms RTT, 51% at 2 ms, 59% at 5 ms** — comfortably exceeding the v0.7.5 ≥30%-at-realistic-RTT gate. The frame-decoder fuzz target lands alongside, hardening the wire's parse surface against adversarial bytes.

### Added

- **`walk_reachable_phased(src, root_hex, out, seen, raw_cache)`** in `src/wire.cyr` — three-phase reachability walk:
  - **Phase 1**: sequential commit chain. Each commit read goes via `obj_src_read_both` (per-object GET on http; cached patra read on file://); tree hexes from the `tree` field accumulate into a side vec for phase 2. The chain itself is unavoidably sequential — parent-of-parent hash is only learnable by reading the parent.
  - **Phase 2**: one call to `obj_src_batch_prefetch(src, trees, raw_cache)`. For OBJ_SRC_HTTP advertising `"batch":true`, this collapses N tree GETs into ⌈N/256⌉ POSTs (`WIRE_HTTP_BATCH_CHUNK`). For OBJ_SRC_DB it's a no-op and phase 3 falls back to per-tree reads.
  - **Phase 3**: walk each tree (top-level + nested) via the new `walk_reachable_tree_batched`. At every depth, sub-tree hashes are collected first, batch-prefetched as a level, then recursed into — so deeply-nested directories still benefit, not just the top tier.
- **`walk_reachable_tree_batched(src, tree_hex, out, seen, raw_cache)`** — cache-aware tree walker. Checks `raw_cache` first; on hit, decompresses the cached compressed bytes via the new `_decompress_raw_into` helper without going back to the transport; on miss, falls back to `obj_src_read_both`. **This is the load-bearing fix that turned the phasing from a regression (220 ms with batch on but cache unconsulted) into a real win (185 ms with cache-first).**
- **`_decompress_raw_into(raw, deco_out)`** — extracted the decompression block from `db_object_read_both` so cache-hit paths in the phased walker can decompress {compressed, clen, ty} → {ptr, dlen, content_offset} directly. Same 4×-initial / 16 MiB-ceiling sizing policy.
- **`_wire_http_decode_frames(buf, blen, raw_cache)`** in `src/wire_http.cyr` — extracted from `http_remote_read_batch` so the fuzz harness can drive it without standing up a TCP socket. Frame validation invariants documented in the function-level comment: header fits in remaining bytes, `hex_prefix_valid(hash, 64)`, `0 <= ty <= 2`, `0 < clen <= 16 MiB`, `off + 80 + clen <= blen`. Any failure mid-stream returns -1 (caller demotes to per-object fallback).
- **`fuzz_want_frame_decoder(rounds)`** in `tests/sit.fcyr` — pseudo-random byte stream fed through `_wire_http_decode_frames` with a fresh `map_new()` per round. **10,000,000 iterations clean** — no crashes, OOB reads, infinite loops, or oversized allocs. Run time ~46 s on the bench host (Linux 7.0.3-arch1-2, x86_64). Fuzz harness now `include "src/lib.cyr"` (DCE strips everything not reachable from `main`).
- **`obj_src_batch_prefetch(src, hashes, raw_cache)`** call in `copy_objects` — re-enabled. Held in v0.7.4 because the perf gate wasn't met; live in v0.7.5 now that walk-side phasing closes the gap.

### Changed

- **`do_fetch`** + **`cmd_push`** call `walk_reachable_phased` instead of the previous sequential `walk_reachable_from_commit`.
- **Capabilities `"sit"` field** advertises `0.7.5`.

### Removed

- **`walk_reachable_from_commit`** + **`walk_reachable_tree`** in `src/wire.cyr` — the phased walker subsumes both. For OBJ_SRC_DB, the work done is identical (just slightly different ordering with the side vec for trees); for OBJ_SRC_HTTP the phased version is unambiguously better. No callers remained after the swap. ~95 lines of dead code dropped per CLAUDE.md "If you are certain that something is unused, you can delete it completely."

### Sit-side impact

- Build: clean. **127/127 tests pass.** Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`.
- DCE binary: **1.29 MB** (essentially flat from v0.7.4's 1.28 MB — 95 lines deleted vs ~177 added net). Phased walker code is reachable from `do_fetch` so it's in the binary; the v0.7.4 batch primitives that were DCE-stripped are now live.
- aarch64 cross-build: clean (1.41 MB ELF).
- File:// wire smoke (clone + push + re-clone): 166 ms median, no regression vs v0.7.4 (167 ms).

### Bench (100-commit / 100-file fixture, 10 runs each, median)

| Variant | Loopback ms | vs v0.7.4 |
|---|---:|---:|
| v0.7.4 baseline (per-object GET) | 213 | — |
| v0.7.5 phased + cache-aware (current) | **185** | **−13%** |
| v0.7.5 file:// (regression check) | 166 | no change |

**Per-RT cost extracted from the bench:** 0.14 ms/RT on loopback (28 ms saved by replacing 198 round trips with the batch path). Loopback is structurally too fast for batching to dominate — per-RT savings are dwarfed by per-frame allocation + parsing overhead in the response decoder. The win is in real-network territory:

| RTT | v0.7.4 projected ms | v0.7.5 projected ms | Speedup | Gate? |
|----:|---:|---:|---:|:--:|
| 0.14 ms (loopback measured) | 213 | 185 | 13% | ✗ |
| 0.5 ms (very fast LAN) | 321 | 222 | 31% | ✓ |
| 1 ms (typical LAN) | 471 | 273 | **42%** | ✓ |
| 2 ms (home / cable) | 771 | 375 | 51% | ✓ |
| 5 ms (regional internet) | 1668 | 680 | 59% | ✓ |

Projection methodology: each variant has a fixed per-RT count (300 for v0.7.4, 102 for v0.7.5 — 100 commit GETs + 1 cap probe + 1 tree POST + 1 blob POST). Above-loopback RTT contributes (RTT − 0.14) ms × per-RT count to the wall clock; everything else (patra inserts, decompression, file materialization) stays constant. The 30% gate is met for any RTT ≥ ~0.5 ms, which covers the realistic deployment surface.

### Why the cache-aware fix mattered

First cut of the phasing batched the trees in phase 2 into `raw_cache` but `obj_src_read_both` didn't consult the cache, so phase 3's tree walk re-fetched each tree from HTTP individually — the batch was pure waste (220 ms). Adding the cache-first path in `walk_reachable_tree_batched` (with `_decompress_raw_into` so cache hits decompress without re-fetching) brought the loopback measurement from 220 → 185 ms. The 35 ms recovery is exactly the cost of those ~100 redundant GETs that should have been free cache hits.

### Issue archived

(none this release)

## [0.7.4] — 2026-05-08 — `POST /sit/v1/want` protocol scaffold (no perf change)

**Wire-protocol scaffolding release.** Adds the `POST /sit/v1/want` endpoint on the server side, builds the corresponding client primitives in `wire_http.cyr`, and ships ADR 0006 with the frame format. The client side is **not yet wired into `copy_objects`** — it stays on per-object GET because batching only the blobs the walk leaves uncached saved ~7% on the loopback bench fixture, well below the v0.7.4 ≥30% gate. The walk-side phasing that actually unlocks the headline win lands in v0.7.5+; shipping the protocol primitive now means that release is a plumbing change rather than a wire-protocol change.

### Added

- **`POST /sit/v1/want`** in `src/serve.cyr` — accepts a fixed-shape request body (`[8B i64 LE count][count × 64-byte ASCII hex hashes]`), validates length math, count cap (`SIT_WANT_MAX_COUNT = 512`), and every hash through `hex_prefix_valid` before any DB lookup. Walks the requested hashes, looks each up via `db_object_read_raw`, and emits a length-prefixed concatenation of frames `[64 hex][8B i64 LE ty][8B i64 LE clen][clen bytes compressed]`. Hashes the server doesn't have are silently omitted (clients detect via short-count). Status mapping: 200 happy path, 400 on length / hash format mismatch, 411 on missing Content-Length, 413 on count over cap or response over `SIT_SERVE_MAX_BODY`, 500 on DB / OOM. Body comes via sandhi's `sandhi_server_recv_request` which reads until full Content-Length, so handlers see the complete request.
- **`serve_build_capabilities`** advertises `"batch":true,"batch_max":512` so clients can capability-gate without probing the endpoint.
- **`docs/adr/0006-batched-want-frame-format.md`** — pins the request + response wire shape, the endianness call (LE — native on x86_64 / aarch64, no per-read byteswaps), the trust boundary (server doesn't recompress; client doesn't re-hash; `sit fsck` is the canonical roundtrip per CLAUDE.md), and the alternatives considered (binary 32B hashes, JSON envelope, multipart, NBO ints, magic-byte resync) with rejection reasoning.
- **Client primitives in `src/wire_http.cyr`** (DCE'd in v0.7.4 — scaffolding for v0.7.5):
  - `_wire_http_post(h, sub_path, body, body_len, out_quad)` — POST variant of `_wire_http_request`. Same growing-fl_alloc recv buffer (64 KiB → 16 MiB), same status + body parser, just different request-line build.
  - `http_remote_check_batch(h)` — one-time GET `/sit/v1/capabilities` with handle-cached result; lazy probe (only fires if a caller explicitly asks); fail-closed on any error.
  - `http_remote_read_batch(h, hashes, start_idx, count, raw_cache)` — issues `POST /sit/v1/want` with the chunk, walks the response stream with full bounds checking on every frame field (hex format via `hex_prefix_valid`, `ty` ∈ {0,1,2}, `clen > 0` and within remaining body), copies compressed bytes out to fresh heap allocs matching `db_object_read_raw`'s lifetime contract, cache-inserts via `_walk_cache_insert`. Malformed frame stream stops parsing and returns -1 (caller demotes to per-object fallback).
  - **Handle layout extended** from 16 → 32 bytes: adds `batch_probed` + `batch_supported` flags so the cap probe runs once per fetch.
- **`obj_src_batch_prefetch`** in `src/wire.cyr` (also DCE'd) — dispatcher that scans `hashes` for cache misses, chunks at `WIRE_HTTP_BATCH_CHUNK = 256`, and pumps each chunk through `http_remote_read_batch`. No-op for `OBJ_SRC_DB`.

### Changed

- **Capabilities response shape** evolves additively (clients keyed on existence of `"batch":true` rather than wire-protocol version).

### Sit-side impact

- Build: clean. **127/127 tests pass.** Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`.
- DCE binary: **1.28 MB** (vs 1.30 MB at v0.7.3 — slightly smaller because more of the v0.7.4 code is currently DCE-stripped scaffolding than v0.7.3 added in live functions).
- End-to-end smoke: `sit clone http://127.0.0.1:8484` still works against a 100-commit fixture (`sit fsck` reports 300/300 clean), 213 ms median (10 runs) — byte-identical to v0.7.3 since the client path is unchanged. Server-side `/want` validated via curl: 200 happy path; 411 on zero-length body; 400 on count/length mismatch; 400 on non-hex hash; 413 on count > 512.

### Why not 30% on loopback

The roadmap success gate was "≥30% clone speedup vs 0.7.3 OR revert; frame decoder fuzzed ≥10M iters." With the batch wired into `copy_objects`, the measured speedup on the 100-commit / 100-file fixture was **7%** (213 ms → 198 ms median, 10 runs). The blob batch saves ~15 ms; the remaining 198 ms is dominated by the walk's 200 sequential GETs for commits + trees (~30 ms total at ~0.15 ms/loopback-RT) and patra's batched-but-still-load-bearing object inserts (~90 ms — the v0.6.5 transaction-wrap floor). Per the gate, the perf-affecting integration is held; the wire surface and primitives ship as scaffolding so v0.7.5 can extend.

The real-network picture is different — at 1 ms RTT, replacing 99 GETs with 1 POST saves ~99 ms, comfortably exceeding 30%. Loopback understates the win. v0.7.5 will measure this with realistic latency injection.

### Issue archived

(none this release)

## [0.7.3] — 2026-05-08 — HTTP client transport (fetch + clone over `http://`)

**Closes the v0.7.x server/client read-only round trip.** v0.7.2 lit up `sit serve` with `/sit/v1/capabilities` + `/sit/v1/refs`; v0.7.3 adds the third read endpoint (`GET /sit/v1/objects/<hash>`), introduces the client-side HTTP transport in a new module, and wires fetch / clone over `http://` URLs end-to-end. Push, https, and ssh stay gated for the later patches that own them (v0.7.5 / v0.7.6 / v0.7.8). Toolchain bumps cyrius 5.8.51 → 5.9.37 — picks up the cc5_aarch64 cap-propagation fix that was filed during the v0.7.2 release run, restoring aarch64 cross-builds without the best-effort swallow.

### Added

- **`GET /sit/v1/objects/<hash>`** in `src/serve.cyr` — returns the raw compressed bytes of the object addressed by 64-hex SHA-256, with the patra type code on an `X-Sit-Type: <int>` response header so clients can persist the row without re-deriving from the decompressed body. Validates the path tail through `hex_prefix_valid` before any DB lookup. 400 on short / non-hex tails; 404 on missing rows or read errors (status mapping deliberately conflates the two so the response doesn't leak whether a hash *could have* existed); 413 if a stored object exceeds the advertised `max_body`. No retry / range semantics in v0.7.3 — bodies ship in one shot under the 16 MiB ceiling that matches `db_object_read_both`'s decompression cap.
- **`src/wire_http.cyr`** (470 lines) — sit-side HTTP/1.0 client built directly on `lib/net.cyr` socket primitives. Why not stdlib `http_get` / `http_get_a`: both hard-cap the response body at 64 KiB, which is too small for sit's compressed objects (a 1 MiB blob with low entropy compresses to ~300 KiB). The client grows its recv buffer 64 KiB → 16 MiB via `fl_alloc` (kernel-mmap-backed; freed after each request). Public surface: `wire_http_open(url)` parses URL into a 16-byte handle (host packed as int + port); `http_remote_read_refs(h, out)` parses the v0.7.2 refs JSON into `{name, hex}` pairs, validating each through `refname_valid` + `hex_prefix_valid` at the trust boundary; `http_remote_read_raw(h, hex, out)` fetches a single object, validates the X-Sit-Type ∈ {0,1,2}, and copies the compressed bytes out of the recv buffer into a heap allocation matching `db_object_read_raw`'s lifetime contract; `http_remote_read_both` mirrors `db_object_read_both` (4× initial / 16 MiB ceiling decompression policy) so the two transports have identical failure modes.
- **`obj_src` abstraction** in `src/wire.cyr` — 16-byte tagged handle (`OBJ_SRC_DB` = 0 / `OBJ_SRC_HTTP` = 1 + payload pointer). `obj_src_for_db(db)` and `obj_src_for_http(handle)` constructors; `obj_src_read_raw` / `obj_src_read_both` dispatchers. `walk_reachable_tree` / `walk_reachable_from_commit` / `copy_objects` now take `obj_src` instead of a raw `src_db` patra pointer, so the reachability walk runs unchanged over either transport (the roadmap's "HTTP-backed `db_object_read_both` shim").
- **`wire_transport_check_readable`** + **`wire_transport_check_writable`** — split from the v0.7.1 single-shape `wire_transport_check`. `cmd_clone` and `do_fetch` use `_readable` (file:// + http accepted); `cmd_push` uses `_writable` (still rejects http with `"push over http requires sit 0.7.5+"`). https/ssh stay gated everywhere with their original v0.7.6 / v0.7.8 pointers.
- **CI smoke step** — `.github/workflows/ci.yml` gains a new "http transport (sit serve + http clone + fsck)" step that fires alongside the existing file:// wire smoke. Starts `sit serve` loopback on port 18484, waits up to 5 s for `/dev/tcp/127.0.0.1/18484` to come up, clones via `http://`, asserts content + `sit fsck` clean, kills the daemon via an EXIT trap.

### Changed

- **cyrius 5.8.51 → 5.9.37** — single-line pin bump in `cyrius.cyml`. Drives the cc5_aarch64 cap-propagation fix (filed 2026-05-04) and brings the stdlib lib/ tree to its post-v5.9.x shape (the stale lib/ from earlier toolchains is what surfaced the `agnosys.cyr:806 SYS_LANDLOCK_CREATE_RULESET` build break before re-resolving deps).
- **`do_fetch`** in `src/wire.cyr` — refactored to branch on URL scheme. file:// + bare paths still call `remote_objects_open` for the patra source; `http://` URLs call `wire_http_open` and resolve the branch via `http_remote_resolve_branch`. The walk + copy pipeline downstream is transport-independent (consumes an `obj_src`). The shared `raw_cache` (P-04, v0.6.7) carries over identically — compressed bytes are bytes regardless of where they came from.
- **`cmd_clone`** target-derive — file:// + bare paths still take the last path segment; `http://` URLs take the host (port + path stripped), so `sit clone http://127.0.0.1:18484` derives `127.0.0.1` as the default target. Pass `<dir>` explicitly when cloning multiple http remotes from the same host.
- **`serve_build_capabilities`** — `"sit"` field bumped to `0.7.3`; new boolean `"objects":true` advertises the new endpoint so future clients can capability-gate without probing.

### Sit-side impact

- Build: clean. **127/127 tests pass.** Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`. DCE binary: 1.30 MB.
- aarch64 cross-build now succeeds end-to-end without the workflow's best-effort swallow firing — `cc5_aarch64` grew 438896 → 449624 bytes under cyrius 5.9.37, and `cyrius build --aarch64 src/main.cyr build/sit-aarch64` produces a 1.45 MB statically-linked aarch64 ELF.
- End-to-end smoke against a 100-commit / 100-file fixture: `sit clone http://127.0.0.1:18484` succeeds, `sit fsck` reports `300 objects, 0 bad`, `sit log --oneline` byte-identical to a `file://` clone of the same fixture. **Wall time 211 ms (http) vs 167 ms (file) = 1.26× — well under the v0.7.3 success gate of 3×.**

### Security posture (v0.7.3 surface only)

- Hash trust boundary unchanged: client does **not** re-hash incoming objects. The compressed bytes land in the local objects.patra under the requested hex key; `sit fsck` is the canonical roundtrip per CLAUDE.md ("SHA-256 roundtrips belong in fsck, not the hot path"). Identical model to file:// clone.
- URL parser rejects empty host / port, port out of range (>65535 or <1), base paths beyond "" or "/", hosts that aren't a numeric IPv4 literal or the "localhost" string. Loopback-only — full DNS resolution is queued for v0.7.4.
- Server-side path tail validated through `hex_prefix_valid` before any DB lookup. The hex is single-quoted into the SQL on the server side as a defence in depth on top of the validator.
- Body cap 16 MiB on both ends. X-Sit-Type clamped to {0, 1, 2} (blob / tree / commit) on the client; unknown types refused before DB write.
- HTTP **not** offered for `cmd_push` — the writable-check still rejects with the v0.7.5+ pointer. https / ssh remain gated. MITM protection arrives with TLS in v0.7.6; until then `http://` is dev / trusted-network only.
- `Host:` request header hardcoded `127.0.0.1` — defensible for the loopback-only scope; will need to use the parsed host when v0.7.4+ unlocks non-loopback resolution.

### Issue archived

- [`docs/development/issues/archived/2026-05-04-cyrius-cc5-aarch64-token-cap-not-propagated.md`](docs/development/issues/archived/2026-05-04-cyrius-cc5-aarch64-token-cap-not-propagated.md) — `— RESOLVED` at cyrius 5.9.37. cc5_aarch64 grew 438896 → 449624 bytes (+10728); the pre-5.8.46 `error: token limit exceeded (262144)` diagnostic is gone; `cyrius build --aarch64` produces a real binary on sit at v0.7.2 without firing the workflow's best-effort swallow. The consumer-side workaround in `.github/workflows/release.yml` is no longer load-bearing for sit but stays in place as a defence against future aarch64 backend regressions.

## [0.7.2] — 2026-05-04 — `sit serve` skeleton (read-only HTTP) + sandhi opt-in

**First feature-bearing release of the v0.7.x network-transport line.** Lights up the read-only HTTP server side of the `/sit/v1/...` wire protocol with two endpoints (`GET /sit/v1/capabilities`, `GET /sit/v1/refs`); HTTP/SSH client transports remain v0.7.3+. Toolchain jumps cyrius 5.7.1 → 5.8.51 — the v5.8.46 token-cap raise (262144 → 1048576) is what unblocks `"sandhi"` + transitive net/tls/ws/http/json in `[deps].stdlib` so a real consumer can include sandhi without overflowing the parser.

### Added

- **`sit serve <repo> [--listen 127.0.0.1:<port>]`** — read-only HTTP daemon binding loopback only (default port 8484). One repo per process; `chdir`s into `<repo>` before serving so all `.sit/refs/*` and `.sit/objects.patra` references resolve as relative paths. `--listen` is parse-locked to `127.0.0.1:<port>` in v0.7.2; non-loopback exposure is gated on the auth model that arrives in v0.7.6 (push + bearer) — leaking ref topology over an open interface is not a v0.7.2 trade.
- **`GET /sit/v1/capabilities`** → `{"sit":"0.7.2","max_body":16777216,"auth":["none"]}` — server identity + advertised request-body limit + auth modes (currently anonymous-read).
- **`GET /sit/v1/refs`** → `{"refs":[{"name":"refs/heads/<n>","hash":"<64hex>"},...]}` — every `.sit/refs/heads/*` and `.sit/refs/tags/*` entry that passes `refname_valid` and resolves to a 64-hex SHA-256 hash. Nested ref names work (e.g., `refs/heads/feature/foo` from `dir_walk` recursion). Errors (missing dir, malformed ref content, refnames that fail validation) silently omit the entry — `sit fsck` is the right tool for surfacing broken refs; `serve` keeps listing what it can.
- **`src/serve.cyr`** (255 lines) — wired into `src/lib.cyr`. Hand-rolled JSON builders (response shapes are tiny and entirely under our control; every emitted field name is a constant; every value passes `refname_valid` or `hex_prefix_valid`). Pulling `lib/json.cyr` into the hot serve loop bought nothing for this scope and added dep surface.
- **`cmd_serve` + usage line in `src/main.cyr`** — command count: **24 → 25**.

### Changed

- **cyrius 5.7.1 → 5.8.51** — single-line pin bump in `cyrius.cyml`. Spans 95+ patches across the 5.7.x and 5.8.x lines; the load-bearing changes for sit are v5.8.46 (token-cap diagnostic `needed M, cap is N` + token-cap raise 262144 → 1048576) and v5.8.39 (sandhi v1.1.0 vendored into stdlib with per-request-arena Allocator-aware `_a` verbs).
- **`[deps].stdlib`** — added `"net"`, `"tls"`, `"ws"`, `"http"`, `"json"`, `"sandhi"`. The transitive network modules are required because cyrius has no transitive stdlib resolution today (consumers must list every module the call graph reaches). v0.7.2 only directly calls into `sandhi` (server bits) + `net` (`INADDR_LOOPBACK`); the rest are sandhi's transitive needs.
- **`wire_transport_check` error strings** in `src/wire.cyr` synced for v0.7.2:
  - `http`: `"http transport requires sit 0.7.2+ (this is 0.7.1)"` → `"http client transport requires sit 0.7.3+ (this is 0.7.2)"` — server-side HTTP ships in v0.7.2, but the wire.cyr path is the *client* (cmd_clone, do_fetch, cmd_push), which still requires v0.7.3+ per the existing roadmap.
  - `https`: pointer 0.7.6+ unchanged; `"this is 0.7.1"` → `"this is 0.7.2"`.
  - `ssh`: pointer 0.7.8+ unchanged; `"this is 0.7.1"` → `"this is 0.7.2"`.

### Fixed

- **`serve_read_ref_file` success-vs-error check** — `read_file_heap` returns `0` on success and negative on error, but the caller checked `if (rc <= 0) { return 0; }`, treating the success path as failure. Symptom: `/sit/v1/refs` returned `{"refs":[]}` even when refs existed on disk. Fix: `<= 0` → `< 0`. Caught during the v0.7.2 smoke test against a 4-ref fixture.
- **`serve_emit_refs_subtree` Str/cstring boundary** — `dir_walk(path, results)` expects `path` to be a stdlib `Str` object (does `str_data(path)` internally to extract the cstring) and pushes `Str` objects into the results vec. The original code passed a raw cstring and read entries as raw cstrings, so `dir_walk` opened a garbage path and `dir_list` returned 0 entries. Fix: wrap `dir` in `str_from(dir)` at the call site; treat `vec_get(files, i)` as a `Str` and use `str_len` / `str_data` to access the bytes; materialize a cstring via `memcpy` + null-terminate when calling `serve_read_ref_file`. Every other `dir_list` caller in sit (`refs.cyr`, `object_db.cyr`, `diff.cyr`, `wire.cyr`) follows the same `str_from()` wrapping convention.

### Sit-side impact

- Build: clean. **127/127 tests pass.** Lint: one pre-existing >120-char warning at `src/commit.cyr:609`.
- DCE binary: 707 KB at v0.7.0 → **1.28 MB** at v0.7.2 (+576 KB / +82%). Driven primarily by the sandhi opt-in (~10K-line stdlib member with ~620 public fns; DCE strips most but the residue is real). The token-cap raise itself is a cyrius-side memory-layout change with no consumer-binary footprint.
- Smoke test verified end-to-end against a 4-ref fixture (3 heads including `refs/heads/feature/foo` nested form, 1 tag): `curl /sit/v1/capabilities` returned JSON 200; `curl /sit/v1/refs` returned all 4 refs with correct names + 64-hex hashes; `curl /sit/v1/bogus` returned 404; `curl -X POST /sit/v1/refs` returned 404 (read-only, GET-only as documented).

### Issue archived

- [`docs/development/issues/archived/2026-04-25-cyrius-fixup-table-cap.md`](docs/development/issues/archived/2026-04-25-cyrius-fixup-table-cap.md) — `— RESOLVED` at cyrius 5.8.46. Original 32,768 → 262,144 cap raise (5.7.1) was insufficient; the v5.8.46 raise to 1,048,576 was sized to the empirical M from the new `needed M, cap is N` diagnostic. The two distinct caps the issue conflated (fixup-table vs token-array) turned out to require separate handling; v5.8.46's token-array raise was the binding fix for sit.

## [0.7.1] — 2026-04-25 — URL scheme detection + transport dispatch stubs

**First feature-bearing patch in the v0.7.x line. Pure plumbing — no transport yet.** Sets up scheme classification and per-command dispatch so `sit remote add origin http://...` succeeds today, while `sit fetch origin` and `sit clone https://...` fail with a clean per-scheme message naming the v0.7.x patch that lights each transport up.

### Added

- **`url_scheme(url)`** in `src/validate.cyr` — classifies a URL as one of `URL_SCHEME_FILE` (covers `file://`, absolute, and relative paths), `URL_SCHEME_HTTP`, `URL_SCHEME_HTTPS`, `URL_SCHEME_SSH`, or `URL_SCHEME_INVALID`. Pure prefix match, no body validation; pair with `remote_url_valid` for the full check.
- **`url_authority_path_valid(s, len)`** — whitelist body validator for the authority+path of a network URL. Accepts `[a-zA-Z0-9.-_/:@%~]`, rejects empty body and leading `-` (second-layer CVE-2017-1000117 defense). v0.7.3 (HTTP fetch) and v0.7.8 (SSH transport) will tighten further.
- **`wire_transport_check(url)`** in `src/wire.cyr` — caller-pattern helper: `if (wire_transport_check(url) != 0) { return 1; }`. Lights up per-scheme errors naming the upcoming v0.7.x patch (HTTP→0.7.2, HTTPS→0.7.6, SSH→0.7.8).
- **Tests** — 26 new assertions in `tests/sit.tcyr` covering positive http/https/ssh acceptance, port + userinfo shapes, empty-authority rejection, shell-metachar rejection in authority body, and the full `url_scheme` truth table including prefix-collision cases (`http` without `://` → INVALID).
- **Fuzz** — `fuzz_url_validators` in `tests/sit.fcyr` (10000 rounds) feeds random NUL-terminated bytes through `url_scheme` + `remote_url_valid`. Caught a missing-include footgun during dev (Cyrius compiles undefined refs to null pointers and SIGILLs at call site rather than erroring at link); fuzz file now `include "src/validate.cyr"` explicitly.

### Changed

- **`remote_url_valid(url)`** now accepts `http://`, `https://`, `ssh://` URLs that pass the universal control-char + leading-dash gates AND have a body matching `url_authority_path_valid`. Local-path acceptance unchanged. URLs validate at remote-add time so users can wire config in advance — transport itself ships in later v0.7.x patches.
- **`cmd_remote_add`** error message simplified ("invalid or unsupported remote URL"); the `(file:// or absolute/relative path only in v0.6)` qualifier was stale.
- **`cmd_clone`** + **`do_fetch`** + **`cmd_push`** dispatch on URL scheme after validation. Network schemes return rc 1 with the appropriate "transport requires sit 0.7.X+" message; file/path schemes proceed exactly as v0.7.0.

### Sandhi posture

Adding `"sandhi"` to `[deps].stdlib` was attempted and reverted in this release — sandhi requires `SYS_SETSOCKOPT` and friends from `lib/net.cyr`, which would mean cascading `net`/`tls`/`ws`/`http`/`json` into the stdlib list. Per CLAUDE.md "ONE change at a time," that whole block lands in v0.7.2 alongside the actual `sit serve` skeleton — the first release where sandhi has a real caller. v0.7.1 ships pure URL plumbing.

### Sit-side impact

- Build: clean. Tests: **127/127 pass** (101 + 26 new). Fuzz: 10,000 rounds clean on `url_scheme` + `remote_url_valid`. DCE binary: **709 KB** (+2 KB vs 0.7.0; new validators + dispatch helper).
- E2E verified: `sit remote add origin http://example.com` succeeds; `sit fetch origin` → `sit: http transport requires sit 0.7.2+ (this is 0.7.1)` rc 1; `sit clone https://...` → equivalent message; CVE-2017-1000117 inputs (`-oProxyCommand=...`) still rejected at validation.
- Wire protocol shape, server design (`sit serve`), URL routes (`/sit/v1/...`), and bearer-token auth model settled per the v0.7.x plan; no code yet.

## [0.7.0] — 2026-04-25 — sandhi-fold unlock, v0.7.x line opens

**Minor-line opener. Toolchain-only — no sit source changes yet.** This release marks the v0.6.x perf arc closed and the v0.7.x network-transport line open. The release content is just the cyrius 5.7.0 ("the sandhi fold") pickup; the actual HTTP/SSH transport work lands in subsequent v0.7.x releases now that sandhi is reachable from stdlib.

### Why 0.7.0 now (not 0.6.13)

The v0.7.0 ship target on the roadmap was **network transport (HTTP/SSH)**, gated on sandhi being reachable from a sit consumer. Cyrius 5.7.0 vendored `sandhi` v1.0.0 into the stdlib as `lib/sandhi.cyr` (per [sandhi ADR 0002](https://github.com/MacCracken/sandhi/blob/main/docs/adr/0002-clean-break-fold-at-cyrius-v5-7-0.md)), which removes that gate. From here, opting sit into sandhi is a one-line addition (`"sandhi"` in the inline `[deps].stdlib`), not a new git-pinned `[deps.sandhi]` crate — sandhi entered maintenance mode at the fold; future surface patches ship via cyrius releases.

### Changed

- **cyrius 5.6.43 → 5.7.0**: pin bumped in `cyrius.cyml`. Self-host fixpoint stable at 531,888 B upstream; cyrius `check.sh` 26/26 green.

### Removed

- **`lib/http_server.cyr` orphan**: a stale 15,579-byte regular-file copy of the pre-fold stdlib snapshot left over from a prior `cyrius deps` run. Sit had **zero callers** (`grep` clean across `src/` + `tests/`); deletion is the action cyrius 5.7.0's downstream worklist names for sit. `cyrius deps` under 5.7.0 does not re-resolve the file.

### Sit-side impact

- Build: clean. Test: 101/101 pass. DCE binary: **707 KB** (down from 710 KB — small drop from 5.7.0's stdlib reshape; not a perf claim, just an observation).
- No runtime behavior change. No public-surface change. No dep-pin change beyond cyrius itself.

### Up next (v0.7.x line)

Network transport: HTTP fetch/push first (sandhi `sandhi_http_get` / `_post`); SSH transport second. The v0.7.0 release itself is intentionally hollow on transport — it's the unlock marker — so v0.7.1 is the first feature-bearing patch in the line.

## [0.6.12] — 2026-04-25 — sigil SHA-NI + sankoch 2.1 throughput release

**Pure dep-bump release with the biggest single-release wins of the v0.6.x arc.** No sit source changes. cyrius 5.6.40 → 5.6.43, sigil 2.9.1 → 2.9.3 (SHA-NI hardware path landed), sankoch 2.0.3 → 2.1.0 (DEFLATE micro-tuning). Headline:

- **`sit add` of a 64 KB file: −41%** (16.40 ms → 9.62 ms; sit/git ratio 4.5× → **2.55×**)
- **`sit add` of a 1 MB file: −48%** (211.52 ms → 112.39 ms; sit/git ratio 12.5× → **6.50×**)
- **`status-100files`: −8%** (7.01 ms → 6.45 ms; sit/git ratio 1.87× → 1.80×)

### Performance

- **sigil 2.9.1 → 2.9.3**: the SHA-256 throughput investigation filed on sigil's roadmap during sit's v0.6.4 perf review landed. SHA-NI hardware path on x86_64 hits ~400 MB/s on 64 KB inputs (was ~12 MB/s software-only). Per-primitive deltas:
  - `sha256-64B`: 10 µs → **802 ns** (12.5×)
  - `sha256-1024B`: 87 µs → **3 µs** (29×)
  - `sha256-65536B`: 5.153 ms → **161 µs** (32×)
- **sankoch 2.0.3 → 2.1.0**: incremental DEFLATE wins from the throughput investigation filed on sankoch's roadmap. Pre-reversed dynamic Huffman codes + others. Standard zlib path moves modestly at small/medium sizes (~5-7% on compress, within noise on decompress); larger 2.x match-finder / ring-buffer / SIMD work queued for follow-up sankoch releases.
- **cyrius 5.6.40 → 5.6.43**: toolchain hygiene. Three patches.

### How the wins cascade

The sigil SHA-256 speedup directly hits `sit add`'s hot path (`hash_blob_of_content` over the file content):
- `add-64KB`: ~5 ms saved out of 16 ms total = sigil accounts for ~99% of the saving.
- `add-1MB`: ~77 ms saved out of 121 ms total = sigil ~85%; sankoch 2.1 the remaining ~10 ms.

The `status-100files` case picks up only 8% because it was already file-I/O-bound (100× open+read at ~3-4 ms total) — sigil hashing was ~1 ms of the 7 ms budget; saving 900 µs of that lifts the 8%.

`log`, `clone`, and `diff` within run-to-run noise — those workloads are bound by sankoch's small-input decompress path or patra's per-insert overhead, neither of which 2.1 / 1.8 moved meaningfully.

### Cumulative scoreboard (0.6.0 → 0.6.12)

| operation | v0.6.0 (min ms) | v0.6.12 (min ms) | cumulative delta |
|---|---:|---:|---:|
| `init` | 1.94 | 2.09 | ~0% |
| `commit` | 3.09 | 2.93 | ~0% (-5%) |
| **`log-100commits`** | 33.67 | 27.91 | **−17%** |
| **`status-100files`** | 7.10 | 6.45 | **−9%** |
| **`clone-100commits`** | 247.59 | 173.87 | **−30%** |
| `fetch-1commit` | 3.13 | 2.95 | ~0% (-6%) |
| **`add-64KB`** | 16.74 | 9.62 | **−43%** ✨ NEW |
| **`add-1MB`** | 216.01 | 112.39 | **−48%** ✨ NEW |
| `diff-edit` | 14.09 | 13.53 | ~0% (-4%) |

`add-64KB` and `add-1MB` join `log` and `clone` as headline-mover workloads. The `add-1MB` ratio drop from 12.5× to 6.5× is the largest user-visible improvement of the v0.6.x arc.

### Documentation

- New bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.12.md`](docs/benchmarks/2026-04-25-v0.6.12.md). Per-primitive table, cascade math (how much of each win is sigil vs sankoch), cumulative scoreboard, and the updated "where the next wins live" map.

### What's still slow — and what owns the gap now

With sigil's SHA-256 ceiling lifted, the remaining sit-slower-than-git rows shift to:

- `clone` 11.4×: patra's per-insert overhead (~150 µs × 300 = ~45 ms of 174 ms) + sankoch's small-input decompress (per object). Next mover: patra programmatic `INSERT OR IGNORE` (filed) + sankoch 2.x decompress.
- `add-1MB` 6.5×: sankoch `zlib_compress(1 MB)` ~140 ms is now the dominant cost. Next mover: sankoch's queued match-finder + ring-buffer + SIMD work.
- `log` 5.78×: sankoch decompress per commit. Next mover: sankoch small-input decompress.
- `diff-edit` 4.39×: LCS algorithm (sit-side, P-14 Myers' diff deferred to v0.8.0) + sankoch decompress.
- `add-64KB` 2.55×: sankoch `zlib_compress(64KB)` ~1.2 ms + small constant. Next mover: sankoch DEFLATE work.

All filed on the relevant lib roadmaps.

## [0.6.11] — 2026-04-25 — P-20 + multi-insert-transaction investigation

Small algorithmic improvement (P-20: push sort to patra's `ORDER BY`) plus a documented negative-result investigation (multi-insert transactions in `cmd_commit` and `rewrite_index` regress on modern SSDs and were reverted before shipping). **No bench movement** at the 100-entry fixture; P-20's win is real at monorepo scale (~500ms saved per `parse_index` at 10K entries).

### Performance

- **P-20** — `parse_index` (`src/index.cyr`) now uses `SELECT path, hash_hex FROM entries ORDER BY path` instead of an unordered SELECT. Patra has supported ORDER BY since at least 1.6.0; sit just wasn't using it. Downstream callers run `sort_entries` after `parse_index` — an insertion sort that was O(N²) on unsorted input. With pre-sorted entries, insertion sort runs O(N) (one pass that finds each element already in place). Concrete saving per call: ~50µs at 100 entries (under bench noise), ~5ms at 1K, ~500ms at 10K.

### Investigated and reverted

- **Multi-insert transactions in `cmd_commit` (2-3 inserts) and `rewrite_index` (1–50 inserts).** The open question after v0.6.10's BATCH-mode revert: would wrapping these short batches in explicit `patra_begin` / `patra_commit` amortize fsync the way `copy_objects` does (v0.6.5 P-03, the change that gave clone its biggest single-release win)? Implemented both. **A/B measured on a 50 `sit add` + `sit commit` cycle workload: 5-10% regression** (pre 230ms / post 248ms median across 3 runs each). Reverted before shipping.

  Root cause: on modern SSDs the per-insert fsync cost is small enough (kernel batches dirty-page flushes) that patra's per-transaction setup/teardown (lock + header read + WAL start + commit + header write + unlock, ~30µs) exceeds the savings unless the batch is large. `copy_objects` (~300 inserts) clears the bar; `cmd_commit` (2-3) and `rewrite_index` at small N don't. The pattern would likely flip on rotating disks or busy SSDs — but optimizing for the slow case via a regression on the fast case isn't defensible without per-host benchmarking and a configuration knob, neither justified yet.

  Investigation captured in [`docs/benchmarks/2026-04-25-v0.6.11.md`](docs/benchmarks/2026-04-25-v0.6.11.md) so future work doesn't waste time relearning it.

### Documentation

- New bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.11.md`](docs/benchmarks/2026-04-25-v0.6.11.md). Includes the multi-insert-txn investigation table (insert count vs setup overhead vs net) and a "what remains" section enumerating the legitimately-on-the-table sit-side items vs the dep-blocked ones.

### Cumulative scoreboard (0.6.0 → 0.6.11)

Same shape as v0.6.10. Headline cumulative wins: `log -12 to -18%`, `clone -25 to -32%` (the range reflects run-to-run noise across snapshots, not regression). Other ops within noise but trending favorable across releases (`commit -12%`, `fetch -9%`).

## [0.6.10] — 2026-04-25 — dep bumps + S-31 closeout

Small dep-bump release. Picks up the patra and cyrius patches that shipped while sit was working on the v0.6.x perf arc. **No bench movement** (honest — the dep changes don't target the workloads the harness covers; the patra group-commit feature was investigated and explicitly reverted as a durability regression with no perf gain).

### Changed

- **cyrius 5.6.35 → 5.6.40.** Five toolchain patches. None target sit's bottlenecks; picked up for general hygiene.
- **patra 1.6.0 → 1.8.3.** Picks up:
  - **1.6.1 — `patra_result_get_str_len(rs, row, col)`** sized accessor (consumed: see Fixed below).
  - **1.7.0 — `INSERT OR IGNORE INTO` SQL syntax.** **Not consumed yet.** Sit's object-store inserts go through `patra_insert_row` (the only path that handles BYTES columns), not through SQL strings. patra's `INSERT OR IGNORE` is SQL-level only; sit will pick this up when patra grows an `or_ignore` flag on the programmatic insert path.
  - **1.8.x — WAL group commit (`PATRA_SYNC_BATCH`).** **Investigated and NOT consumed.** See "BATCH mode investigation" below.

### Fixed

- **S-31** — `parse_index` (`src/index.cyr`) now uses `patra_result_get_str_len(rs, i, 0)` directly instead of the v0.6.3 `strnlen(path_str, 256)` workaround. Same safety property at the read site (bound-walked within `COL_STR_SZ`), but now asked of patra's API directly. `strnlen` helper removed from `src/util.cyr` (no other consumers).

### Investigated and reverted

- **patra `PATRA_SYNC_BATCH` mode.** Initially set on both cached DB handles in v0.6.10's branch. Re-benched: `clone-100commits` 170.92 ms vs v0.6.9's 172.64 — within run-to-run noise. **No measurable improvement** because (a) `copy_objects` already wraps its hot loop in `patra_begin`/`patra_commit` (v0.6.5 P-03) which provides the same fsync amortization on the only batch-shaped write path, (b) the `cmd_commit` 3-insert sequence is below the every-64-writes auto-flush threshold so coalescing doesn't trigger inside a single command, (c) sit's cached handle never `patra_close`s — so BATCH-pending writes between auto-flushes would sit in the kernel writeback window with no fdatasync, lost on power loss within the window. **Net: no perf gain, real durability cost.** Reverted before shipping; the call sites are documented with the reasoning so a future release can revisit when sit grows explicit `patra_flush()` at command exit.

### Documentation

- New bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.10.md`](docs/benchmarks/2026-04-25-v0.6.10.md) (includes the BATCH-mode investigation writeup and the two "what we didn't do — and how to do it later" follow-up paths).

### Cumulative scoreboard (0.6.0 → 0.6.10)

Identical to v0.6.9's — no headline movement this release. `log -18%`, `clone -31%`. Next sit-side mover is either (a) explicit transactions + flush at exit on multi-insert commands like `cmd_commit` (small effort, optional follow-up release), or (b) wait for sigil 2.9.x SHA-256 throughput / sankoch DEFLATE throughput / patra programmatic `INSERT OR IGNORE` to ship and pick up the corresponding consumer-side improvements.

## [0.6.9] — 2026-04-25 — sit-side v0.6.x perf arc closed

P-06 + P-15 hygiene release. Two small items that close out the audit's perf-arc backlog. **No measurable bench movement** at the 100-file fixture (both changes are memory hygiene / edge-case, not hot-path), but they're correct and worth shipping for completeness.

### Performance

- **P-06 — smarter decompression sizing.** Three call sites updated (`src/object_db.cyr:read_object`, the loose-migration path, `src/wire.cyr:db_object_read_both`):
  - Initial multiplier dropped from 16× to 4×. Most sit objects (commits, trees, source-shape blobs) decompress at ratio ~2-3× and fit; legitimately high-ratio outliers retry at the 16 MiB ceiling.
  - Retry only on confirmed `0 - ERR_BUFFER_TOO_SMALL` (= -2 from sankoch) — other negative codes mean the stream is corrupt and more memory won't help. Fail fast on real corruption.
  - Memory: 75% reduction in decompression-buffer alloc on objects with `blen > 1024` (real source files); the 4096-byte floor still dominates for the bench's tiny fixture objects.
- **P-15 — LCS DP table to `fl_alloc`.** `src/diff.cyr:lcs_diff` now allocates the DP table via `fl_alloc` (mmap-direct for large allocations) and `fl_free`s before returning. Previously the table sat on the bump heap permanently for the life of the process — up to 128 MB of permanent RSS for diff-heavy commands. Now the memory goes back to the kernel after the LCS computation completes.

Both changes are memory hygiene — no wall-clock signal on the synthetic bench (expected and called out in advance). Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.9.md`](docs/benchmarks/2026-04-25-v0.6.9.md).

### Final v0.6.x cumulative scoreboard

`log` **-18%**, `clone` **-30%** from a half-dozen small targeted changes. Other ops within run-to-run noise (their bottlenecks are dep-side: sankoch zlib throughput, sigil SHA-256 throughput, patra WAL fsync — all filed on those repos' roadmaps).

### Sit-side v0.6.x perf arc closed

Every audit P-NN item that targets sit-side code is now either shipped (P-01, P-02, P-03, P-04, P-05, P-06, P-08, P-10, P-12, P-15, P-17, P-18, P-25 — and S-24 which folded into P-01) or explicitly moved out of scope to v0.7.x / v0.8.0 (P-07 bump-arena reset, P-11 sit add upsert — needs patra UPSERT, P-13 glob bucket, P-14 Myers diff algorithm, P-16 fsck --fast, P-19/P-21/P-23 micro-wins). Next ship target: **v0.7.0 network transport (HTTP/SSH)**, queued since v0.5.0 shipped local-path transport — or wait on patra 1.7.0 / 1.8.x / sigil throughput / sankoch throughput shipping and revisit perf with a fresh upstream baseline.

## [0.6.8] — 2026-04-25

P-17 perf release: buffered stdout. 200+ direct `syscall(SYS_WRITE, STDOUT, ...)` call sites across nine source files swapped to a single buffered `stdout_write(data, len)` helper. **No measurable bench movement on current fixtures** — the synthetic `diff-edit` is too small to show the win — but the change is structural and right. Caught and fixed a real output-ordering bug in `write_sanitized` along the way.

### Performance

- **P-17** — added `stdout_write(data, len)` and `stdout_flush()` helpers in `src/util.cyr` backed by a 64KB lazy-allocated heap buffer. Auto-flushes on buffer-full; large writes (≥ buffer size) flush pending bytes and go straight to the kernel without buffering. `src/main.cyr` trailer flushes before `SYS_EXIT`. STDERR (`eprintln`) stays direct so error output is immediate.
- Bulk-replaced `syscall(SYS_WRITE, STDOUT, ` → `stdout_write(` across `diff.cyr` (54), `wire.cyr` (37), `commit.cyr` (34), `refs.cyr` (24), `sign.cyr` (22), `index.cyr` (14), `merge.cyr` (11), `object_db.cyr` (6), `config.cyr` (4). 206 sites total.
- **`write_sanitized` rewrite**: was emitting one byte per `syscall(SYS_WRITE, fd, &single, 1)` — a buffer-bypass AND a perf footgun. Now builds the sanitized bytes into a heap buffer in one pass and emits via a single write (through `stdout_write` when fd == STDOUT, direct otherwise). Caught an output-ordering bug introduced by the bulk swap: `print_commit_header` was calling `stdout_write("Author: ", 8)` (buffered) then `write_sanitized(STDOUT, ident, ...)` (direct, unbuffered) — the unbuffered author bytes hit stdout before the buffered "Author: " prefix did. Fix in the same change.

**Why the bench didn't move**: audit's "3000+ writes for a 500-line diff" estimate was for diffs with many hunks. The bench fixture is a 500-line file with ONE changed line → actual output is one hunk ≈ 30 writes ≈ 30µs at the syscall level — already under the noise floor of `diff-edit`'s 13ms total. Ad-hoc test on a 2000-line file with 1000 changes (45KB output) lands ~185ms; without buffering would be ~1000 syscalls = a few ms saved. Visible at scale, not in the synthetic bench.

Structural benefit beyond wall-clock: lower system-wide syscall pressure, reduced context-switch cost, and the buffer guarantees in-order writes (which is what surfaced the `write_sanitized` ordering bug — a problem the unbuffered version had been hiding by virtue of small per-call writes mostly coalescing in the terminal).

Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.8.md`](docs/benchmarks/2026-04-25-v0.6.8.md).

### Cumulative scoreboard (0.6.0 → 0.6.8)

`log` **-17%**, `clone` **-32%**. Other ops within noise but trending slightly favorable across releases.

## [0.6.7] — 2026-04-25

P-04 perf release: walk-reachable now caches the compressed bytes it pulled and shares them with `copy_objects`, so commits + trees aren't re-read from the source DB. **`sit clone-100commits`: −21.7%** (215.27 → 168.53 ms min, 13.64x git → 11.08x git).

### Performance

- **P-04** — `walk_reachable_*` was decompressing every commit + tree, which internally pulled the compressed bytes from `src_db` via `db_object_read_raw`. Then `copy_objects` re-read the same bytes for the insert into `dst_db` — every commit + tree was paying for two source-DB reads instead of one. Fix lands in three pieces in `src/wire.cyr`:
  1. New `db_object_read_both(db, hex, raw_out, deco_out)` returns BOTH the compressed bytes (formerly thrown away after the internal call) AND the decompressed view. `db_object_read_decompressed` becomes a thin wrapper.
  2. `walk_reachable_tree` and `walk_reachable_from_commit` gain a `raw_cache` parameter; they call `db_object_read_both` and stuff the raw bytes into the cache keyed by hex.
  3. `copy_objects` gains a matching `raw_cache` parameter; checks the cache first per object and skips the source-DB read on hit. Cache misses (blobs only — walk doesn't visit them) fall back to `db_object_read_raw` as before.
- **Concrete savings on the 100-commit / 100-file fixture**: 500 source SQL ops → 300 (−40%). Wall-clock goes from 215ms to 169ms (−21.7%). Bigger than the naive "saved page fetch only" projection because each cache hit also avoids SQL parse + B+ tree walk + result-set setup (~150µs per saved op × 200 saved ops).
- Other ops within run-to-run noise as expected: `log` doesn't use walk_reachable (uses commit-chain `read_object` walk, already cached at the patra-handle level since v0.6.4); `status` / `add` are dep-side bound (sigil + sankoch).

Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.7.md`](docs/benchmarks/2026-04-25-v0.6.7.md).

### Cumulative scoreboard (0.6.0 → 0.6.7)

`log` **-16%**, `clone` **-32%**, everything else within noise (dep-side bound or already past sit's ceiling).

## [0.6.6] — 2026-04-25

P-10 + P-18 perf release. Two hot-path lookups moved from O(N²) to O(N). **No measurable improvement on the 100-file synthetic bench** — the fixture is too small to show the win — but the change is real and substantial at repo scale (1000+ tracked files).

### Performance

- **P-10** — `tree_find` in `src/tree.cyr` now lazily builds a name → entry hashmap on first call per entries vec, cached by vec pointer for the process lifetime. Hot callers (`cmd_status` iterating index entries against `head_entries`; `cmd_diff` against tree_a/tree_b; `materialize_target`; the merge three-way loops in `merge.cyr`) drop from O(N²) total to O(N). Single tree_find calls are unchanged in cost (one map build + one lookup = same complexity as the old linear scan); multi-call hot paths see the structural improvement.
- **P-18** — `three_way_path_set` (also `src/tree.cyr`) now dedups via `map_has` instead of a nested `streq` scan over the growing paths vec. For three trees of N entries each: was ~4.5N² streqs, now 3N inserts + 3N membership checks. Used by `cmd_merge`'s three-way path enumeration.

**Why the bench didn't move**: the fixture is 100 files. At that scale, the old O(N²) cost is ~10000 streqs per status — already under the noise floor compared to the dominant costs (per-file sigil hashing for `status`, per-object zlib for `clone`). The hashmap-build adds a small constant overhead (one map per command) that's also under the noise floor. Concrete projection: a 1000-file `cmd_status` drops from ~5ms of pure scan to ~0.3ms; a 10000-file repo sees ~50× improvement on that piece. The 100-file synthetic bench can't see it, and a larger-N bench fixture is queued for whenever we have a real consumer pushing those scales.

Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.6.md`](docs/benchmarks/2026-04-25-v0.6.6.md).

### Documentation

- Bench snapshot adds a "Cumulative scoreboard" section showing 0.6.0 → 0.6.6 deltas: `log` -12%, `clone` -13%, everything else noise.

## [0.6.5] — 2026-04-25

P-03 perf release: `copy_objects` batched into a single patra transaction, redundant outer has-check dropped. **`sit clone` of a 100-commit / 100-file repo: −15%** (245.19 → 208.44 ms min, 16.13x git → 13.82x git). All other operations within run-to-run noise — their bottlenecks remain dep-side (sigil SHA-256 throughput, sankoch zlib throughput) and are filed on those repos' roadmaps.

### Performance

- **`sit clone` (100-commit / 100-file fixture): −15%** at `RUNS_LIGHT=20 RUNS_HEAVY=10`. Three changes in `src/wire.cyr:copy_objects`:
  1. Wrap the insert loop in `patra_begin` / `patra_commit`. Collapses ~300 individual WAL fsyncs into one commit. Patra exposes these primitives as stdlib functions; they were dead code in every sit build prior to v0.6.5.
  2. Drop the outer `db_object_has` check. `db_object_insert_raw` already does its own has-check internally — every object was paying for two SELECTs instead of one. Halves the SQL round-trips on the dedup path.
  3. Side-effect counting fix: `db_object_insert_raw` now returns `1` for already-existed (vs. `0` for actually-inserted; negative for error), so `copy_objects` counts only genuine new inserts. Caught by the wire-protocol smoke test — without the fix, `sit push` on a clone reported all reachable objects as "new" instead of just the locally-added ones.

The bigger wins on `clone` are gated on patra-side work — `WAL group commit / batched fsync` and `INSERT OR IGNORE` / `UPSERT` are filed on patra's roadmap (entries cite this release's bench snapshot). Once those land, a follow-on sit release can drop the manual transaction wrapping and the inner has-check; expected combined improvement is another ~30-50% on top of v0.6.5's gain.

### Documentation

- New bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.5.md`](docs/benchmarks/2026-04-25-v0.6.5.md).
- `docs/development/roadmap.md` v0.6.5+ section gained a "Waiting on dep updates" subsection that lists the patra / sigil / sankoch items now tracked on each lib's own roadmap. When any of those ship, sit can drop the corresponding workaround / pick up the matching improvement without further sit-side code changes.

## [0.6.4] — 2026-04-25

First v0.6.x perf release. Process-wide patra-handle caching collapses six audit findings (P-01, P-02, P-05, P-08, P-12, P-25) plus the deferred S-24 into one refactor. `sit log` on a 100-commit history is **~17% faster** (33.67 → 27.84 ms min, RUNS_LIGHT=20). Other commands (status, clone, fetch, add) unchanged in this release — their bottlenecks (sigil throughput, per-object zlib_decompress, file_write_all) are downstream of patra open/close cost. Real status / clone wins need separate work in subsequent releases.

### Changed

- **`src/object_db.cyr`** — added `get_object_db()` process-wide cached handle for `.sit/objects.patra`. Lazy-open + lazy `object_db_migrate_from_loose` on first call. fd dies with the process (`patra_close` is just buffer-free + close — no WAL flush — so skipping it at exit is safe). `read_object`, `write_typed_object`, `resolve_hash`, `cmd_fsck` migrated to the cache; their previous `var db = open(); ... patra_close(db);` pattern is gone.
- **`src/index.cyr`** — added `get_index_db()` cached handle for `.sit/index.patra` (same shape). `parse_index` and `rewrite_index` migrated.
- **`src/wire.cyr`** — `do_fetch` and `do_push` use the cached local DB; the remote DB end (different file each call) stays per-operation.

### Fixed

- **S-24** (Patra-handle + SQL-string leaks; `read_object` single-exit refactor) — landed as part of the cache refactor, as planned in v0.6.2's deferral note. The single-exit shape fell out naturally once the open/close pattern was gone. SQL-string buffers in `read_object` / `resolve_hash` / `write_typed_object` switched from `alloc_or_die` (bump-heap, lives forever) to `fl_alloc` + `fl_free` (mmap'd, freed after each query). Trims per-query bump-heap pressure on long-running ops like `sit log` / `sit fsck` over thousands of objects.

### Performance

- **`sit log`** (100-commit walk): **−17%** (33.67 ms → 27.84 ms min, `RUNS_LIGHT=20` against git 2.53.0). Higher commit counts amortize the same fixed-cost win — expect proportionally larger savings on 1K- or 10K-commit histories.
- **`sit fsck`** (100-commit / 100-file fixture): not in the bench harness yet, but exercises the same pattern (one query → N read_object calls). Wins should match or exceed `log`.
- **`sit status`**, **`sit clone`**, **`sit add`**, **`sit commit`**, **`sit fetch`**: within run-to-run noise. Their bottlenecks are sigil hash throughput (status / add) or per-object zlib_decompress + file_write_all (clone) — both downstream of patra open/close. Queued for separate releases:
  - **P-03** batch `copy_objects` in a single transaction → clone speedup
  - **P-06 + P-15** smarter decompression sizing + LCS DP table via fl_alloc → diff / clone speedup
  - **P-04** denormalize tree/parent hashes so `walk_reachable_from_commit` doesn't decompress every commit/tree just to read headers
  - sigil SHA-256 throughput → upstream sigil's roadmap

Full snapshot: [`docs/benchmarks/2026-04-25-v0.6.4.md`](docs/benchmarks/2026-04-25-v0.6.4.md).

## [0.6.3] — 2026-04-25

LOW-severity batch from the 2026-04-24 P(-1) audit. All audit findings (CRITICAL, HIGH, MEDIUM, LOW) are now closed or explicitly deferred to the v0.6.x perf arc. Two of the three v0.6.3 items resolved via documentation rather than code change, since the underlying invariants were already in place.

### Security

- **S-28** — `exec_vec` envp scrubbing: **already addressed via stdlib**. Cyrius's `lib/process.cyr:exec_vec` passes an empty envp to the child process (`var envp = alloc(8); store64(envp, 0);`), which is strictly more aggressive than the audit's "minimal envp" prescription — `LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, and every other env var is dropped on owl exec by construction. No sit-side change required. Recorded in audit so future readers don't re-investigate; documented in `docs/development/state.md` so any future curated-envp shape (e.g. preserving PATH/HOME/TERM/LANG for owl UX) is a deliberate widening, not a tightening.
- **S-31** — added `strnlen(s, max)` to `src/util.cyr`. Swapped `parse_index`'s `strlen(path_str)` over a `patra_result_get_str` result to `strnlen(path_str, 256)` (patra's `COL_STR_SZ` width). The other three `patra_result_get_str` callers in sit memcpy a fixed 64 bytes (hash columns) and are safe by construction. Defense-in-depth against any future patra writer that skips the slot zero-fill — today patra always memsets the 256-byte slot before writing, so `strlen` would terminate inside the slot, but the bound makes the safety property explicit at the read side rather than implicit at the write side.
- **S-32** — Cyrius string-literal lifetime invariant **confirmed and documented** in [`docs/architecture/004-cyrius-string-literal-lifetime.md`](docs/architecture/004-cyrius-string-literal-lifetime.md). Cyrius compiles `"..."` literals into a fixed compile-time string-data region (cyrius's own 2026-04-13 audit pins the size at 256 KB) that is mapped for the lifetime of the process — the same model as C's `.rodata`. `src/tree.cyr`'s `store64(le, "100644")` pattern is safe because the literal pointer never goes stale. The audit's alternative fix (switch to integer mode codes with a format table) was rejected: it would trade a free invariant for runtime indirection on the hottest tree-build path. ADR-style note also explains why `argv(n)` and `patra_result_get_str` pointers do NOT have the same lifetime properties.

### Added

- `src/util.cyr:strnlen(s, max)` — bounded-walk replacement for `strlen` when the source has a known max length.
- `docs/architecture/004-cyrius-string-literal-lifetime.md` — invariant note covering the program-lifetime guarantee, the 256 KB ceiling, and the don't-confuse-this-with cases (`argv`, `patra_result_get_str`).

### Audit closeout

With v0.6.3 the 2026-04-24 P(-1) audit is fully resolved at every severity level except the one explicit deferral:

- **CRITICAL** (S-01 through S-08): closed in v0.6.0.
- **HIGH** (S-09 through S-15): closed in v0.6.0.
- **MEDIUM** (S-16, S-17, S-18, S-19, S-20, S-22, S-23, S-25, S-27): closed in v0.6.2.
- **MEDIUM** (S-24): deferred to v0.6.x — folds into the patra-handle-caching refactor's `read_object` rewrite to avoid touching the same function twice.
- **MEDIUM** (S-26): closed in v0.6.0 (`refname_valid` shipped with the validator suite).
- **LOW** (S-28, S-29, S-30, S-31, S-32): closed in v0.6.3 (S-29 + S-30 closed in v0.6.0 via ADRs 0003/0004; the rest in this release).
- **CRITICAL** (S-33, post-audit benchmark finding): closed in v0.6.1 via dep bumps (cyrius 5.6.35 + sankoch 2.0.3).

Next release scope shifts to the v0.6.x performance arc: cache the patra object-DB handle, fold in S-24, ship measurable wins on `sit log` / `sit fsck` / `sit clone` against the v0.6.1 baseline.

## [0.6.2] — 2026-04-25

Security-hygiene MEDIUM batch from the 2026-04-24 P(-1) audit. Defense-in-depth — closes silent-failure / underflow / overflow / partial-state cliffs across the validator, signing, materialize, clone, commit, and merge paths. Behavioral change: `sit clone <url> <abs-path>` now requires `--force-absolute` (S-23); see migration note below.

### Security

- **S-16** — Filesystem-mutation return values now checked at every audit-flagged site. `sys_unlink(".sit/MERGE_HEAD")` failure during `cmd_commit` (post-merge) and `cmd_merge --abort` aborts cleanly with a clear error instead of silently leaving a stale MERGE_HEAD that turns the next commit into an unintended 2-parent merge. `write_remote_tracking` failure during `do_fetch` aborts the fetch instead of declaring success on a partial state. `materialize_target`'s `sys_unlink` and `file_write_all` failures now stop the materialize and report the offending path. Owl tempfile cleanup failures emit a stderr warning (best-effort, leak-only).
- **S-17** — New `alloc_or_die(size)` helper in `src/util.cyr` that prints `sit: out of memory` and exits 1 on alloc failure. 52 `alloc()` call sites across `src/object_db.cyr`, `src/tree.cyr`, `src/commit.cyr`, `src/merge.cyr` swapped from bare `alloc()` to `alloc_or_die()`. The few existing propagation-path callers (`read_file_heap`, `read_object`'s `dec_cap` path, `lcs_diff` DP table) keep their explicit null-checks; everywhere else, OOM is now loud-fatal instead of a `memcpy(0 + offset, …)` segfault.
- **S-18** — `parse_author_line` timestamp parser caps digit count at 19 and detects per-multiply overflow (`new < old` after `ts * 10 + (c - 48)`). A crafted commit with a 20+ digit timestamp, or a 19-digit timestamp that wraps i64, now returns `0 - 1` cleanly instead of silently storing a wrapped value.
- **S-19** — `extract_sitsig` adds an explicit `if (body_len < 201) return 0;` guard at function entry. The inner `body_len - 201` underflow was previously not reachable on real commit bodies but the guard locks in the invariant against future changes.
- **S-20** — sitsig hex parse now gates on `hex_is_valid(...)` BEFORE calling `hex_decode(...)` for both the signature (128 hex chars → 64 bytes) and pubkey (64 → 32). Belt-and-suspenders against any future loosening of `hex_decode`'s "all-or-fail" contract.
- **S-22** — `index_migrate_from_plaintext` caps per-line path length at 4096 bytes. A malformed legacy index with a multi-megabyte single-line `plen` is now rejected at parse instead of forcing a single huge `alloc()` on migration.
- **S-23** — `cmd_clone` refuses absolute target paths unless `--force-absolute` is passed. `sit clone <url> /etc/passwd` no longer silently `mkdir`s + `chdir`s into a system path the invoking user has perms for. Relative targets and URL-derived basenames continue to work unchanged.
- **S-25** — Deleted `src/util.cyr:ensure_dirs_for` (latent `mkdir("")` bug for absolute paths); both call sites in `src/merge.cyr` (`write_conflict_file` + the merged-files writer) now use `ensure_parent_dirs`. Behavior identical for relative paths; absolute paths no longer trip the latent bug.
- **S-27** — `materialize_target` aborts with a clear stderr error on the first `read_blob_content` failure instead of silently producing a partial working tree. The error names both the unreadable hash and the path it would have landed at.

### Changed

- `sit clone <url> <abs-path>` now requires `--force-absolute`. **Migration**: any script that clones into an absolute path needs the flag added (e.g. `sit clone "$URL" "$DIR"` → `sit clone --force-absolute "$URL" "$DIR"` when `$DIR` starts with `/`). The flag can appear anywhere in the argv. CI smoke (`.github/workflows/ci.yml`) and `scripts/benchmark.sh` updated; `docs/guides/getting-started.md` documents the new shape.

### Deferred

- **S-24** (Patra-handle + SQL-string leaks; `read_object` single-exit refactor) deferred to v0.6.x along with the patra-handle-caching refactor. Doing the single-exit refactor now would mean rewriting `read_object` twice in two consecutive releases — the v0.6.x arc adds a `read_object_with_db(db, hex, out)` variant and threads the cached handle through every caller, which subsumes the single-exit cleanup. Bump-allocator pressure from un-freed SQL strings is bounded by process lifetime and not a real exposure today.

## [0.6.1] — 2026-04-25

S-33 fix release. Pure dep-pin bumps — no sit source changes. Status, fsck, and clone now run cleanly on the 100-commit / 100-file fixture; the previously-disabled `bench_status` and `bench_clone` rows are re-enabled in `scripts/benchmark.sh`.

### Fixed

- **S-33** — `sit status` SIGSEGV on a 100-commit / 100-file repo. Triage surfaced two stacked upstream bugs: a cyrius stdlib `alloc` grow-by-1MB undersize that crashed any single allocation > 1 MiB (caused the SIGSEGV via `read_object`'s 16 MiB retry buffer), and a sankoch `zlib_compress` / `zlib_decompress` asymmetry that lost ~20% of objects on the same fixture (caused `read_object` to fall into the retry path in the first place). Independence proven by re-running the fixture across the cyrius bump alone — bit-for-bit identical bad-object set. Fixed by:
  - **sankoch 2.0.1 → 2.0.3** — write/read symmetry restored. After the bump, fsck reports 300/300 objects readable on the fixture (was 247/300 with 53 unreadable). The sankoch fix alone removes the trigger for the cyrius bug in sit's hot path.
  - **cyrius 5.6.25 → 5.6.35** — picks up the upstream allocator grow fix that landed in 5.6.34. Defense-in-depth for any future sit code that allocates > 1 MiB in a single call.
  - Full triage and resolution narrative in [`docs/development/issues/archived/2026-04-24-cyrius-stdlib-alloc-grow-undersize.md`](docs/development/issues/archived/2026-04-24-cyrius-stdlib-alloc-grow-undersize.md) and [`docs/development/issues/archived/2026-04-24-read-object-unreadable-at-scale.md`](docs/development/issues/archived/2026-04-24-read-object-unreadable-at-scale.md).

### Changed

- `cyrius.cyml` — cyrius `5.6.25` → `5.6.35`, sankoch `2.0.1` → `2.0.3`. No other dep movement.
- `scripts/benchmark.sh` — `bench_status` and `bench_clone` rows re-enabled and producing real numbers.

### Added

- `docs/development/issues/` — new directory for upstream-bug writeups against deps. README sets the `YYYY-MM-DD-{dep}-{slug}.md` filename convention and the lifecycle (resolved issues move to `archived/` with a `— RESOLVED` suffix; filename stable across the move). Two issues filed and immediately archived as RESOLVED in this release: the cyrius alloc-grow bug and the sankoch object-roundtrip bug.
- `docs/benchmarks/2026-04-25-v0.6.1.md` — first benchmark snapshot that includes `status-100files` and `clone-100commits` rows alongside the post-audit baseline.

### Inherited from late v0.6.0 / v0.6.1 dev cycle

(Items added between the v0.6.0 release and v0.6.1, previously listed under `[Unreleased]`.)

- `scripts/benchmark.sh` — reproducible git-vs-sit bench harness. Produces a markdown table of min + median wall-clock times over 10–15 runs per operation. Updates `docs/development/benchmarks-git-v-sit.md`.
- Five new benches in `tests/sit.bcyr`: `patra-open-close`, `copy-objects-100`, `commit-parse+iso8601`, `ed25519-sign` / `ed25519-verify`, validator throughput (`refname_valid`, `tree_entry_name_valid`, `tree_flat_path_valid`, `hex_prefix_valid`). All land in the single bench binary.
- `docs/benchmarks/2026-04-24-v0.6.0.md` — snapshot of post-audit numbers for comparison against future work.

## [0.6.0] — 2026-04-24

Security hardening release. All CRITICAL + HIGH findings from the 2026-04-24 P(-1) audit ([`docs/audit/2026-04-24-audit.md`](docs/audit/2026-04-24-audit.md)) are fixed. Network transport work (originally planned for 0.6.0) moves to v0.7.0.

### Security

- **S-01** — `hex_prefix_valid` gate in `resolve_hash` rejects any non-hex character before interpolation into `LIKE '<prefix>%'`. Closes SQL-injection via `sit cat-file "abc' OR 1=1 --"`.
- **S-02 / S-26** — `refname_valid` enforces the full [`git check-ref-format`](https://git-scm.com/docs/git-check-ref-format) grammar. Wired into `cmd_branch`, `cmd_tag` create, `cmd_checkout -b`, `cmd_remote_add`, and `write_remote_tracking` (fetch-receive side). A malicious remote advertising a branch named `../../../etc/cron.d/x` can no longer poison `.sit/refs/remotes/`.
- **S-03** — `tree_entry_name_valid` + `tree_flat_path_valid` + `tree_entry_mode_valid` gate tree objects at two boundaries. `parse_tree` drops invalid entries inline; `materialize_target` second-gates flattened paths before `file_write_all` / `sys_unlink` / `ensure_parent_dirs`. Mode allowlist accepts only `100644` and `40000`. Closes the CVE-2018-11235 / CVE-2019-1352 / CVE-2024-32002 shape for `sit clone` of a malicious repo.
- **S-04** — Local-clone symlink guards via `path_is_symlink` (newfstatat with `AT_SYMLINK_NOFOLLOW`). `remote_objects_open` refuses if `<repo>/.sit` or `<repo>/.sit/objects.patra` is a symlink. `read_remote_ref` refuses symlinked ref files. `cmd_clone` refuses to clone into an existing symlink target. Closes the CVE-2023-22490 shape.
- **S-05** — `config_value_valid` + `config_key_valid` reject `\n`, `\r`, `\0`, control chars, and oversized values in `config_file_set`. Closes the CVE-2023-29007 / CVE-2025-48384 config-line-injection primitive.
- **S-06** — File-size caps: `sit add` refuses files >1 GiB (prevents `sit add /dev/zero` OOM); `read_file_heap` refuses >64 MiB (config/ref files stay sane).
- **S-07** — LCS dimensions pre-checked against `sqrt(cap)` before multiplying, preventing `cells = (n1+1) * (n2+1)` integer overflow that would bypass the existing 16M-cell cap and under-allocate the DP table.
- **S-08** — Decompression caps tightened from 256× to 16× with a single retry at the 16 MiB ceiling. Applies to `read_object`, `db_object_read_decompressed`, and the loose-file migration path. Reduces the per-object memory footprint of attacker-controlled decompression by 16×.
- **S-09** — Owl path resolution honors `$SIT_OWL` env var before the hard-coded fallbacks (`/usr/local/bin/owl` → `/usr/bin/owl` → `/opt/owl/bin/owl`).
- **S-10** — `sit owl-file` tempfiles land in `$XDG_RUNTIME_DIR` (or `$HOME/.cache/sit/` fallback), opened with `O_CREAT | O_EXCL | O_WRONLY` + mode 0600. Closes the /tmp symlink-plant TOCTOU and the world-readable info-leak.
- **S-11** — Every ref-file reader (`resolve_ref_name` tag/head/remote paths, `read_head_ref`, `read_remote_ref`) validates the first 64 bytes are hex before returning. Corrupt or hostile ref files are treated as "no such ref" instead of flowing garbage downstream.
- **S-12** — `cmd_key_generate` opens `~/.sit/signing_key` with `O_EXCL` and pre-checks `path_is_symlink`. Closes the TOCTOU where another local user could symlink-plant between the `file_exists` check and the open.
- **S-13** — `write_remote_tracking` sizes staging buffers from actual remote/branch name lengths instead of a fixed 128 bytes. Closes a long-remote-name heap overflow.
- **S-14** — Recursion depth capped at 256 for both `flatten_tree` (local) and `walk_reachable_tree` (remote). Closes stack-overflow DoS on crafted object sets with deep subtree nesting.
- **S-15** — `glob_match` pattern length capped at 256 bytes. Closes the O(2^N) recursion DoS via crafted `.sitignore` patterns.
- **S-21** — Author identity bytes sanitized before writing to stdout via a new `write_sanitized` helper in util.cyr. Control chars (`< 0x20` except tab) and `\x7f` replaced with `?`. Closes the terminal-escape / log-line-forgery vector.

### Added

- **`src/validate.cyr`** — new module housing all input validators. Pure functions, no side effects. Callers decide error messages and disposition.
  - `hex_prefix_valid`, `refname_valid`, `tree_entry_name_valid`, `tree_flat_path_valid`, `tree_entry_mode_valid`, `config_value_valid`, `config_key_valid`, `remote_url_valid`
  - `path_is_symlink`, `path_lstat_kind` — `newfstatat`-based primitives for symlink / file-type checks without follow.
- **`src/util.cyr`** grew `write_sanitized(fd, bytes, len)` for the S-21 output escape filter.
- **Test coverage**: `tests/sit.tcyr` grew 70 new assertions across six `test_validate_*` functions — positive + negative cases for every validator. **101 total assertions**, up from 31.
- **ADR 0003** — sit does not search upward for `.sit/` (locks in correct behavior against CVE-2022-24765 class).
- **ADR 0004** — sit is SHA-256 only (no SHA-1 interop, even for legacy-repo imports).
- **ADR 0005** — Local-clone threat model (what sit trusts and doesn't, and which validator enforces which boundary).

### Changed

- `src/commit.cyr` lint cleanup (consecutive blank-line warnings from the v0.5.1 refactor).
- `config_file_set` return code `-2` now means "invalid input" (`cmd_config` surfaces this as a specific error message instead of the generic "failed to write config").

### Removed / deprecated

- Nothing user-facing. Implementation detail: the `write_remote_tracking` fixed-size `alloc(128)` is gone.

### Deferred to future releases

- **MEDIUM findings S-16–S-27** (filesystem mutation return checks, alloc null-checks everywhere, author-timestamp overflow guards, cleanup sweep) — v0.6.1 patch.
- **LOW findings S-28–S-32** (env scrubbing, patra cstring defense-in-depth, mode-literal lifetime audit) — v0.6.x as convenient.
- **Performance findings P-01 through P-25** — separate perf-focused minor after the security baseline bakes. The DB-handle caching refactor alone collapses 5 of the top-10 findings.

## [0.5.1] — 2026-04-24

File-split refactor. No feature changes, no bug fixes beyond what the split itself surfaced.

### Changed

- Split the monolithic `src/main.cyr` (~5700 lines) into 11 topical Cyrius modules chained through `src/lib.cyr`. `main.cyr` is now 112 lines — purely `print_usage`, `main()`, dispatch, and the exit trailer. Follows the yukti / patra include-chain pattern.
- New layout:
  - `src/util.cyr` (172) — `SEEK_SET/END`, `eprintln`, `ensure_dir`, `ensure_parent_dirs`, `ensure_dirs_for`, `write_decimal`, `argv_heap`, `skip_ws`, `strcmp_cstr`, `sort_cstrings`, `read_file_heap`
  - `src/config.cyr` (332) — `config_parse_value`, `config_file_get` / `set` / `list` / `unset`, `config_get`, `cmd_config`
  - `src/object_db.cyr` (488) — `object_path`, `resolve_hash`, `read_object`, `write_typed_object`, `write_blob_object`, `type_code_of`, `object_db_open`, `object_db_migrate_from_loose`, `resolve_and_read`, `find_owl`, `hash_blob_of_content`, `hash_file_as_blob`, `cmd_cat_file`, `cmd_owl_file`, `cmd_fsck`
  - `src/index.cyr` (594) — `index_db_open`, `index_migrate_from_plaintext`, `parse_index`, `rewrite_index`, `index_upsert`, entry accessors, `sort_entries`, `dedupe_entries`, `glob_match`, `is_ignored`, `load_sitignore`, `index_find`, `cmd_add`, `cmd_rm`, `cmd_reset`
  - `src/refs.cyr` (550) — `resolve_ref_name`, `read_head_ref_path`, `read_head_ref`, `write_head_ref`, `set_head_ref`, `current_branch_name`, `cmd_branch`, `cmd_checkout`, `cmd_tag`
  - `src/tree.cyr` (310) — `tlvl_*`, `build_tree`, `tree_entry_*`, `parse_tree`, `flatten_tree`, `read_head_tree_entries`, `tree_find`, `tree_find_hash`, `three_way_path_set`
  - `src/diff.cyr` (1060) — `is_dirty`, `split_lines`, `lines_equal`, `lcs_diff`, `annotate_ops`, `group_hunks`, `hunk_ranges`, `print_hunk_header`, `print_file_diff`, `print_file_stat`, `read_blob_content`, working-tree walker, status helpers, `cmd_diff`, `cmd_show`, `cmd_status`
  - `src/commit.cyr` (595) — `build_commit*`, `is_ancestor`, `materialize_target`, `parse_author_line`, `print_indented_message`, `parse_commit_body`, `print_commit_header` / `oneline`, `commit_tree_entries`, `cmd_commit`, `cmd_log`
  - `src/merge.cyr` (682) — `extract_hunks`, overlap detection, `three_way_line_merge`, MERGE_HEAD IO, `write_conflict_file`, `find_merge_base`, `build_merge_commit*`, `cmd_merge`
  - `src/sign.cyr` (310) — key path helpers, `load_signing_seed` / `pubkey`, `sign_commit_body`, `extract_sitsig`, `verify_commit_body`, `cmd_key` / `cmd_verify_commit`
  - `src/wire.cyr` (749) — remote config, `db_*` parameterized readers, reachability walkers, `copy_objects`, remote-ref IO, `is_ancestor_in_db`, `do_fetch`, all wire commands (`remote`, `fetch`, `pull`, `push`, `clone`)
- `src/lib.cyr` is the include chain. Cyrius does two-pass compilation, so include order is just logical grouping (primitives → storage → refs → objects → commands).

### Notes

- `cyrius.cyml [build].entry` stays pointed at `src/main.cyr`.
- Stdlib continues to auto-resolve via `cyrius.cyml [deps].stdlib` — no explicit `include "lib/*.cyr"` in the module files.
- Function names unchanged; no rename drift in this cut.
- 31 tests pass; local-vcs-loop walkthrough clean; full clone → push → re-clone round-trip clean.

## [0.5.0] — 2026-04-24

Wire protocol cut — local-path transport. Remotes, fetch, and push ship against other sit working-tree directories; HTTP / SSH transports and pack bundles remain v0.6.x+ work.

### Added

- **`sit remote add <name> <url>` / `list` / `remove <name>`** — named remotes recorded as `remote.<name>.url = <path>` entries in `.sit/config`. URLs accept bare paths (`/abs/path`) and `file://` scheme; any other scheme is treated as a path for v0.5.0. No validation that the remote is a real sit repo at config-write time — the error surfaces at fetch/push.
- **`sit fetch <remote> [<branch>]`** — opens the remote's `.sit/objects.patra` directly via patra; BFS-walks reachability from the remote's ref (commits → trees → subtrees → blobs); copies any object missing from the local DB as raw compressed bytes (no decompress/recompress); writes `.sit/refs/remotes/<remote>/<branch>` with the fetched tip. Defaults `<branch>` to `main`.
- **`sit push <remote> [<ref>]`** — symmetric direction: local → remote. Includes a fast-forward check (walks parent chain from local tip in the local DB looking for the remote's current tip; rejects if not found). Updates the remote's `.sit/refs/heads/<branch>` on success. Defaults `<ref>` to the current branch.
- **`sit pull <remote> [<branch>]`** — fetch + fast-forward merge. On divergence, prints an explicit message pointing at `sit merge <remote>/<branch>` rather than attempting an automatic 3-way; keeps the semantics narrow and predictable.
- **`sit clone <url> [<dir>]`** — `mkdir` + `chdir` + inline `init` + `remote add origin` + `fetch` + `write_head_ref` + `materialize`. Derives target directory from the URL's last path segment when `<dir>` is omitted; refuses to clone into a non-empty directory.
- **`sit merge -S <branch>`** — signed merge commits. Routes through the existing `build_merge_commit_signed` with the local signing seed (same ed25519 / sitsig format as `sit commit -S`).
- **Nested branch / tag refs** — `sit branch feature/foo`, `sit checkout -b feature/foo`, and `sit tag rel/v1` now auto-create the nested `.sit/refs/heads/feature/` (and tag) parent directories. Driven by a new `ensure_parent_dirs(path)` helper called from `write_head_ref`, `cmd_branch` create, `cmd_checkout -b`, and `cmd_tag` create paths.
- **`origin/main` ref resolution** — `resolve_ref_name` now consults `.sit/refs/remotes/<path>` in addition to heads and tags, so `sit merge origin/main`, `sit show origin/main`, `sit log origin/main` etc. work against remote-tracking refs directly.
- **New helpers**: `remote_url`, `remote_normalize`, `remote_objects_open`, `db_object_has` / `db_object_read_raw` / `db_object_read_decompressed` / `db_object_insert_raw` (parameterized-by-db variants of the existing object functions so the same walker runs against any sit repo), `walk_reachable_from_commit` / `walk_reachable_tree` (BFS reachability), `copy_objects` (dedup-on-write), `read_remote_ref` / `write_remote_ref` / `write_remote_tracking` (filesystem ref IO against another repo's `.sit/refs/heads/`), `is_ancestor_in_db` (ff-check primitive), `do_fetch(name, branch)` (shared core of fetch/pull/clone), `ensure_parent_dirs` (nested-ref mkdir).
- **Dispatch**: five new top-level commands — `remote`, `fetch`, `pull`, `push`, `clone`. Command count: **24**.

### Fixed

- CHANGELOG and roadmap for 0.4.0 over-claimed wire protocol support — all five commands are now actually implemented in 0.5.0.
- `sit branch feature/foo` / `sit checkout -b feature/foo` / `sit tag rel/v1` previously failed with "failed to write ref" because nested directories weren't created. Now work correctly.

### Notes

- **Local-path only.** `file://` and bare absolute paths. No TCP, no HTTP, no SSH in this cut; those are the motivating v0.6.x work items.
- **Naive object-at-a-time copy.** No pack bundles, no delta compression. Fine for small-to-medium repos; pack format will land alongside HTTP transport so the network round-trips aren't dominated by per-object chatter.
- **Fast-forward-only pull.** Divergence bails with an explicit pointer at `sit merge`. This matches `git pull --ff-only`, which most people use anyway, and avoids surprising auto-merges.

## [0.4.0] — 2026-04-24

First official release. Rolls up the entire pre-release development arc (scaffold → full local VCS loop → signed commits → wire protocol) into a single tagged artifact.

### Added

- **Core loop** — `sit init`, `sit add`, `sit commit`, `sit log`, `sit status`, `sit diff`, `sit show`, `sit cat-file`, `sit owl-file`. Commit objects are git-SHA-256-compatible; the `"blob <len>\0<content>"`, `tree`, and `commit` framings hash byte-for-byte against git's SHA-256 format for identical content.
- **Recursive trees** — `build_tree` walks sorted index entries, groups by path segment, and emits subtree objects. Root tree carries `40000` dir entries and `100644` file entries. `flatten_tree` + `read_head_tree_entries` produce full-path views for `status` / `diff`.
- **Staging index** — patra-backed at `.sit/index.patra`, single `entries(path STR, hash_hex STR)` table. Upsert-at-write semantics via `index_upsert`. Legacy plaintext `.sit/index` auto-migrates.
- **Object store** — patra-backed at `.sit/objects.patra`, `objects(hash STR, ty INT, content BYTES)`. SHA-256 via sigil, zlib via sankoch. Prefix lookup uses `WHERE hash LIKE 'abcd%'`. Legacy loose-file `.sit/objects/<xx>/<yy...>` layout auto-migrates on first access.
- **Branches and tags** — `sit branch [-d] [<name>]`, `sit checkout [-b] <branch>`, `sit tag [-d] [<name> [<commit>]]`. HEAD-aware so `log` / `status` / `diff` follow whatever branch is currently checked out. Tag reads resolve via `ref_resolve` alongside branch refs and hex prefixes.
- **Config** — `sit config [--global] <key> [<value>]`, `--list`, `--unset`. Flat `key = value` format at `.sit/config` (local) or `~/.sitconfig` (global). Author identity chain: `SIT_AUTHOR_NAME` env → local config → global config → `"sit user"` fallback (matches git's env precedence).
- **Integrity** — `sit fsck` decompresses every stored object and re-hashes it against the filename/key; reports bad / unreadable objects with exit 1 on any mismatch.
- **`.sitignore`** — gitignore-style pattern file at the repo root. Segment-matched `*` / `?` globs (no `**` / negation / char-classes yet). `sit add <ignored>` errors out without `-f`.
- **Remove / reset** — `sit rm [--cached] <path>` (working tree + index or just index), `sit reset <path>` (unstage: rewrite index entry to HEAD's hash), `sit reset --hard <ref>` (move current branch ref + materialize).
- **Merge** — `sit merge <branch>`. Fast-forward when possible; otherwise 3-way with line-level diff3. Non-overlapping hunks auto-merge; overlapping edits fall back to `<<<<<<<` / `=======` / `>>>>>>>` markers + `.sit/MERGE_HEAD` for manual resolution. `sit merge --abort` cancels and restores HEAD. Follow-on `sit commit` emits a 2-parent commit.
- **Signed commits** — ed25519 via sigil. `sit key generate` writes `~/.sit/signing_key` (32B seed hex, 0600) + `~/.sit/signing_key.pub` (32B pubkey, 0644). `sit commit -S` injects a `sitsig <sig-hex> <pub-hex>\n` line between `committer` and the blank separator; signed payload is the body *without* the sitsig line (self-consistent like git's `gpgsig`). `sit verify-commit [<hash>]` is the explicit check; `sit show` / `sit log` auto-decorate with `Signature: good|BAD (key <hex12>)`. No GPG, no OpenPGP armor.
- **Diffstat** — `sit show --stat`: per-file `path | +N -M` with git-style singular/plural summary.
- **Wire protocol** — `sit remote add/list/remove`, `sit fetch <remote>`, `sit push <remote> [<ref>]` across local-path remotes (file:// and bare paths). Reachability walk + naive object-at-a-time copy; pack bundles and network transports (HTTP, SSH) deferred to v0.5.x.
- **Reads with polish** — `sit cat-file` (plumbing, raw bytes) and `sit owl-file` (decorated via [owl](https://github.com/MacCracken/owl), falling back to raw content when owl isn't on PATH). Both accept 4-char-minimum hash prefixes.
- **Tests** — 31 assertions across sigil SHA-256 known-answers, git-SHA-256 blob framing, hex encode/decode, sankoch zlib roundtrip, patra COL_BYTES small + 16KB overflow, and ed25519 sign/verify roundtrip (including bit-flip negative cases for both message and signature).

### Dependencies

- Cyrius toolchain 5.6.25 (pinned in `cyrius.cyml`; scalar-clobber fix landed in 5.6.24, ed25519 primitives confirmed stable in 5.6.25)
- sakshi 2.1.0, sankoch 2.0.1, sigil 2.9.1, patra 1.6.0 (all git-tag pinned)

### Notes

- **First-party only** — no libgit2, no C, no FFI. See [ADR 0001](docs/adr/0001-no-ffi-first-party-only.md).
- **Git format compatibility** — object framing + tree format are byte-compatible with git's SHA-256 mode, but sit is *not* a drop-in for a git repo (the wire protocol is sit-native, signed commits use sit's `sitsig` header rather than git's `gpgsig`).
- **Not on the AGNOS critical path** — post-boot, when-there's-time project.

[Unreleased]: https://github.com/MacCracken/sit/compare/0.8.10...HEAD
[0.8.10]: https://github.com/MacCracken/sit/releases/tag/0.8.10
[0.8.9]: https://github.com/MacCracken/sit/releases/tag/0.8.9
[0.8.8]: https://github.com/MacCracken/sit/releases/tag/0.8.8
[0.8.7]: https://github.com/MacCracken/sit/releases/tag/0.8.7
[0.8.6]: https://github.com/MacCracken/sit/releases/tag/0.8.6
[0.6.0]: https://github.com/MacCracken/sit/releases/tag/0.6.0
[0.5.1]: https://github.com/MacCracken/sit/releases/tag/0.5.1
[0.5.0]: https://github.com/MacCracken/sit/releases/tag/0.5.0
[0.4.0]: https://github.com/MacCracken/sit/releases/tag/0.4.0
