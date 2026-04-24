# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

[Unreleased]: https://github.com/MacCracken/sit/compare/0.4.0...HEAD
[0.4.0]: https://github.com/MacCracken/sit/releases/tag/0.4.0
