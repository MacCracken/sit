# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

[Unreleased]: https://github.com/MacCracken/sit/compare/0.5.1...HEAD
[0.5.1]: https://github.com/MacCracken/sit/releases/tag/0.5.1
[0.5.0]: https://github.com/MacCracken/sit/releases/tag/0.5.0
[0.4.0]: https://github.com/MacCracken/sit/releases/tag/0.4.0
