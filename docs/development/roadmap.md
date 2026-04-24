# sit Development Roadmap

> **v0.1.0** — Sovereign version control for Cyrius. Scaffold + `init` + `add` loop working; `sit commit` is the next move.

## Completed

### v0.1.0

- Initial project scaffold via `cyrius init sit` — stdlib baseline, test/bench/fuzz harnesses, CI workflows.
- `cyrius.cyml` dep layout following yukti conventions — sakshi 2.1.0, sankoch 2.0.1, sigil 2.9.1, patra 1.5.5 git-tag pinned. Expanded stdlib list to cover transitive reach of the git deps (cyrius 5.6.x has no transitive resolution; 5.7.x targeted).
- `sit init` — creates git-parity `.sit/{HEAD,objects,refs/heads}` layout; HEAD is `ref: refs/heads/main\n`; idempotent re-init.
- `sit add <path>` — sigil SHA-256 object IDs, sankoch zlib compression, loose-object storage at `.sit/objects/<hex[0:2]>/<hex[2:64]>`. Framing is `"blob <len>\0<content>"` — hashes are byte-identical to git's SHA-256 object format for the same content. Plaintext staging index at `.sit/index`.
- Documentation scaffold: `docs/{adr,architecture,guides,examples,development}/`.
- ADR 0001 — no FFI, first-party only.
- Arch 001 — `args.cyr` post-return stack memory quirk (Cyrius stdlib).
- Arch 002 — loose-file objects until patra grows `COL_BLOB`.

### v0.1.1

- **`sit cat-file <hash>`** — plumbing read command. Decompresses an object, strips framing, writes content to stdout. Supports 4-char-minimum hash prefixes via `dir_list` scan of `.sit/objects/<xx>/`. Reports ambiguous / no-match / too-short errors with distinct exit messages.
- **`sit owl-file <hash>`** — decorated viewer. Resolves the object, writes content to `/tmp/sit-owl-<hash[0:12]>`, execs [owl](https://github.com/MacCracken/owl) via `exec_vec` at `/usr/local/bin/owl` → `/usr/bin/owl` → `/opt/owl/bin/owl`. Transparent fallback to raw content when owl is not installed (owl is currently pre-1.0 per its own roadmap).
- Internal helpers: `object_path()`, `resolve_hash()`, `read_object()`, `find_owl()`, `resolve_and_read()` shared by both read commands.

### v0.1.2 — `sit commit`

- **`sit commit [-m] <message>`** — writes a tree object from the staging index plus a commit object, and atomically updates `.sit/refs/heads/main`. Supports both positional (`sit commit "msg"`) and `-m` forms.
- **Refactor**: `write_blob_object` now delegates to a type-agnostic `write_typed_object(type, type_len, content, content_len)` — same primitive drives blob, tree, and commit writes. Blob hashes unchanged (verified via regression).
- **Tree format** is git-SHA-256 compatible: `<mode> <name>\0<32 raw hash bytes>` entries, sorted by name. Mode fixed at `100644` for v0.2 (no exec-bit detection). Verified byte-by-byte against `xxd` output.
- **Commit format** is git-compatible: `tree <hex>\n[parent <hex>\n]author ... committer ... \n<message>\n`. Author/email from `SIT_AUTHOR_NAME` / `SIT_AUTHOR_EMAIL` env, fallback `"sit user" <user@localhost>`. Timestamp via `clock_epoch_secs()`, timezone fixed at `+0000`.
- **Dedup on stage**: `sit add foo.txt; sit add foo.txt; sit commit` produces a tree with one `foo.txt` entry (last hash wins), not two.
- **Root-commit marker**: output reads `[main (root-commit) <hash>] <msg>` when no parent exists, `[main <hash>] <msg>` otherwise.
- Arch 003 — subdirectory paths deferred to v0.3.0 (recursive trees); commit rejects nested paths with a clear error.

### v0.1.3 — `sit log`

- **`sit log`** — walks `HEAD` → `refs/heads/main` → parent pointers, printing each commit in git-style format (`commit <hex>`, `Author: NAME <EMAIL>`, `Date: <ISO-8601>`, blank line, indented message). Uses `iso8601()` from the chrono stdlib for date rendering.
- **Commit body parser** — line-based walk extracting `parent <hex>\n` and `author <line>\n`; `parse_author_line` splits the author identity (up to `>`) from the trailing timestamp and timezone. `print_indented_message` handles multi-line messages with git's 4-space indent convention.
- **Fix**: `read_object` now sizes its decompression buffer from the compressed input (256× upper bound, capped at 16 MB) instead of unconditionally allocating 16 MB. The old code exhausted the bump allocator after ~15 calls — caught when walking a two-commit history segfaulted on the second `read_object`. Dynamic sizing lets `sit log` scale to arbitrarily long histories.
- Handles empty repo ("no commits yet"), root commit (walk terminates when `parent_hex` stays 0), and multi-line commit messages (each physical line gets indented).

### v0.1.4 — `sit status` + tree reader

- **`sit status`** — three-way diff across HEAD tree, staging index, and working directory. Reports "Staged for commit" (index vs HEAD), "Unstaged changes" (working vs index), and "Untracked files" (in working, absent from both index and HEAD). Emits `nothing to commit, working tree clean` when all three categories are empty.
- **Tree reader**: `parse_tree(body, body_len)` walks `<mode> <name>\0<32 raw hash bytes>` entries and returns a vec of 24-byte entries holding `(mode_ptr, name_ptr, hash_hex_ptr)`. `read_head_tree_entries()` composes `read_main_ref` → `read_object` → tree-hash extraction → `parse_tree` in one call. Shared with future `sit diff` and (eventually) recursive-tree construction.
- **Working-dir walker**: `list_working_files()` uses stdlib `dir_list` + `is_dir`, filters dotfiles (including `.sit/`) and directories. Paired with `hash_file_as_blob` — hashes a working-tree file through the same `"blob <len>\0<content>"` framing as `sit add` so index-vs-working comparisons are hash equality, not content comparison.
- **Dedup at read time**: `cmd_status` sorts + dedupes the index (same helpers as `cmd_commit`) before walking it, so a path that was `sit add`'d twice appears once in status output. Without this the status output double-counted re-staged files.
- **Deletion detection**: index entry whose path is missing in the working tree shows as `Unstaged changes: deleted: <path>`.
- Covers nine scenarios: empty repo, untracked-only, staged-new, clean-after-commit, modified-unstaged, re-staged-after-modify, multi-mixed (staged + unstaged + untracked), deleted, outside-repo.

### v0.1.5 — `sit diff`

- **`sit diff`** (default) — line-level diff of working tree vs staging index. For each index entry: hash the working file; if hashes differ (or the working file is missing), read both blobs and run an LCS-based diff.
- **`sit diff --staged`** — index vs HEAD tree. Each index entry compared to HEAD's matching tree entry; entries absent from HEAD show as new-file insertions, entries whose HEAD hash differs from the index hash get a full line diff.
- **LCS algorithm**: classical DP table, `lines_equal` for cell comparison, backtrace to produce an op-script (`keep` / `delete` / `insert`). Script is reversed before emission so output reads top-to-bottom. Capped at 16M cells (≈128 MB table) — larger files fall through with a clear message.
- **Output**: `--- a/<path>` / `+++ b/<path>` header followed by the script with ` ` / `-` / `+` prefixes per line. No `@@` hunk headers in v0.2 — all context lines are printed; hunk grouping waits for a later pass.
- **Primitives**: `split_lines`, `lines_equal`, `lcs_diff`, `print_file_diff`, `read_blob_content` (thin wrapper around `read_object` that returns just the content span). Reusable for future `sit show`, `sit blame`, etc.
- Eight scenarios verified: clean repo, modified staged file, post-commit working divergence, `--staged` clean, `--staged` new-file adds, working deletion, multi-file mixed, outside-repo.

### v0.1.6 — Recursive trees

- **`build_tree(entries, prefix_len)`** replaces `build_flat_tree`. Recursive writer that walks sorted index entries, groups consecutive entries sharing the next path segment, emits a subtree for each group, and produces the current level's tree with `40000` entries for directories and `100644` for files. Mode `40000` matches git's wire format (no leading zero for dirs).
- **No custom sort comparator needed.** Lexical sort of full paths produces correct per-tree git order when walked depth-first: at any tree level, `name/` vs sibling `name.x` sorts identically under both byte-wise comparison of full paths and git's directory-trailing-`/` rule.
- **`flatten_tree(hex, prefix, out)`** — recursive reader. Walks subtrees transparently; emits one flat entry per file with the full repo-relative path (e.g., `src/main.cyr`) in the `name` slot. `read_head_tree_entries` now composes this. Callers (`tree_find`, status, diff) don't change.
- **`list_working_walk(prefix, fs_path, out)`** — recursive working-dir walker. Skips dotfiles (catches `.sit`, `.git`, `.env`). Emits full repo-relative paths matching the index/HEAD path convention.
- **Arch 003 resolved.** `cmd_commit`'s flat-paths rejection is gone; `entries_have_subdirs` deleted; `sit add src/main.cyr && sit commit` works end-to-end.
- Verified against an 8-test matrix with nested structure (`src/`, `src/lib/`, `docs/`): root tree has correct `100644 README.md / 40000 docs / 40000 src` layout (byte-verified via hexdump), status+diff see nested files correctly, log + commit chain work across subdirectory layouts.

### v0.1.7 — Hunk grouping in `sit diff`

- **`annotate_ops(ops)`** — tags each LCS op with `(old_line, new_line)` 1-indexed line numbers. `keep` advances both, `delete` advances only old, `insert` advances only new.
- **`group_hunks(annotated, ctx)`** — canonical unified-diff hunk grouper. Buffers up to `ctx` recent keeps as leading context; extends a hunk while keeps-since-last-change stays `<= 2*ctx`; on the `(2*ctx)+1`-th keep, trims trailing keeps to `ctx` and starts the next hunk with the overshoot keep as new leading context. Default `ctx=3` matches git.
- **`@@ -oldstart,oldlen +newstart,newlen @@`** headers emitted per hunk. `hunk_ranges` computes ranges by walking the hunk once (first-keep-or-delete → `old_start`; first-keep-or-insert → `new_start`; counts derive len). Pure-insertion hunks correctly print `-0,0` (new-file case).
- Verified against six scenarios: mid-file single change, adjacent changes merged, far-apart changes split, start-of-file (0 leading context), end-of-file (0 trailing context), pure new-file insertion (`@@ -0,0 +1,N @@`).

## Post-0.1 Backlog

### Priority — the v0.2.0 loop

- **`sit show <commit>`** — combines `cat-file` + diff-against-parent for a single commit. All primitives already in place; hunk-grouped diff from v0.1.7 provides the right output shape.
- **HEAD-aware branch selection** — `sit commit` / `sit log` / `sit status` currently hardcode `refs/heads/main`. Needs HEAD parsing (`ref: refs/heads/<branch>`).

### Working-tree visibility

- **`sit status`** — diff working tree vs staging index vs HEAD.
- **`sit log`** — walk commit parent chain from HEAD, print summary.
- **`sit diff`** — sankoch-backed text diff between two blobs / working tree / index.

### Storage migrations

- **Staging index into patra** — `index(path STR, hash STR, mode INT)` table. Fits current `COL_STR`/`COL_INT`, unblocks mutation semantics (`sit rm`, re-add updates existing row instead of appending). Likely the first real patra consumer in sit.
- **Objects into patra** — contingent on patra's roadmap `COL_BLOB` landing. Migrates sit off the loose-file object store; see [arch 002](../architecture/002-loose-objects-until-patra-blobs.md).
- **Pack format** — delta-compressed multi-object storage for density; depends on `COL_BLOB` and on sankoch delta primitives. Deferred until the simple store proves out.

### Network / interop

- **Wire protocol** — first-party smart-HTTP / ssh replacement. Not on the AGNOS critical path; revisit once the local VCS loop is solid.
- **Signed commits** — sigil-backed signatures on commit objects.

### Quality

- **Integration tests in-tree** — promote the shell-level smoke tests from `docs/guides/getting-started.md` into `tests/` with fixtures. Current `tests/sit.tcyr` is stdlib-assert smoke only.
- **`sit fsck`** — verify object hashes, walk commit chain, report corruption.
