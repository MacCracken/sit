# sit — Live State Snapshot

> Volatile state for this project. Refreshed every release. Do not inline this content into `CLAUDE.md` or `README.md` — they're durable rules only.
>
> Historical release narrative lives in [`CHANGELOG.md`](../../CHANGELOG.md). This file is a point-in-time snapshot.

## Current

- **Version**: 0.6.2 (read `VERSION` for the authoritative number)
- **Cyrius toolchain**: 5.6.35 (pinned in `cyrius.cyml [package].cyrius`)
- **Status**: Security hardening MEDIUM batch shipped (S-16/17/18/19/20/22/23/25/27 from the 2026-04-24 P(-1) audit). All P(-1) CRITICAL/HIGH/MEDIUM closed. v0.6.3 is LOW-severity + hygiene; then v0.6.x perf arc (folds in deferred S-24 with the patra-handle-caching refactor); then v0.7.0 network transport
- **Primary target**: Linux x86_64. aarch64 cross-build is best-effort in CI

## Source layout

14 files total, 6699 lines (up from 13 files / 5972 lines in 0.5.1 — v0.6.0 added `validate.cyr` and wired call-sites across most existing modules).

| File | Lines | Responsibility |
|------|------:|----------------|
| `src/main.cyr` | ~112 | `print_usage`, `main()`, dispatch, trailer |
| `src/lib.cyr` | ~20 | include chain (domain modules; stdlib auto-includes via `cyrius.cyml`) |
| `src/util.cyr` | ~200 | `eprintln`, `ensure_dir`, `ensure_parent_dirs`, `write_decimal`, `argv_heap`, `skip_ws`, `strcmp_cstr`, `sort_cstrings`, `read_file_heap`, `write_sanitized` (S-21) |
| `src/validate.cyr` | ~320 | **NEW in 0.6.0.** Pure validators: `hex_prefix_valid`, `refname_valid`, `tree_entry_name_valid`, `tree_flat_path_valid`, `tree_entry_mode_valid`, `config_value_valid`, `config_key_valid`, `remote_url_valid`, `path_is_symlink`, `path_lstat_kind` |
| `src/config.cyr` | ~335 | `config_*` helpers + `cmd_config` |
| `src/object_db.cyr` | ~568 | patra object store, `resolve_hash`, `read_object`, framing + compression, `cat-file` / `owl-file` / `fsck` (owl tempfile hardening in 0.6.0) |
| `src/index.cyr` | ~607 | staging index + `.sitignore` + `cmd_add/rm/reset` |
| `src/refs.cyr` | ~578 | HEAD/branch/tag/resolve + `cmd_branch/checkout/tag` (ref-name + hex validation in 0.6.0) |
| `src/tree.cyr` | ~320 | `parse_tree`, `build_tree`, `flatten_tree` (depth-capped), entry accessors |
| `src/diff.cyr` | ~1065 | LCS, hunks, working walker + `cmd_diff/show/status` (LCS dim pre-check in 0.6.0) |
| `src/commit.cyr` | ~612 | builders, parsers, `cmd_commit/log` (author sanitization in 0.6.0) |
| `src/merge.cyr` | ~682 | 3-way merge, conflict markers, `cmd_merge` |
| `src/sign.cyr` | ~312 | ed25519 signing + `cmd_key/verify-commit` (O_EXCL in 0.6.0) |
| `src/wire.cyr` | ~830 | remote config, reachability (depth-capped), `cmd_remote/fetch/pull/push/clone` (symlink guards + URL allowlist in 0.6.0) |

## Commands shipped

**24 total.** `init`, `add`, `rm`, `branch`, `checkout`, `tag`, `merge` (`-S`), `reset`, `commit` (`-S`), `config`, `fsck`, `key`, `verify-commit`, `remote`, `fetch`, `pull`, `push`, `clone`, `log`, `status`, `diff`, `show` (`--stat`), `cat-file`, `owl-file`.

## Tests

- **Unit**: `tests/sit.tcyr` — **101 assertions** (up from 31 in 0.5.x). Covers sigil SHA-256 known-answers, git-SHA-256 blob framing, hex encode/decode, sankoch zlib roundtrip, patra COL_BYTES small + 16KB overflow, ed25519 sign/verify roundtrip with bit-flip negatives, and the v0.6.0 validator suite: refname / tree-entry-name / tree-flat-path / hex-prefix / config-value / remote-URL positive + negative cases.
- **Integration**: shell-level via `docs/examples/local-vcs-loop/walkthrough.sh` and CI smoke steps (init → add → commit → log → fsck, signed commit + verify, clone → push → re-clone round trip).
- **Benchmarks / fuzz**: `tests/sit.bcyr` (sigil + sankoch primitives), `tests/sit.fcyr` (random inputs through hash / zlib / hex_decode).

## Dependencies (current pins)

All git-tag pinned in `cyrius.cyml`. No FFI, no C, no libgit2 — see [ADR 0001](../adr/0001-no-ffi-first-party-only.md).

- **sakshi** 2.1.0 — tracing, error handling
- **sankoch** 2.0.3 — LZ4/DEFLATE/zlib/gzip (bumped from 2.0.1 in v0.6.1; 2.0.3 fixes the zlib compress/decompress symmetry bug that lost ~20% of objects on a 100-commit fixture — see [`issues/archived/2026-04-24-read-object-unreadable-at-scale.md`](issues/archived/2026-04-24-read-object-unreadable-at-scale.md))
- **sigil** 2.9.1 — SHA-256 + ed25519 signing
- **patra** 1.6.0 — B+ tree / WAL object store (COL_BYTES since 1.6.0)

**Cyrius stdlib declared explicitly** in `cyrius.cyml [deps].stdlib` because 5.6.x has no transitive resolution (fix targeted for 5.7.0's `sandhi` stdlib crate). Current list: `string`, `fmt`, `alloc`, `io`, `vec`, `str`, `syscalls`, `assert`, `fs`, `args`, `chrono`, `hashmap`, `process`, `tagged`, `fnptr`, `thread`, `freelist`, `bigint`, `ct`, `keccak`, `bench`. Entries past `hashmap` exist for patra / sigil's transitive reach.

## Storage layout (sit repos on disk)

- **`.sit/HEAD`** — symbolic ref (`ref: refs/heads/main\n`)
- **`.sit/refs/heads/<name>`** — branch ref, 64-char hex + `\n`
- **`.sit/refs/tags/<name>`** — tag ref, same format
- **`.sit/refs/remotes/<remote>/<branch>`** — remote-tracking ref
- **`.sit/objects.patra`** — patra DB, schema `objects(hash STR, ty INT, content BYTES)`
- **`.sit/index.patra`** — staging index, schema `entries(path STR, hash_hex STR)`
- **`.sit/config`** — local config (`user.name`, `user.email`, `remote.<name>.url`)
- **`~/.sitconfig`** — global config (same format)
- **`~/.sit/signing_key`** (0600) / `~/.sit/signing_key.pub` (0644) — ed25519 seed + pubkey hex
- **`.sit/MERGE_HEAD`** — in-progress merge marker (cleared on commit or `--abort`)
- **Legacy**: `.sit/objects/<xx>/<yy...>` loose files and plaintext `.sit/index` auto-migrate on first access — see [arch 002](../architecture/002-loose-objects-until-patra-bytes.md)

## Recent shipped releases

| Version | Date | Summary |
|---------|------|---------|
| 0.6.2 | 2026-04-25 | Security hygiene MEDIUM batch from the 2026-04-24 audit. `alloc_or_die` helper + 52-site swap (S-17). Materialize / merge / commit / clone now fail loudly on FS-mutation errors instead of silently producing partial state (S-16, S-27). Author-line + sitsig parsers hardened against integer overflow + partial hex decode (S-18, S-19, S-20). `cmd_clone` requires `--force-absolute` for absolute targets (S-23). Index-migrate caps per-line path length at 4096 (S-22). Latent `ensure_dirs_for` mkdir("") bug removed (S-25). |
| 0.6.1 | 2026-04-25 | S-33 fix release. Pure dep-pin bumps — sankoch 2.0.1 → 2.0.3 (zlib symmetry) + cyrius 5.6.25 → 5.6.35 (allocator grow defense-in-depth). Status / fsck / clone clean on 100-commit / 100-file fixture. `bench_status` + `bench_clone` re-enabled. New `docs/development/issues/` for upstream-bug writeups. |
| 0.6.0 | 2026-04-24 | Security hardening: all CRITICAL + HIGH findings from the 2026-04-24 P(-1) audit fixed. `validate.cyr` with every input validator. Tree-entry / refname / hex / config / URL gating. Symlink guards on clone paths. Output escape filter. 101 assertions (from 31). 3 new ADRs. |
| 0.5.1 | 2026-04-24 | File-split refactor: `src/main.cyr` → 11 topical modules via `src/lib.cyr`. Zero feature changes. |
| 0.5.0 | 2026-04-24 | Wire protocol (local-path): `remote`, `fetch`, `pull`, `push`, `clone` + nested branch names + `sit merge -S` + `resolve_ref_name` sees `refs/remotes/*`. |
| 0.4.0 | 2026-04-24 | First official release. Rolls up the entire pre-release development arc (scaffold → local VCS → signed commits) into a single tagged artifact. |

Full history in [`CHANGELOG.md`](../../CHANGELOG.md). Forward-looking items in [`roadmap.md`](roadmap.md).

## Consumers / integration

- **owl** (pre-1.0, downstream) — consumes sit for git-marker gutter decorations once both ship. sit's `owl-file` command falls back to raw content when owl isn't on PATH.

## Known footguns (tracked)

See [roadmap.md § Longer horizon](roadmap.md#longer-horizon) for the full list. Highlights:

- **Push to checked-out branch** — sit silently advances the remote's ref while leaving its working tree stale. Git rejects this by default (`receive.denyCurrentBranch=refuse`); sit should follow suit.
- **`sit fsck` reachability** — only checks integrity today, not reachability (no dangling-object detection).
- **Gitignore semantics incomplete** — no negation (`!pattern`), no `**`, no char classes.
