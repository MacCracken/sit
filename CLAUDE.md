# sit — Claude Code Instructions

> **Core rule**: this file is **preferences, process, and procedures** — durable rules that change rarely. Volatile state (current version, line counts, test counts, dep pins, in-flight work, consumers) lives in [`docs/development/state.md`](docs/development/state.md), bumped every release. Do not inline state here — inlined state rots within a minor.

---

## Project Identity

**sit** (Sanskrit: *smriti*, स्मृति — "that which is remembered") — sovereign version control, a Cyrius-native git replacement.

- **Type**: Binary (VCS tool)
- **License**: GPL-3.0-only
- **Language**: Cyrius (toolchain pinned in `cyrius.cyml [package].cyrius`; see [`docs/development/state.md`](docs/development/state.md) for the current pin)
- **Version**: SemVer; `VERSION` at the project root is the source of truth — do not inline the number here
- **Genesis repo**: [agnosticos](https://github.com/MacCracken/agnosticos)
- **Standards**: [First-Party Standards](https://github.com/MacCracken/agnosticos/blob/main/docs/development/applications/first-party-standards.md) · [First-Party Documentation](https://github.com/MacCracken/agnosticos/blob/main/docs/development/applications/first-party-documentation.md)
- **Shared crates**: [shared-crates.md](https://github.com/MacCracken/agnosticos/blob/main/docs/development/applications/shared-crates.md)

## Goal

Own the "track a codebase over time" job on AGNOS. No libgit2, no C, no FFI. Every layer — compression, hashing, storage, signing, protocol — is first-party Cyrius and benchmarked against its C incumbent.

Intentionally not on the AGNOS critical path. This is a post-boot, when-there's-time project.

## Current State

> Volatile state lives in [`docs/development/state.md`](docs/development/state.md) — current version, source layout stats, dep pins, command inventory, test counts, consumers, storage layout, recent shipped releases. Refreshed every release.
>
> Historical release narrative lives in [`CHANGELOG.md`](CHANGELOG.md).

This file (`CLAUDE.md`) is durable rules only. See [first-party-documentation § CLAUDE.md](https://github.com/MacCracken/agnosticos/blob/main/docs/development/applications/first-party-documentation.md#claudemd) for what belongs where.

## Scaffolding

Project was scaffolded with `cyrius init sit`. **Do not manually create project structure** — use the tools. If the tools are missing something, fix the tools.

## Quick Start

```bash
cyrius build src/main.cyr build/sit       # build
cyrius test tests/sit.tcyr                # unit tests
cyrius bench tests/sit.bcyr               # benchmarks
cyrius fuzz tests/sit.fcyr                # fuzz harness
cyrius lint src/*.cyr                     # static checks
cyrius audit                              # full check: self-host, test, fmt, lint
CYRIUS_DCE=1 cyrius build src/main.cyr build/sit   # dead-code-eliminated release build
```

## Key Principles

- **Correctness is the optimum sovereignty** — if it's wrong, you don't own it; the bugs own you.
- **First-party only, no FFI** — no libgit2, no C, no binding to OpenSSL / zlib / libsha. Every layer reimplemented in Cyrius and benchmarked against its C incumbent. See [ADR 0001](docs/adr/0001-no-ffi-first-party-only.md).
- **Git on-disk compatibility where it costs nothing** — object framing and tree format are byte-compatible with git's SHA-256 mode. Wire protocol and sitsig header are intentionally sit-native.
- Test after EVERY change, not after the feature is "done".
- ONE change at a time — never bundle unrelated changes.
- Research before implementation — check yukti / patra / the stdlib for existing patterns before inventing.
- Study working programs (`yukti/src/main.cyr`, `patra/programs/demo.cyr`) before writing new code.
- Programs call `main()` at top level: `var r = main(); syscall(SYS_EXIT, r);`
- **Build with `cyrius build`, never raw `cc5`** — the manifest auto-resolves deps and prepends includes.
- Source files only need project includes (`include "src/lib.cyr"`) — stdlib / external deps auto-resolve from `cyrius.cyml [deps]`.
- Every buffer declaration is a contract: `var buf[N]` = N **bytes**, not N entries.
- Fuzz every parser path — edge cases get invariants, not assertions.
- Benchmark before claiming perf — numbers or it didn't happen.
- **Cross-project feature requests go on the target repo's `docs/development/roadmap.md`, not GitHub issues** — these repos don't use the issue tracker. When sit needs something from a dep, draft a backlog entry for the dep's roadmap.

## Rules (Hard Constraints)

- **Read the genesis repo's CLAUDE.md first** — [agnosticos/CLAUDE.md](https://github.com/MacCracken/agnosticos/blob/main/CLAUDE.md).
- **Do not commit or push** — the user handles all git operations.
- **NEVER use `gh` CLI** — use `curl` to the GitHub API if needed.
- Do not add unnecessary dependencies. Every crate sit pulls in punches a hole in the no-FFI thesis if it ever drifts toward C.
- Do not skip tests before claiming changes work.
- Do not skip fuzz / benchmark verification before claiming a feature works.
- Do not use `sys_system()` with unsanitized input — command injection risk.
- Do not trust external data (file content, network input, user args) without validation.
- Do not use `break` in while loops with `var` declarations — use flag + `continue`.
- Do not add Cyrius stdlib includes in individual `src/*.cyr` files — the manifest's `[deps].stdlib` resolves them.
- Do not hardcode toolchain versions in CI YAML — the `cyrius = "X.Y.Z"` pin in `cyrius.cyml` is the only source of truth.
- **`cyrius.cyml` is a manifest, not a ledger or changelog** — keys and values only. Rationale goes in `docs/adr/` or `docs/architecture/`, history in CHANGELOG, and versions in `state.md`.
- Do not add `[deps.<name>]` git blocks for modules folded into the cyrius stdlib (sakshi / sankoch / sigil / patra / sandhi). The `cyrius` pin is the only version lever — see [ADR 0012](docs/adr/0012-deps-pinned-through-the-toolchain.md).
- Do not inline volatile state (versions, line counts, dep pins, command counts) into `CLAUDE.md` / `README.md` — that content lives in `docs/development/state.md` and rots fast if copied.
- **Anything that rewrites the worktree goes through `materialize_target_safe`** (or `_apply_conflicted_merge` on a conflict stop), which refuses a dirty tree, untracked files in the way and symlinked parents before writing anything. Forced `materialize_target` is for `reset --hard` and abort / restore paths only. The 2026-10-19 audit's data-loss findings were commands that skipped a check a sibling made — put new checks in the shared function, not the command.
- **`cmdit_*` calls live only in `src/main.cyr`** (or a future `src/cli.cyr`), never in a `[lib]` / `[lib.read]` module — the bundles ship every `cmd_*`, and owl / thoth must not inherit cmdit. A command keeps reading its own arguments; see [ADR 0015](docs/adr/0015-cli-dispatch-through-cmdit.md).
- **Repo-path writes go through the `sf_*` wrappers** (`sf_write_all`, `sf_unlink`, `sf_rename`, …), never a raw `file_write_all` / `xunlink` on a repo path — they are what refuses to write through a symlink.
- **"Does it exist?" is `lstat`'s question, not `sf_exists`'s** — `sf_exists` / `file_exists` mean *can be opened for reading*, so an unreadable file looks absent, and "absent → start fresh" then replaces it. Before merging into or replacing a file, ask `path_lstat_kind`, and treat exists-but-unreadable as an error ([architecture 007](docs/architecture/007-exists-means-readable.md)).
- **`[lib]` / `[lib.read]` modules use only public stdlib API.** Consumers pin older toolchains (owl: cyrius 6.6.2); a stdlib-internal `_name` that exists only in sit's pin breaks their build. Verify with the downstream check before a release.
- **Every object sit stores from elsewhere is verified before it lands; nothing is recompressed** — fetch / clone / pull and the server's push endpoint check each object's framing type and SHA-256 against its id (`_object_verify`, 1.7.6) and refuse the transfer on a mismatch, before any ref moves. A row travels and is stored as its raw compressed bytes; a packed object (ADR 0016) has no stored bytes of its own, so `db_object_read_raw` / `db_object_read_both` reconstruct and compress it once, as it leaves the store — the receiver never recompresses. The walk verifies commits and trees where it already inflates them, so only blobs pay an extra inflate; do not add a second inflate or hash of the same object on that path, and do not re-hash objects sit itself wrote (that is `fsck`'s job). The old rule ("do not re-hash during wire transfer") let a hostile server swap content behind a signed commit — see ADR 0006's 1.7.6 amendment.
- **sit writes nothing in a `.git/` repository.** Read-only commands open one through `cli_read_repo` (status, log, diff, show, reflog, cat-file); a command that writes keeps its `.sit/HEAD` gate, and a write sub-path of a read command (`reflog expire`) refuses in git mode. Read paths take id widths from `_id_hexlen()` / `_id_dup`, never a literal 64 (ADR 0011's 1.12.0 amendment).
- **Per-repository state is never process-global without a reset.** One process can open several repositories (the read API's `sit_repo_open`, `sit serve --repos`). A new cache of anything repository-specific is keyed by the resolved path or root, or is dropped in `store_repo_reset` / `index_db_reset` / a `store_ctx_*` context — through 1.10.1 the store and index handles were neither, and a second repository was read through the first one's.
- **Check every patra write status before anything points at the row** — an insert's or `patra_commit`'s refusal must fail the command before a ref moves, a hash is handed back, or a source copy is deleted. Since patra 1.16.2 a failed commit means the whole transaction rolled back, and a failed fdatasync is reported, not swallowed.
- **Every new object kind or ref / log location gets a root or edge in `fsck_collect_roots` / `fsck_walk_reachable`**, plus a test that deletes `.sit/logs` before `fsck --prune`. `--prune` deletes whatever the walk cannot reach, so a missing root is silent data loss.
- **Only `sit gc` replaces `objects.patra` or removes a pack, and only under the exclusive store lock** (`store_lock_exclusive`). Every store is opened through `get_object_db` / `remote_objects_open`, which take `.sit/objects.flock` shared first — a command holds it to exit, a long-lived process (`sit serve`, the read API) per request or call through `store_enter` / `store_leave`. A new path that calls `patra_open` on an object store directly must take it too, or a gc can rename the file out from under its writes ([architecture 008](docs/architecture/008-gc-runs-alone.md)). `fsck --prune` deletes rows only; a packed object is never pruned in place.

## Process

### P(-1): Scaffold / Project Hardening (before any new features)

1. **Cleanliness** — `cyrius build`, `cyrius lint`, `cyrius audit`; all tests pass.
2. **Benchmark baseline** — `cyrius bench`, save CSV for comparison.
3. **Internal deep review** — gaps, optimizations, correctness, docs.
4. **External research** — domain completeness, best practices, existing CVE patterns (git's CVE history is a rich source for VCS).
5. **Security audit** — input handling, syscall usage, buffer sizes, pointer validation. File findings in `docs/audit/YYYY-MM-DD-audit.md`.
6. **Additional tests / benchmarks** from findings.
7. **Post-review benchmarks** — prove the wins against step 2.
8. **Documentation audit** — ADRs for decisions made during hardening, source citations, guides for public commands.
9. **Repeat if heavy** — keep drilling until clean.

### Work Loop (continuous)

1. **Work phase** — new features, roadmap items, bug fixes.
2. **Build check** — `cyrius build src/main.cyr build/sit`.
3. **Test + benchmark additions** for new code.
4. **Internal review** — performance, memory, correctness, edge cases.
5. **Security check** — any new syscall usage, user input handling, buffer allocation.
6. **Documentation** — update CHANGELOG, roadmap, `docs/development/state.md`, any ADR the change earned.
7. **Version check** — `VERSION`, `cyrius.cyml`, CHANGELOG header in sync.
8. **dist bundles** — if the change touched any source file `cyrius.cyml [lib].modules` lists, run `cyrius distlib` and commit the regenerated `dist/sit.cyr` **in the same commit** as the source change. CI's `Verify dist/sit.cyr is in sync` step hard-fails otherwise. **Two profiles now**: `[lib]` → `dist/sit.cyr` (full) and `[lib.read]` → `dist/sit-read.cyr` (the lean read-only bundle for report-only consumers — thoth / owl — via `cyrius distlib read`). A touched file that is ALSO in `[lib.read].modules` must regenerate **both** — run `cyrius distlib && cyrius distlib read`. (`wire_ssh.cyr` / `wire_https.cyr` are in neither `[lib]` set — transport internals stay out of the consumer bundles, and nothing reachable from a `[lib]` module may call into them; see [ADR 0013](docs/adr/0013-dist-bundle-profiles.md) and [architecture 006](docs/architecture/006-bundle-closure.md).)
9. **Return to step 1.**

### Security Hardening (before every release)

Every release runs a security audit pass — see [first-party-standards § Security Hardening](https://github.com/MacCracken/agnosticos/blob/main/docs/development/applications/first-party-standards.md#security-hardening-new--required-before-every-release) for the canonical list. Minimum:

1. **Input validation** — every function accepting external data validates bounds, types, ranges. Particular attention for sit: commit/tree body parsing, hex decoding, ref-name sanitization, remote URL normalization.
2. **Buffer safety** — every `var buf[N]` verified; N is **bytes**, max access < N, no adjacent-variable overflow.
3. **Syscall review** — every syscall validated: args checked, returns handled, error paths complete. `syscall(SYS_CHDIR, ...)` in `cmd_clone` gets extra scrutiny.
4. **Pointer validation** — no raw pointer dereference of untrusted input without bounds.
5. **No command injection** — use `exec_vec()` with explicit argv; never `sys_system()` with unsanitized input. `cmd_owl_file` execs owl — args must remain controlled.
6. **No path traversal** — file paths from external input validated, no `../` escape. Tree entry names, index paths, `.sitignore` patterns, and remote URLs are all external data.
7. **Known CVE review** — check sakshi / sankoch / sigil / patra pins and git's CVE history for patterns worth reproducing checks against.
8. **Document findings** — all issues in `docs/audit/YYYY-MM-DD-audit.md`.

Severity levels: **CRITICAL** (remote / privilege escalation), **HIGH** (moderate effort), **MEDIUM** (specific conditions), **LOW** (defense-in-depth).

### Closeout Pass (before every minor/major bump)

Run a closeout pass before tagging `X.Y.0` or `X.0.0`. Ship as the last patch of the current minor (e.g. `0.5.9` before `0.6.0`).

1. **Full test suite** — all `.tcyr` pass, zero failures.
2. **Benchmark baseline** — `cyrius bench`, save CSV; compare against prior closeout.
3. **Dead code audit** — remove unused functions; record remaining floor in CHANGELOG. (The `build_commit` / `build_merge_commit` thin wrappers are intentional — the `*_signed` variants are the real builders.)
4. **Refactor pass** — consolidate the minor's additions where parallel codepaths / dispatch branches accreted. Watch for `cmd_*` sprawl across domain modules.
5. **Code review pass** — walk diffs end-to-end for missed guards, ABI leaks, off-by-ones, silently-ignored errors. Pay attention to any new patra / sigil / sankoch calls.
6. **Cleanup sweep** — stale comments, dead `#ifdef` branches, unused includes in `src/lib.cyr`, orphaned files.
7. **Security re-scan** — quick grep for new `sys_system`, unchecked writes, unsanitized input, buffer size mismatches, ref-name unchecked bytes.
8. **Downstream check** — owl (and any future consumer listed in `state.md`) still builds against the new version.
9. **Doc sync** — CHANGELOG, roadmap, `docs/development/state.md`, CLAUDE.md (if durable content changed).
10. **Version verify** — `VERSION`, `cyrius.cyml`, CHANGELOG header, intended git tag all match.
11. **Full build from clean** — `rm -rf build && cyrius deps && CYRIUS_DCE=1 cyrius build src/main.cyr build/sit` passes clean.

### Task Sizing

- **Low/Medium effort**: batch freely — multiple items per work loop cycle.
- **Large effort**: small bites only — break into sub-tasks, verify each before moving to the next. (The v0.5.1 file-split is a prototype of this pattern — one module per build cycle.)
- **If unsure**: treat it as large.

### Refactoring Policy

- Refactor when the code tells you to — duplication, unclear boundaries, measured bottlenecks.
- Never refactor speculatively. Wait for the third instance.
- Every refactor must pass the same test + fuzz + benchmark gates as new code.
- 3 failed attempts = defer and document — don't burn time in a rabbit hole.

## Cyrius Conventions

- All struct fields are 8 bytes (`i64`), accessed via `load64` / `store64` with offset.
- Heap allocation via `fl_alloc()` / `fl_free()` (freelist) for data with individual lifetimes.
- Bump allocation via `alloc()` for long-lived data (vec, str internals).
- Enum values for constants — don't consume `gvar_toks` slots (4,096 initialized globals limit).
- Heap-allocate large buffers — `var buf[256000]` bloats the binary by 256KB.
- `break` in while loops with `var` declarations is unreliable — use flag + `continue`.
- No negative literals — write `(0 - N)` not `-N`.
- No mixed `&&` / `||` in one expression — nest `if` blocks instead.
- Reserved names to avoid as variables: `match`, `in`, `pub`, `stack`, `callptr`.
- `return;` without value is invalid — always `return 0;`.
- All `var` declarations are function-scoped — no block scoping.
- Max limits per compilation unit: 4,096 variables, 1,024 functions, 4,096 initialized globals.
- Counting rule: only a top-level `var NAME = <non-literal>;` (call / identifier / expression initializer) consumes an initialized-globals slot; a bare integer-literal init (`var x = 42;`) takes the static-init fast path and enum members are const-folded, so neither counts. See the cyrius guide's **Global Initializers** section (`docs/guides/cyrius-guide.md` in the cyrius repo).
- Cyrius does **two-pass compilation** — include order in `src/lib.cyr` is logical grouping only; forward references resolve across the full source set.

## CI / Release

- **Toolchain pin**: `cyrius = "X.Y.Z"` field in `cyrius.cyml [package]`. No separate `.cyrius-toolchain` file. CI and release both read this; no hardcoded version strings in YAML.
- **Dead code elimination**: every release `cyrius build` runs with `CYRIUS_DCE=1`. Binary size is a release metric — track it in `state.md`.
- **Tag filter**: release workflow triggers on `tags: ['[0-9]+.[0-9]+.[0-9]+'` or `v[0-9]+.[0-9]+.[0-9]+']`. Non-semver tags do not ship a release.
- **Version-verify gate**: release asserts `VERSION == tag` before building. Mismatch fails the run. (`cyrius.cyml` pulls VERSION via `${file:VERSION}` so there's nothing else to sync.)
- **Lint step**: CI runs `cyrius lint` per source file. Advisory by default.
- **Workflow layout**:
  - `.github/workflows/ci.yml` — build, test, docs + version consistency, init/add/commit/fsck smoke, signed-commit smoke, wire-protocol (clone/push/re-clone) smoke; reusable via `workflow_call`.
  - `.github/workflows/release.yml` — version gate → CI gate → DCE build (x86_64 + best-effort aarch64) → `git archive` src tarball + SHA256SUMS → GitHub release with CHANGELOG extract as body, `prerelease: true` for 0.x tags.
- **Concurrency**: CI uses `cancel-in-progress: true` keyed on workflow + ref — only the latest push is tested.
- **State sync**: `docs/development/state.md` is hand-bumped per release until a post-hook exists. If the hook lands, fix it — don't maintain state by hand long-term.

## Docs

- [`docs/adr/`](docs/adr/) — architecture decision records. *Why did we choose X over Y?* Start with [0001 — no FFI](docs/adr/0001-no-ffi-first-party-only.md).
- [`docs/architecture/`](docs/architecture/) — non-obvious constraints and quirks a reader can't derive from the code. **Skim this before writing new code** — e.g. [001](docs/architecture/001-args-stack-buffer-lifetime.md) documents a stdlib `args.cyr` lifetime hazard that silently affects any `argv(n)` usage.
- [`docs/guides/`](docs/guides/) — task-oriented how-tos. [Getting started](docs/guides/getting-started.md) covers build + every shipped command.
- [`docs/examples/`](docs/examples/) — runnable examples. [`local-vcs-loop/`](docs/examples/local-vcs-loop/) is the canonical end-to-end walkthrough.
- [`docs/development/roadmap.md`](docs/development/roadmap.md) — **forward-looking backlog only**. Single source of truth for what sit does next. Work is **slotted by target version**: the current patch line (`1.7.x`) with one heading per planned patch, one section per planned minor (`1.8.0`, `1.9.0`, …), then `1.x — unscheduled` for anything not yet committed to a release. Upstream asks, on-hold items and "decided — do not re-attempt" notes follow the slots. **When an item ships, delete it** — CHANGELOG is the record, and struck-through entries are not. **When a slot slips, re-slot it** to the next version rather than leaving a stale number; at every release, re-check the line / count pins the remaining items cite.
- [`docs/development/state.md`](docs/development/state.md) — live state snapshot, refreshed every release.
- [`CHANGELOG.md`](CHANGELOG.md) — tagged-release source of truth for all changes.

New quirks and constraints land in `docs/architecture/` as numbered items (`NNN-kebab-case.md`). New decisions land in `docs/adr/` using [`template.md`](docs/adr/template.md). **Never renumber either series.**

Full doc-tree convention: [first-party-documentation.md](https://github.com/MacCracken/agnosticos/blob/main/docs/development/applications/first-party-documentation.md).

## Documentation Structure

```
Root files (required):
  README.md, CHANGELOG.md, CLAUDE.md, CONTRIBUTING.md,
  SECURITY.md, CODE_OF_CONDUCT.md, LICENSE,
  VERSION, cyrius.cyml

docs/ (minimum):
  adr/ — architectural decision records (README + template.md + NNNN-*.md)
  architecture/ — non-obvious invariants (README + NNN-*.md)
  guides/ — task-oriented how-tos
  examples/ — runnable examples
  development/
    roadmap.md — completed, backlog, future
    state.md — live state snapshot (volatile; release-bumped)

docs/ (when earned):
  audit/ — security audit reports (YYYY-MM-DD-audit.md)
  benchmarks.md — perf history (promoted from benchmarks-git-v-sit.md when it stabilizes)
  sources.md — academic / domain citations
  proposals/ — pre-ADR design drafts
  api/ — curated public-surface reference
```

## .gitignore (Required)

```gitignore
# Build
/build/
/dist/

# Resolved deps (auto-generated by cyrius deps)
lib/*.cyr
!lib/k*.cyr

# Release / toolchain artifacts
cyrius-*.tar.gz
*.tar.gz
SHA256SUMS

# IDE
.idea/
.vscode/
*.swp
*~

# OS
.DS_Store
Thumbs.db
```

## CHANGELOG Format

Follow [Keep a Changelog](https://keepachangelog.com/). Performance claims **must** include benchmark numbers. Breaking changes get a **Breaking** section with migration guide. Security fixes get a **Security** section with CVE references where applicable. See [first-party-documentation § CHANGELOG](https://github.com/MacCracken/agnosticos/blob/main/docs/development/applications/first-party-documentation.md#changelog) for the full conventions.

## Naming

The name is deliberate and stays:

- **smriti** (स्मृति) — memory, that which is remembered. The Sanskrit root.
- **Three letters**, same typing rhythm as `git`.
- **sit vs stand, park vs push** — the verb wordplay holds.
- **Phonetic echo of "symmetry"** — version control as mirrored state.
- Cultural thread with **sitar**, matching the AGNOS Sanskrit-leaning naming.
