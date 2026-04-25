# sit Development Roadmap

> **v0.6.0** — Security hardening release. All CRITICAL + HIGH findings from the P(-1) audit fixed, 3 new ADRs, dedicated validator module, 101 test assertions (up from 31). Network transport originally planned for v0.6.0 shifts to v0.7.0.

Historical per-sub-version notes were collapsed into the 0.4.0 entry; see [`CHANGELOG.md`](../../CHANGELOG.md) for the tagged artifacts.

## Released

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

### v0.6.x — Performance (patra handle caching) + S-24 fold-in

Ship after security baseline is clean. Collapses P-01, P-02, P-05, P-08, P-12, P-25 + S-24 into one refactor:

- Cache the patra object-DB handle process-wide (open on first use, close at exit); add `read_object_with_db(db, hex, out)` variant and thread the handle through `cmd_log`, `cmd_fsck`, `flatten_tree`, `materialize_target`, `is_ancestor`, `find_merge_base`.
- **S-24** (deferred from v0.6.2) folds in here: refactor `read_object` to a single-exit pattern as part of the handle-threading rewrite; switch the SQL-string buffers to `fl_alloc` / `fl_free` in the same touch. Doing it together avoids a double-rewrite of the same function.
- **P-03** `copy_objects`: pre-filter via `WHERE hash IN (...)` batch; wrap the insert loop in a single patra transaction.
- **P-06** + **P-15** Smarter decompression sizing (read the framing length prefix); route LCS DP table through `fl_alloc` / `fl_free`.
- **P-10 + P-18** Hashmap-backed `tree_find` + three_way_path_set dedup.
- **P-11** `sit add` index upsert without full rewrite (needs patra UPSERT; if patra doesn't have it, push on their roadmap).
- **P-17** Buffered stdout.
- Re-run `docs/benchmarks/2026-04-24-baseline.md` after each change; gate merges on no regression.

### ADRs to write (concurrent with v0.5.2)

- **ADR 0003** — sit does not search upward for `.sit/` (CVE-2022-24765-shape; locks in correct behavior).
- **ADR 0004** — sit is SHA-256 only; no SHA-1 interop ever.
- **ADR 0005** — Local-clone threat model (symlink handling, allowed URL schemes, future HTTP notes).

### Cross-project backlog (from audit § Downstream)

- **patra** — `INSERT OR IGNORE` / `UPSERT` (unblocks P-11 / P-24), bound parameters for STR columns (unblocks the right fix for S-01), sized `patra_result_get_str_len` (S-31). Draft entries on patra's roadmap.
- **sigil** — `hex_decode` that strictly fails on invalid chars rather than partial decode (S-20). Flag SHA-256 software throughput; software vs hardware story.
- **sankoch** — `zlib_decompress_with_ratio_cap` primitive to give every consumer a one-call decompression bomb defense (S-08 root-cause fix).

### v0.7.0 — Network wire protocol + deferred bench fixtures

**Network wire protocol**

**Benchmarks** — three bench targets were scoped but deferred from v0.6.0 because they need larger fixtures or a companion algorithm change:

- **LCS diff** at 100×100 / 1000×1000 / 4000×4000 line counts. Shows the cost curve and the 16M-cell cliff; motivates the Myers O((N+M)D) fallback (P-14).
- **`glob_match`** against 10 / 50 / 200-pattern `.sitignore` files. Baseline for the P-13 pattern pre-classification refactor.
- **`hash_file_as_blob` end-to-end** on 1 KB / 64 KB / 1 MB inputs. Measures the true `sit add` floor and maps sigil's software-SHA-256 bottleneck.

Add these alongside the algorithm / transport work that justifies them.

- **HTTP transport** — sit-native JSON/REST (not git-wire-compatible). Likely shape: `GET /sit/v1/refs`, `GET /sit/v1/object/<hash>`, `POST /sit/v1/refs/<name>`, `POST /sit/v1/object`. Server is a thin patra-to-HTTP translator.
- **SSH transport** — run `sit-upload-pack` / `sit-receive-pack` over stdin/stdout (same pattern as git).
- **Pack bundles** — batch object transfer using sankoch delta primitives once patra grows the supporting storage. Reduces per-object network chatter.

### Longer horizon

- **Reject push to checked-out branch** — git's `receive.denyCurrentBranch = refuse` default. Today `sit push` silently advances the remote's ref while leaving its working tree stale; surprising when the remote is someone's active repo. Check whether the remote's HEAD resolves to the branch being pushed and refuse by default; opt-in escape via a config knob later.
- **`sit fsck` reachability** — walk commit chain and flag dangling objects (current implementation checks integrity but not reachability).
- **Full `.sitignore` semantics** — negation (`!pattern`), double-star (`**`), character classes (`[abc]`), anchored patterns (`/foo`), path patterns (`foo/bar`).
- **`sit log --graph`** — ASCII DAG for merge history.
- **Shallow clone** — `--depth N` limits to N commits back from HEAD.
- **Integration tests in-tree** — promote the shell-level scenarios from `docs/guides/getting-started.md` into `tests/` with fixtures. Current `tests/sit.tcyr` is primitive-assert smoke only.
- **sandhi migration** — cyrius 5.7.0 ships a first-party `sandhi` stdlib crate; migrate `cyrius.cyml`'s inline `stdlib = [...]` list when the release is out. Transitive dep resolution in the same release should also let us drop the expanded `thread`/`freelist`/`bigint`/`ct`/`keccak` entries.
