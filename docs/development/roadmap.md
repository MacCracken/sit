# sit Development Roadmap

> **v0.5.0** — Wire protocol (local-path transport). Remotes, fetch, push across bare-path remotes. Network transports are v0.6.x work.

Historical per-sub-version notes were collapsed into the 0.4.0 entry; see [`CHANGELOG.md`](../../CHANGELOG.md) for the tagged artifact.

## Released

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

### v0.5.1 — File-split refactor

`src/main.cyr` is ~5700 lines in one flat file. That's been fine for bootstrap but needs to be broken up before v0.6.x network work adds another ~1000 lines. No features, no bug fixes beyond what the split itself surfaces.

Candidate module layout (read the code before committing to it):

- `src/object_db.cyr` — `object_db_open`, `write_typed_object`, `read_object`, loose-file migrator, `db_*` parameterized variants
- `src/index.cyr` — `parse_index`, `rewrite_index`, `index_upsert`, plaintext migrator
- `src/commit.cyr` — `build_commit*`, `build_merge_commit*`, `parse_commit_body`, `print_commit_header`
- `src/refs.cyr` — `read_head_ref`, `write_head_ref`, `resolve_ref_name`, `resolve_hash`, `ensure_parent_dirs`
- `src/tree.cyr` — `build_tree`, `parse_tree`, `flatten_tree`, entry accessors
- `src/diff.cyr` — `lcs_diff`, `split_lines`, `annotate_ops`, hunk grouping, `print_file_diff` / `print_file_stat`
- `src/sign.cyr` — key paths, `sign_commit_body`, `extract_sitsig`, `verify_commit_body`, `cmd_key`, `cmd_verify_commit`
- `src/wire.cyr` — remote config, `walk_reachable_*`, `copy_objects`, `cmd_remote/fetch/pull/push/clone`
- `src/main.cyr` — `print_usage`, dispatch, and the `main()` wrapper only

Cyrius composes sources via `include "path/to/file.cyr"` (see stdlib `hashmap.cyr` for the pattern); `cyrius.cyml [build].entry` stays pointed at `src/main.cyr`. No new ADR needed — this is a mechanical file split, not an architectural decision.

### v0.6.0 — Network wire protocol

- **HTTP transport** — sit-native JSON/REST (not git-wire-compatible). Likely shape: `GET /sit/v1/refs`, `GET /sit/v1/object/<hash>`, `POST /sit/v1/refs/<name>`, `POST /sit/v1/object`. Server is a thin patra-to-HTTP translator.
- **SSH transport** — run `sit-upload-pack` / `sit-receive-pack` over stdin/stdout (same pattern as git).
- **Pack bundles** — batch object transfer using sankoch delta primitives once patra grows the supporting storage. Reduces per-object network chatter.

### Longer horizon

- **`sit fsck` reachability** — walk commit chain and flag dangling objects (current implementation checks integrity but not reachability).
- **Full `.sitignore` semantics** — negation (`!pattern`), double-star (`**`), character classes (`[abc]`), anchored patterns (`/foo`), path patterns (`foo/bar`).
- **`sit log --graph`** — ASCII DAG for merge history.
- **Shallow clone** — `--depth N` limits to N commits back from HEAD.
- **Integration tests in-tree** — promote the shell-level scenarios from `docs/guides/getting-started.md` into `tests/` with fixtures. Current `tests/sit.tcyr` is primitive-assert smoke only.
- **sandhi migration** — cyrius 5.7.0 ships a first-party `sandhi` stdlib crate; migrate `cyrius.cyml`'s inline `stdlib = [...]` list when the release is out. Transitive dep resolution in the same release should also let us drop the expanded `thread`/`freelist`/`bigint`/`ct`/`keccak` entries.
