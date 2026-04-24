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
- Arch 002 — loose-file objects until patra grows `COL_BYTES` (patra keeps `COL_BLOB` as an alias for the habit crowd).

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

### v0.1.8 — `sit show`

- **`sit show [<hash>]`** — prints a single commit: log-style header (author, date, indented message) + diff against parent. No-arg defaults to HEAD; accepts any hash prefix ≥ 4 chars via `resolve_hash`.
- **Refactor**: extracted `parse_commit_body(body, len, out)` (56-byte struct: tree_hex, parent_hex, author identity + ts + tz, msg_start) and `print_commit_header(hex, info, body, len)` from the inline `cmd_log` logic. Both `cmd_log` and `cmd_show` now compose them.
- **`commit_tree_entries(commit_hex)`** — loads a commit → its tree → flattened entries vec. Used for both "this commit's files" and "parent commit's files" in the diff pass.
- **Diff pass**: walk new entries (emit new-file diff for paths missing from parent, modified diff for differing hashes) then walk old entries (emit deletion diff for paths missing from new). Each file goes through `print_file_diff` so hunk grouping applies uniformly.
- Verified against seven scenarios: empty repo, root commit (new-file hunks, `@@ -0,0 +1,N @@`), modification commit (hunk-grouped diff), hash-prefix resolution, multi-file commit (two files, two diffs), bad hash, outside-repo.

### v0.1.9 — `sit rm` + staged deletions

- **`sit rm [--cached] <path>`** — removes `<path>` from the staging index and (unless `--cached`) from the working tree. Errors with `'<path>' is not tracked` if the path is neither in the index nor HEAD's tree.
- **`rewrite_index(entries)`** — truncates and re-serializes `.sit/index` from a vec of entries. Handles the zero-entries case by writing an empty file. First index-mutating helper; opens the door for future unstage/reset commands.
- **`cmd_status` HEAD-walk**: files in HEAD but not in the index now render as `Staged for commit: deleted: <path>`. Covers both `sit rm <path>` (working also gone) and `sit rm --cached <path>` (working retained but untracked, HEAD entry triggers the flag).
- **`cmd_diff --staged` HEAD-walk**: same logic, emits full-file `@@ -1,N +0,0 @@` deletion diffs for index-absent HEAD paths.
- **`cmd_diff` path corrected**: early-return on empty index moved past the HEAD-deletion pass so `sit diff --staged` works even when every file is rm'd.
- Verified against six scenarios: rm-untracked error, rm-tracked end-to-end (working + index + status + diff), commit-then-verify-tree-omits-file, `--cached` semantics (status correctly separates Staged-deleted from Untracked since HEAD still contains the on-disk file), rm of an already-manually-deleted file.

### v0.1.10 — `.sitignore`

- **`.sitignore`** at the repo root, read by `load_sitignore()`. Blank lines and `#`-comments are skipped; trailing `/` on a pattern is stripped (directory-only hints not enforced in v1).
- **`glob_match(pat, name)`** — recursive single-segment glob matcher with `*` (any run) and `?` (exactly one char). Operates on a single segment so `*` never crosses `/`.
- **`is_ignored(path, patterns)`** — segment-level check: a pattern without `/` matches any segment of the path. `build` ignores `build/`, `src/build/`, and `lib/build/foo.cyr` alike — simple and matches the 80% use case. Anchored (`/build`) and path-patterns (`src/build`) are v2.
- **`list_working_walk` behavior change**: previously skipped all dotfiles blanket-style. Now only hardcodes `.sit/`; everything else is included unless matched by a pattern. Ignored *directories* aren't descended into (no wasted I/O on `node_modules`/`build`).
- **`cmd_add`** now rejects ignored paths with `sit: '<path>' matches a .sitignore pattern` — git's behavior, without `-f` override yet.
- **`.sitignore` is itself trackable** — not auto-ignored; users `sit add .sitignore` normally.
- Verified against ten scenarios: dotfile visibility without `.sitignore`, `.env`/`build`/`*.log`/`*.tmp` ignore patterns, nested-dir non-recursion, `sit add` rejection, tree omits ignored files on commit, `*` boundary (`*.log` vs `logfile`), `?` single-char semantics, blank/comment lines, empty `.sitignore`.

### v0.1.11 — `sit diff HEAD`

- **`sit diff HEAD`** — working tree vs HEAD tree, skipping the index. Complements the existing `sit diff` (working vs index) and `sit diff --staged` (index vs HEAD): diff HEAD is `diff + diff --staged` combined into one view, answering "what's the total change since my last commit?".
- Walks HEAD entries: modified files → line diff; missing files → full-deletion diff. Then walks `list_working_files()` (which already respects `.sitignore`): paths not in HEAD → full-addition diff.
- Pre-req for owl's gutter-marker integration — owl will call this per file to paint changed lines.
- Verified against six scenarios: clean tree, combined staged+unstaged change (shows both), working-deletion, untracked-file addition, `.sitignore` respected for new files, no-commits-yet repo (HEAD-empty → all working files shown as additions).

### v0.2.0 — HEAD-aware branch resolution

- **`read_head_ref_path()`** — parses `.sit/HEAD` as `ref: refs/heads/<branch>\n`, returns the ref path ("refs/heads/main") or 0 on detached/malformed HEAD.
- **`read_head_ref()`** + **`write_head_ref(hex)`** — compose the ref path with `.sit/` to read/write the branch's commit hex. Drop-in replacements for the old `read_main_ref` / `write_main_ref` hardcodes.
- **`current_branch_name()`** — strips `refs/heads/` prefix off the ref path for display. Falls back to `(detached)` for non-branch HEAD.
- **Everywhere-refactor**: `cmd_commit`, `cmd_log`, `cmd_status`, `cmd_show`, `cmd_diff`, and `read_head_tree_entries` all route through the new helpers. Status's `On branch main\n` and commit's `[main ...]` are now dynamic.
- Verified against seven scenarios: main-branch regression, manual HEAD retarget to `dev`, commit lands on correct ref (main untouched), log follows active branch, switch back via HEAD edit, new-branch creation by committing with HEAD pointing at a nonexistent ref (creates `refs/heads/<name>` on write), malformed HEAD shows `(detached)` and commit errors out cleanly.

### v0.2.1 — `sit branch` + `sit checkout`

- **`sit branch`** (no args) — lists branches at `.sit/refs/heads/`, alphabetically sorted, current one prefixed with `* `. Uses new `sort_cstrings` helper (insertion-sort over a cstring vec).
- **`sit branch <name>`** — creates `.sit/refs/heads/<name>` pointing at HEAD's current commit. Errors if branch already exists or if no commits exist yet.
- **`sit checkout <branch>`** — switches to target branch. Full flow:
    1. Resolve target ref path + read its commit hex.
    2. No-op if already on target.
    3. Dirty check via `is_dirty()` — blocks if index differs from HEAD or working differs from index.
    4. Collision check — any untracked working file that the target tree contains → error ("would be overwritten").
    5. Delete files present in current HEAD tree but not in target.
    6. Write target tree's blob content to working paths, creating parent dirs via `ensure_dirs_for`.
    7. Rewrite `.sit/index` to exactly match target tree (hex→raw bytes via `hex_decode`).
    8. Update `.sit/HEAD` via `set_head_ref(target_ref)`.
- **`is_dirty()`** — factors the dirty detection used by checkout; reuses `parse_index` + `read_head_tree_entries` + `hash_file_as_blob` in the same pattern as `cmd_status`.
- **`ensure_dirs_for(path)`** — `mkdir -p`-style helper walking the path and `ensure_dir`-ing each prefix at each `/`.
- **`set_head_ref(ref_path)`** — writes `ref: <ref_path>\n` to `.sit/HEAD`. Used by checkout; probably also by future `sit checkout -b`.
- Verified against 13 scenarios: empty-branch-list (no commits), list-with-just-main, create-dev, checkout dev (materialize), checkout main (cleanup dev-only files), roundtrip, dirty blocking, clean allows, bad-branch error, dup-branch error, untracked collision, nested-dir create/delete across branches, log-follows-active-branch.

### v0.2.3 — Polish batch: tags, `checkout -b`, `add -f`

- **`sit tag`** — lightweight refs at `.sit/refs/tags/<name>`. `sit tag` lists alphabetically; `sit tag <name>` creates at HEAD; `sit tag <name> <hash-prefix>` creates at a resolved commit via `resolve_hash`. Ensures `.sit/refs/tags/` exists lazily. Duplicate-tag errors cleanly.
- **`sit checkout -b <branch>`** — create-and-switch convenience. If the target branch doesn't exist, creates it at HEAD before running normal checkout. Errors if the branch already exists (matches git's behavior). Lets us collapse the `sit branch X && sit checkout X` two-step.
- **`sit add -f <path>`** — force-add an ignored path. Skips the `is_ignored` check when `-f` is present. Non-ignored paths work the same with or without `-f`.
- Verified against nine scenarios across all three features: empty tag list, tag-at-HEAD, tag-at-hash-prefix, duplicate-tag error, tag-hash-correctness, `checkout -b` creates+switches, `checkout -b` dup error, `add -f` overrides ignore, `add -f` on non-ignored path.

### v0.2.4 — Ref resolution

- **`resolve_ref_name(name, out_buf)`** — new helper. Resolves `HEAD`, `refs/tags/<name>`, and `refs/heads/<name>` in that order (git's precedence minus remotes). On success, writes the 64-char hash into the caller's buffer.
- **`resolve_hash` chains through `resolve_ref_name`** before falling back to hash-prefix scanning. Net effect: anywhere sit used to accept a hash prefix (`cat-file`, `show`, `tag <name> <commit>`, future `log <rev>`), you can now pass `HEAD`, a tag name, or a branch name interchangeably.
- Fixes UX gap flagged in v0.2.3: `sit show v0.1` no longer errors with "too short prefix" and instead resolves to the tagged commit.
- Verified against eight scenarios: `show HEAD`, `show <tag>`, `show <branch>`, `show` on cross-branch tag, `show` on non-current branch, `cat-file <tag>`, short-name-as-tag beats too-short-prefix rule, empty-repo `show HEAD` returns cleanly.

### v0.2.5 — Staging index migrates to patra

- Patra 1.6.0 ships with `COL_BYTES` and its prerequisites (`patra_insert_row`, `patra_result_read_bytes`). sit's first real patra consumer is the staging index.
- **`.sit/index.patra`** — single-table schema `entries(path STR, hash_hex STR)`. Replaces the plaintext `.sit/index` appended by `file_append_locked` in prior versions.
- **`index_db_open()`** — opens the patra db and ensures the `entries` table exists (CREATE is idempotent; patra returns a cheap error on second call, which we ignore).
- **`index_migrate_from_plaintext(db)`** — on first read of any repo that still has the old plaintext `.sit/index`, parse it line-by-line and `patra_insert_row` each entry, then `sys_unlink` the old file. Transparent to the user — first `sit status` after upgrade does the migration.
- **`parse_index()`** now walks `SELECT path, hash_hex FROM entries`; reallocates rows into the same 40-byte `(hash_bytes, path_ptr)` layout the rest of sit already uses, so no call-site changes outside the parser.
- **`rewrite_index(entries)`** now `DELETE FROM entries; patra_insert_row(...)` per row. Same external contract — truncate + re-serialize — different backing store.
- **`index_upsert(hash_hex, path)`** new helper, replaces `cmd_add`'s inline `file_append_locked`. Loads current entries, filters out any row matching the path, appends the new entry, rewrites. Same last-write-wins semantics as the old append-then-dedupe-at-commit dance, but the index now holds at most one row per path at rest.
- Required toolchain bump: `cyrius = "5.6.22"` (5.6.21 had a sankoch mutex regression that hung `zlib_compress`; 5.6.22 fixes it).
- Verified against five scenarios: fresh add + commit flow, add + rm workflow, cross-branch checkout round-trip, legacy plaintext auto-migration, clean-tree status.

### v0.2.2 — `sit config` + `sit fsck`

- **`sit config [--global] <key> [<value>]`** — flat `key = value` format, git-compatible priority chain for author identity (`SIT_AUTHOR_NAME` env → `.sit/config` → `~/.sitconfig` → `"sit user"` fallback). Get mode returns the value and exits 0; set mode upserts (replaces the first matching line or appends, preserving comments and blanks).
- **`config_parse_value`, `config_file_get`, `config_get`, `config_file_set`** helpers — the file walker tolerates arbitrary whitespace around `=`, skips `#`-comments and blanks, preserves surrounding lines on write. `skip_ws(data, pos, stop)` utility for whitespace runs.
- **`build_commit` author fallback chain updated** — env first (matches git), then config, then the hardcoded fallback.
- Verified against nine scenarios: missing-key exit 1, set-then-get, set-existing-replaces, commit uses config when env unset, env overrides config, `--global` set/get, local-beats-global, comments+blanks preserved through set, usage error.
- **`sit fsck`** — walks every `.sit/objects/<xx>/<yy...>`, decompresses, re-hashes via `hash_data` over the framed bytes, compares to the filename. Reports `bad object <hex>` for hash mismatches and `unreadable <hex>` for decompression / read failures. Exit 1 if any bad object found. Emits `checked <n> objects, <m> bad` summary on stdout.
- Verified against four scenarios: empty repo (0 objects), populated repo (8 objects clean after two commits), corrupted object (GARBAGE overwrite detected as unreadable), missing object file (detected).

## Post-0.1 Backlog

### Longer horizon

- **Objects into patra** — `COL_BYTES` is live (patra 1.6.0). The last piece of arch 002's migration: move `.sit/objects/<xx>/<yy...>` loose files into a `objects(hash STR PRIMARY, type INT, content BYTES)` patra table. See [arch 002](../architecture/002-loose-objects-until-patra-bytes.md).
- **Pack format** — delta-compressed multi-object storage; depends on `COL_BYTES` and sankoch delta primitives.
- **Wire protocol** — first-party smart-HTTP / ssh replacement. Not on the AGNOS critical path; revisit once the local VCS loop is solid.
- **Merge** — 3-way merge with conflict markers. Needs a merge-base finder (walk commit ancestors to find LCA) and per-file three-way text merge.
- **Signed commits** — sigil-backed signatures on commit objects.
- **Integration tests in-tree** — promote the shell-level smoke tests from `docs/guides/getting-started.md` into `tests/` with fixtures. Current `tests/sit.tcyr` is stdlib-assert smoke only.
- **`sit fsck` reachability** — walk commit chain, flag dangling objects (current v0.2.2 only checks integrity, not reachability).
- **Hunk-grouping polish** — handle the `@@ -N +N,M @@` one-line-count abbreviation.
- **Full `.sitignore` semantics** — negation (`!pattern`), double-star (`**`), character classes (`[abc]`), anchored patterns (`/foo`), path patterns (`foo/bar`).
