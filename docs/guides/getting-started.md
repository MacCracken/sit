# Getting started

Build sit from source and initialize your first repository.

## Prerequisites

- Cyrius toolchain — version pinned in `cyrius.cyml` under `[package].cyrius` (currently **5.6.16**). Check `cyrius --version`.
- Linux x86_64. Other targets will work when the corresponding `syscalls_*` stdlib modules are exercised, but x86_64 Linux is the primary target today.

## Build

```sh
cyrius build src/main.cyr build/sit
```

First build fetches the git deps (sakshi, sankoch, sigil, patra) into `~/.cyrius/deps/<name>/<tag>/` and symlinks them into `lib/`. Subsequent builds are cached.

Run the test suite:

```sh
cyrius test
```

## Try it

```sh
mkdir /tmp/sit-demo && cd /tmp/sit-demo
/path/to/sit/build/sit init
```

Expected output:

```
initialized empty sit repository in .sit/
```

Inspect the layout:

```sh
find .sit
# .sit
# .sit/HEAD
# .sit/objects
# .sit/refs
# .sit/refs/heads

cat .sit/HEAD
# ref: refs/heads/main
```

Layout and HEAD contents are byte-compatible with a freshly-initialized git repository, by design.

Re-running `sit init` is idempotent: it prints `reinitialized existing sit repository in .sit/` and exits 0.

## Add a file

```sh
echo "hello, sit!" > greeting.txt
/path/to/sit/build/sit add greeting.txt
# added 37f70a18b0d2 greeting.txt
```

What that did:

1. Wrapped the file content with git's `"blob <len>\0<content>"` framing.
2. Hashed the framed bytes with sigil (SHA-256) → 64-char hex object ID.
3. Compressed the framed bytes with sankoch (`zlib_compress`, level 6).
4. Wrote the compressed blob to `.sit/objects/37/f70a18b0d2...`.
5. Appended `<hash>\t<path>\n` to the staging index at `.sit/index`.

Verify with any zlib-capable tool:

```sh
python3 -c "
import zlib
print(zlib.decompress(open('.sit/objects/37/f70a18b0d27d5dd912f6080063bf6fe10820814bccc4bcd13c67ce97c2a96c','rb').read()))
# b'blob 12\\x00hello, sit!\\n'
"
```

Sit's object hashes are byte-identical to git's SHA-256 object hashes for the same content — see [ADR 0001](../adr/0001-no-ffi-first-party-only.md) for why we reimplement the stack rather than bind to libgit2.

## View an object — plumbing (`cat-file`)

```sh
# Full 64-char hash
/path/to/sit/build/sit cat-file 37f70a18b0d27d5dd912f6080063bf6fe10820814bccc4bcd13c67ce97c2a96c

# Or any prefix ≥ 4 chars
/path/to/sit/build/sit cat-file 37f7
```

Output is the raw blob content — the framing (`"blob <len>\0"`) is stripped. Errors on ambiguous prefixes, prefixes shorter than 4 characters, or missing objects.

## View an object — decorated (`owl-file`)

```sh
/path/to/sit/build/sit owl-file 37f7
```

Runs the content through [owl](https://github.com/MacCracken/owl) — bat-like file viewer with syntax highlighting, line numbers, and git-aware gutter markers. Looks for owl at `/usr/local/bin/owl`, `/usr/bin/owl`, `/opt/owl/bin/owl`.

If owl isn't installed (it's currently pre-1.0), `owl-file` prints a notice and falls back to emitting raw content — so the command is usable today, and transparently upgrades to decorated output once owl ships.

## Commit

```sh
export SIT_AUTHOR_NAME="Your Name"
export SIT_AUTHOR_EMAIL="you@example.com"
/path/to/sit/build/sit commit -m "initial commit"
# [main (root-commit) 9836957df923] initial commit
```

The first commit on a branch prints `(root-commit)` in the header. Subsequent commits link to their parent via the commit object's `parent <hex>\n` line. If `SIT_AUTHOR_NAME` / `SIT_AUTHOR_EMAIL` are unset, sit uses the placeholder `"sit user" <user@localhost>`.

Both `sit commit "msg"` (positional) and `sit commit -m "msg"` work.

Inspect the commit and its tree:

```sh
sit cat-file 9836957df923
# tree 8cf1dc97124fcbe8ec037c213cbb5440b03b7f4377a7aecc7bb3bae59f3d16da
# author Your Name <you@example.com> 1776999445 +0000
# committer Your Name <you@example.com> 1776999445 +0000
#
# initial commit

sit cat-file 8cf1dc9 | xxd
# 100644 greeting.txt\0<32 raw hash bytes>100644 notes.md\0<32 raw hash bytes>...
```

Subdirectories work end-to-end — `sit add src/main.cyr && sit add docs/intro.md && sit commit -m "..."` produces a proper recursive tree structure (root tree → `src/` subtree → `main.cyr` blob, etc). Trees use mode `40000` for directories and `100644` for files, matching git's SHA-256 tree format byte-for-byte.

## View history

```sh
/path/to/sit/build/sit log
# commit 39cec8d7f0a5e65721fc903a67acb1e2b5cd1ffb2a81a08dbdb838fd32f179ce
# Author: Your Name <you@example.com>
# Date:   2026-04-24T03:07:29Z
#
#     third
#
# commit c0772e81223544e732d1176e1494bdfc11fb202808a340eee78e6b54ae95f691
# Author: Your Name <you@example.com>
# Date:   2026-04-24T03:07:29Z
#
#     second commit
#
#     with a longer body
#     on multiple lines
#
# commit 0d5aa988afbd4aa15140bc249b0b8afd96352292628a9aa3bbbe4db85bc333e3
# ...
```

Walks the commit chain starting from `HEAD` (currently hardcoded to `refs/heads/main`), following each commit's `parent <hex>` line. Terminates at the root commit (no parent line). Multi-line messages are indented 4 spaces per git convention.

Empty repo prints `sit: no commits yet` to stderr and exits 0 — not an error.

## Check status

```sh
/path/to/sit/build/sit status
# On branch main
#
# Staged for commit:
#   modified:  readme.txt
#   new file:  third.txt
#
# Unstaged changes:
#   modified:  third.txt
#
# Untracked files:
#   new.txt
```

Compares three views:

1. **HEAD tree** — what was last committed (the tree object pointed to by `refs/heads/main`).
2. **Staging index** — what `sit add` has recorded as "about to commit".
3. **Working directory** — what's actually on disk right now.

Categories:

- **Staged for commit** — files in the index whose hash differs from HEAD's tree (or aren't in HEAD at all).
- **Unstaged changes** — index entry where the file on disk has changed since `sit add`, or the file has been deleted.
- **Untracked files** — files on disk that are neither staged nor committed.

Empty repo with no files prints `nothing to commit, working tree clean`.

## See what changed

```sh
# Unstaged changes — working tree vs index
/path/to/sit/build/sit diff
# --- a/fruits.txt
# +++ b/fruits.txt
# @@ -1,5 +1,6 @@
#  alpha
# -beta
# +bravo
#  gamma
# +delta
#  epsilon

# Staged changes — index vs HEAD tree
/path/to/sit/build/sit diff --staged
```

Output is unified diff: `@@ -oldstart,oldlen +newstart,newlen @@` hunk headers, then ` ` prefix for unchanged context, `-` for removed, `+` for added. Up to 3 lines of context before and after each change; adjacent changes within 6 context lines get merged into a single hunk (standard git behavior).

The diff walks each entry in the staging index:

- **Default mode**: hashes the working file, compares to the staged hash. If they differ (or the working file is missing), reads both blobs and emits a line diff.
- **`--staged` mode**: looks up the path in HEAD's tree. If missing, shows all lines as inserts (new file). If the tree hash differs, reads both blobs and diffs.

Algorithm is classical LCS (longest common subsequence) — DP table capped at 16M cells (≈128 MB). Files beyond that threshold print a "too large" notice and are skipped.

## Show a single commit

```sh
/path/to/sit/build/sit show           # defaults to HEAD
/path/to/sit/build/sit show 2b33d699  # 4-char-minimum hash prefix
```

Output is the log-style header followed by the diff of that commit against its parent (root commits get new-file diffs for everything). Each file's diff goes through the same hunk-grouped renderer as `sit diff`, so you get `@@` headers and 3-line context automatically.

## Ignore files with `.sitignore`

Drop a `.sitignore` at the repo root to keep build artifacts, editor junk, and secrets out of status and commits:

```
# .sitignore — blank lines and comments are skipped
.env
build
*.log
*.tmp
file?.bak
```

- Patterns are segment-matched: `build` ignores `build/`, `src/build/`, and `lib/build/foo.cyr`.
- `*` matches any run of non-`/` chars; `?` matches exactly one. No `**` yet.
- Trailing `/` on a pattern is allowed but not enforced (v1 doesn't restrict matches to directories).
- `sit add <ignored>` errors out — like git, no `-f` override in v1.
- `.sitignore` itself is trackable; `sit add .sitignore` works normally.

**Note**: unlike older sit versions, dotfiles aren't hidden by default anymore — only `.sit/` is hardcoded-skipped. To keep `.git/` out of your sit repo when both coexist, list `.git` in your `.sitignore`.

## What works today

- `sit init` — create empty repository
- `sit add <path>` — hash, compress, and store a file as a blob object; append to staging index
- `sit rm [--cached] <path>` — remove a tracked file from working tree + index (or just the index with `--cached`)
- `sit branch [<name>]` — list branches, or create one at HEAD
- `sit checkout <branch>` — switch branches: materializes the target tree into the working directory, rewrites the index, updates HEAD
- `sit config [--global] <key> [<value>]` — read/write config entries (`user.name`, `user.email`, etc). Local at `.sit/config`, global at `~/.sitconfig`
- `sit fsck` — verify that each stored object's content hashes back to its filename
- `.sitignore` — gitignore-style pattern file (at repo root) filters untracked-file display and `sit add`
- `sit commit [-m] <message>` — write tree + commit objects, update `refs/heads/main`
- `sit log` — walk commit history from HEAD with git-style output
- `sit status` — three-way diff across HEAD tree, staging index, and working directory
- `sit diff [--staged|HEAD]` — unified diff with `@@` hunk headers (working vs index / index vs HEAD / working vs HEAD)
- `sit show [<hash>]` — show a single commit's header + parent-diff (defaults to HEAD)
- `sit cat-file <hash>` — emit object content to stdout; supports 4-char hash prefixes
- `sit owl-file <hash>` — view object through owl (falls back to raw output when owl isn't installed)

## What doesn't yet

- Remote / push / pull / fetch / wire protocol
- Merge, rebase, tags
- `sit checkout -b <name>` convenience (use `sit branch <name>` then `sit checkout <name>`)
- Full gitignore semantics (no negation / `**` / char-classes yet)

Track progress in [`../development/roadmap.md`](../development/roadmap.md). Design notes live in [`../architecture/`](../architecture/); decisions in [`../adr/`](../adr/).
