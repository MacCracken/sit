# Getting started

Build sit from source and initialize your first repository.

## Prerequisites

- Cyrius toolchain — version pinned in `cyrius.cyml` under `[package].cyrius` (the pin is the single source of truth; check it there, and `cyrius --version` to confirm your install matches).
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

**Git-aware (1.2.0):** run this inside an existing **git** repository (a `.git/` but no `.sit/`) and `cat-file` reads the object from the git store instead — loose objects *and* packfiles, SHA-1 or SHA-256 — read-only, via the same repo-open path. See [ADR 0011](../adr/0011-git-read-mode.md) and the ["read an existing git repository"](#what-works-today) entry below.

## View an object — decorated (`owl-file`)

```sh
/path/to/sit/build/sit owl-file 37f7
```

Runs the content through [owl](https://github.com/MacCracken/owl) — bat-like file viewer with syntax highlighting, line numbers, and git-aware gutter markers. Looks for owl at `/usr/local/bin/owl`, `/usr/bin/owl`, `/opt/owl/bin/owl`.

If owl isn't installed (it's currently pre-1.0), `owl-file` prints a notice and falls back to emitting raw content — so the command is usable today, and transparently upgrades to decorated output once owl ships. Like `cat-file`, `owl-file` is git-aware (1.2.0): inside an existing git repo it reads the object from the `.git/` store (loose + packfiles, SHA-1 / SHA-256).

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

## Sign commits

Sit uses sigil's ed25519 directly — no GPG, no OpenPGP armor, no agent. Generate a keypair once per machine:

```sh
/path/to/sit/build/sit key generate
# generated ed25519 key ce8fc220b848
#   private: /home/you/.sit/signing_key (0600)
#   public:  /home/you/.sit/signing_key.pub
```

The seed lives at `~/.sit/signing_key` (hex-encoded, chmod 0600). Treat it the same as an SSH private key.

Sign a commit with `-S`:

```sh
/path/to/sit/build/sit commit -S -m "signed initial"
# [main (root-commit) 15a772e936d9] signed initial
```

Verify it:

```sh
sit verify-commit 15a772e936d9
# good signature on 15a772e936d9 (key ce8fc220b848698b45379f4825dcaca1eb1ef7105948e22408c57b521848b102)
```

And `sit show` / `sit log` pick up the signature automatically:

```sh
sit show
# commit 15a772e936d9179bc0f69f0fb2496abb79132e1da18e5f2369c2f6eb58ce941a
# Signature: good (key ce8fc220b848)
# Author: Your Name <you@example.com>
# ...
```

The signature is a `sitsig <128-hex-sig> <64-hex-pubkey>` line spliced into the commit header between `committer` and the blank separator. `cat-file` shows it verbatim; the signed payload is the commit body *without* the sitsig line, matching git's self-consistent `gpgsig` convention.

## Browse history

`sit log` walks the first-parent chain (`--oneline` for one line per commit, `-n <count>` to cap). To see merge topology, `--graph` renders an ASCII DAG over the **full** parent graph:

```sh
sit log --graph
# * 5379191fde87 Merge branch 'feature'
# |\
# * | ad72885ba558 main work
# | * a0efb20c9948 feature work
# |/
# * 2e6de91b936a base2
# * 40853f1196f3 base1
```

Each commit is a `*` on its lane; a merge opens a `\` branch, a rejoin closes with `/`. Linear history is just a column of `*`. (Spacing is sit-native, not byte-identical to git.)

## Sync with a remote

A "remote" can be a sit working-tree directory on the same filesystem **or** a network endpoint. sit supports four transports — the object-transfer mechanics (reachability walk → copy raw compressed bytes → fsck verifies) are identical across all of them:

| URL form | Transport | Read (clone/fetch) | Write (push) |
|---|---|---|---|
| `/srv/repo` or `file:///srv/repo` | local path | ✅ | ✅ |
| `http://host:port` | plain HTTP (loopback / private net) | ✅ | ✅ |
| `https://host:port` | TLS 1.3, first-party (TOFU-pinned) | ✅ | ✅ |
| `ssh://user@host/path` | system `ssh` process | ✅ | ✅ |

```sh
# Register a remote. The URL is a path, http(s)://, or ssh://.
/path/to/sit/build/sit remote add origin /srv/sit-repos/demo
/path/to/sit/build/sit remote list
# origin	/srv/sit-repos/demo
```

Fetch objects and the tracking ref:

```sh
sit fetch origin            # defaults to main
sit fetch origin feature-x  # or a specific branch
# fetched origin/main at 05359719b7c3 (7 new objects)
```

The fetched objects land in your local `.sit/objects.patra`; the remote's tip is written to `.sit/refs/remotes/origin/<branch>`. Fetch does not merge — run `sit merge origin/main` or `sit pull` to integrate.

Push the current branch back upstream:

```sh
sit push origin             # defaults to current branch
sit push origin main
# pushed main -> origin at 859d7b43afef (3 new objects)
```

Push is fast-forward-only: if the remote has commits your local branch doesn't contain, the push aborts with `non-fast-forward push rejected (remote has diverged)`. Fetch, merge, and re-push is the resolution path.

### Pull and clone

`sit pull` is fetch + fast-forward merge:

```sh
sit pull origin             # defaults to main
# fetched origin/main at 0755fb124e1a (3 new objects)
# fast-forward to 0755fb124e1a
```

If your local branch has diverged from origin, `sit pull` bails out with `local and remote have diverged; run 'sit merge origin/main' to resolve`. This matches `git pull --ff-only` and avoids surprising auto-merges.

`sit clone` bootstraps a new repo from a remote path:

```sh
cd /tmp
sit clone /srv/sit-repos/demo my-demo
cd my-demo
sit log
```

Under the hood it's `mkdir` + `chdir` + `sit init` + `sit remote add origin <url>` + `sit fetch origin main` + `write HEAD ref` + materialize the tree. The target directory defaults to the URL's last path segment when you don't pass one.

**Shallow clone** — `--depth <n>` pulls only the most recent *n* commits (each with its complete tree + blobs), not the full history:

```sh
sit clone --depth 1 /srv/sit-repos/demo my-demo   # just the tip commit
```

The kept commits' un-fetched parents are recorded in `.sit/shallow` (git's `.git/shallow` parity), so `sit log` stops cleanly at the boundary and `sit fsck` stays clean. Depth is exact for linear history; across merges the boundary is approximate.

## Serve and sync over the network

`sit serve` exposes a repo over the `/sit/v1/...` wire protocol. It's loopback-bound by default (`127.0.0.1`); put it behind a tunnel, or use `--tls` / `ssh://` for encrypted-over-internet.

```sh
# Plain HTTP (loopback / private network / behind a tunnel)
sit serve /srv/repos/demo --listen 127.0.0.1:8484 &
sit clone http://127.0.0.1:8484 my-demo

# HTTPS — first-party TLS 1.3 (no libssl). Bring an Ed25519 (or ECDSA P-256) cert+key:
openssl req -x509 -newkey ed25519 \
  -keyout key.pem -out cert.pem -days 365 -nodes -subj "/CN=127.0.0.1"
sit serve /srv/repos/demo --tls --cert cert.pem --key key.pem --listen 127.0.0.1:8443 &
sit clone https://127.0.0.1:8443 my-demo
```

HTTPS trust is **TOFU / pinned** (like SSH host keys): the first clone records the server's certificate fingerprint in `~/.sit/known_certs`; a later mismatch refuses the connection. The TLS connection is reused across the whole clone (one handshake). **Ed25519, ECDSA P-256, and ECDSA P-384** server certs all work (Ed25519 support landed via the sigil 3.9 / cyrius 6.x X.509-parser fix); RSA server certs are not supported.

```sh
# SSH — reuses the system ssh binary; sit runs 'sit serve --stdio' on the far side
sit clone ssh://user@host/srv/repos/demo my-demo
```

Bearer-token auth (`--require-auth`, `~/.sit/serve.token`) gates writes over HTTP/HTTPS; reads stay anonymous. Pushing to a remote's currently-checked-out branch is refused (`denyCurrentBranch`), matching git.

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
# .sitignore — blank lines and # comments are skipped
.env
build
*.log
!keep.log          # negation: re-include a file an earlier pattern excluded
/root-only         # leading '/' anchors to the repo root
**/cache/*         # '**' spans directories
[Tt]emp            # char classes (ranges + [!…] negation too)
```

As of v0.8.10 the matcher is git-parity:

- **`*`** matches a run of non-`/`; **`?`** matches one non-`/`; **`[abc]` / `[a-z]` / `[!abc]`** char classes match one char.
- **`**`** spans directories — `**/foo` matches `foo` at any depth, `foo/**` matches everything under `foo`, `a/**/b` matches across nesting.
- **Anchoring**: a pattern with a leading or middle `/` (`/foo`, `a/b`) is matched from the repo root; a pattern with no `/` (`build`, `*.log`) matches at any level.
- **Negation**: `!pattern` re-includes a previously-excluded match — patterns are evaluated in order, last match wins.
- **Directory exclusion**: a matched directory excludes its contents (`build` also ignores `build/foo.o`).
- `sit add <ignored>` errors out — like git, override with `-f`. `.sitignore` itself is trackable.

Simplifications vs git (documented in `src/index.cyr`): a non-segment `**` (e.g. `a**b`) still crosses `/`; a trailing `/` (`build/`) is allowed but not enforced as directories-only.

**Note**: unlike older sit versions, dotfiles aren't hidden by default anymore — only `.sit/` is hardcoded-skipped. To keep `.git/` out of your sit repo when both coexist, list `.git` in your `.sitignore`. (Separately, since 1.2.0 sit can *read* an existing `.git/` repo read-only — see ["read an existing git repository"](#what-works-today) below — so a `.git/` directory isn't merely clutter.)

## What works today

- `sit init` — create empty repository
- `sit add <path>` — hash, compress, and store a file as a blob object; append to staging index
- `sit rm [--cached] <path>` — remove a tracked file from working tree + index (or just the index with `--cached`)
- `sit branch [<name>]` — list branches, or create one at HEAD
- `sit checkout [-b] <branch>` — switch branches; `-b` creates the branch first at HEAD
- `sit tag [<name> [<commit>]]` — list tags, or create a lightweight tag at HEAD (or at a given commit)
- `sit merge <branch>` — fast-forward when possible; otherwise 3-way merge with line-level diff3. Edits on different regions of the same file auto-merge; truly overlapping edits fall back to `<<<<<<<`/`=======`/`>>>>>>>` markers, save `.sit/MERGE_HEAD`, and wait for you to resolve + `sit add` + `sit commit` (which emits a 2-parent commit). `sit merge --abort` cancels the merge and restores HEAD.
- `sit reset <path>` — unstage: rewrite the index entry for the path to HEAD's tree hash (or drop it if HEAD doesn't have it). Working tree untouched.
- `sit reset --hard <ref>` — move the current branch's ref to `<ref>` (branch / tag / commit hex) and restore the working tree to that commit.
- `sit config [--global] <key> [<value>]` — read/write config entries (`user.name`, `user.email`, etc). Local at `.sit/config`, global at `~/.sitconfig`
- `sit fsck [--prune] [--prune-now]` — integrity (each stored object re-hashes to its key) **and reachability** (objects no ref / index entry points at are reported as `dangling <type> <hex>`); reflog entries count as reachability roots, so a `reset --hard`-discarded tip is protected. `--prune` removes dangling objects subject to a 90-day grace window (datable commits older than the window; undatable trees/blobs are kept), `--prune-now` is the legacy immediate sweep (`git gc --prune=now`). Both refused mid-merge or when the store looks corrupt
- `sit reflog [-n <count>] [<ref>]` — show a ref's movement history newest-first (`<short-oid> <ref>@{N}: <message>`), defaulting to HEAD; every commit / reset / merge / checkout / branch-create / fetch records an entry under `.sit/logs/`. Resolve `<ref>@{N}` anywhere a revision is accepted — e.g. `sit reset --hard HEAD@{1}` undoes your last reset, `sit log HEAD@{2}` inspects where HEAD was two moves ago
- `sit merge-base <a> <b>` — print the lowest common ancestor of two commits over the full parent DAG (correct across merges; git's `git merge-base`)
- `.sitignore` — git-parity ignore matcher (`*` / `?` / `[...]` char classes / `**` / `!` negation / leading-or-middle-`/` anchoring) filtering untracked-file display and `sit add` (override with `-f`)
- `sit commit [-m] <message>` — write tree + commit objects, update `refs/heads/main`
- `sit log [--oneline] [--graph] [-n <count>] [<ref>]` — walk commit history from HEAD with git-style output; `--oneline` for one line per commit, `--graph` for an ASCII commit DAG over the full parent graph (`* | / \` lanes)
- `sit status` — three-way diff across HEAD tree, staging index, and working directory
- `sit diff [--staged|HEAD]` — unified diff with `@@` hunk headers (working vs index / index vs HEAD / working vs HEAD)
- `sit show [--stat] [<hash>]` — show a single commit's header + parent-diff (defaults to HEAD); `--stat` emits per-file insertion/deletion counts instead of the full diff
- `sit key generate` / `sit key show` — create / inspect the local ed25519 signing key at `~/.sit/signing_key`
- `sit commit -S` — sign the commit body (inserts a `sitsig <sig> <pubkey>` header line)
- `sit verify-commit [<hash>]` — check a commit's signature; defaults to HEAD
- `sit remote add|list|remove <name> [<url>]` — manage named remotes (`file://` / `http://` / `https://` / `ssh://`)
- `sit fetch <remote> [<branch>]` — copy remote objects + tracking ref into the local repo (any transport)
- `sit pull <remote> [<branch>]` — fetch + fast-forward merge (divergence → use `sit merge` manually)
- `sit push <remote> [<branch>]` — push HEAD's branch to a remote, fast-forward only (any transport; refuses the remote's checked-out branch per `denyCurrentBranch`)
- `sit clone [--force-absolute] [--depth <n>] <url> [<dir>]` — init + remote add + fetch + materialize in one shot, over any transport. `--depth <n>` is a shallow clone (only the most recent *n* commits, each with its full tree + blobs; boundary recorded in `.sit/shallow` so `log` stops cleanly). Absolute target paths require `--force-absolute` (so `sit clone <url> /etc/passwd` doesn't silently land where you didn't mean — S-23 hardening from v0.6.2).
- `sit serve <repo> [--listen 127.0.0.1:<port>] [--tls --cert <f> --key <f>] [--stdio] [--require-auth]` — host a repo over the `/sit/v1/...` wire protocol (loopback HTTP, HTTPS via first-party TLS 1.3, or SSH stdio)
- `sit merge -S <branch>` — signed merge commit (same ed25519 flow as `sit commit -S`)
- `sit cat-file <hash>` — emit object content to stdout; supports 4-char hash prefixes
- `sit owl-file <hash>` — view object through owl (falls back to raw output when owl isn't installed)
- **Read an existing git repository (read-only, 1.2.0)** — point sit at a directory with a `.git/` (no `.sit/`) and it transparently opens the git store: `sit cat-file` / `sit owl-file` read git objects — loose *and* packed (packfiles decoded via `.idx` v2 binary search + a first-party OFS/REF delta interpreter), SHA-1 or SHA-256, refs resolved from `HEAD` / `refs/` / `packed-refs`. The `dist/sit.cyr` **library API** (`sit_diff_path`, `sit_repo_branch`, `sit_repo_status`) additionally reports branch / status / diff for consumers like owl + thoth. Read-only — no `.git/` write-back; sit stays `.sit/`-native for its own repos. Modules `src/git_read.cyr` + `src/git_pack.cyr`; see [ADR 0011](../adr/0011-git-read-mode.md).

## What doesn't yet

- Rebase; cherry-pick; stash (the reflog + its `fsck --prune` grace period landed in 1.1.0, making these safe to add next)
- Reflog entry expiry (`reflog expire` / `delete`) — entries are currently unbounded, so reflog-protected objects stay until the log is cleared manually; the `@{<date>}` time-selector (only the integer `@{N}` ordinal ships in 1.1.0)
- Octopus (3+ parent) merges — `merge-base` resolves them correctly, but `sit merge` is 2-way, so 3-parent commits can't be created yet
- Pack bundles / delta compression for object transfer (objects copy one-at-a-time)
- HTTPS over public CA certs / mTLS — HTTPS today is TOFU-pinned (CA-chain + hostname verification is a post-v1 opt-in; the 1.5.0 transport-trust minor)
- `.sitignore` directory-only (`build/`) enforcement

Track progress in [`../development/roadmap.md`](../development/roadmap.md). Design notes live in [`../architecture/`](../architecture/); decisions in [`../adr/`](../adr/).
