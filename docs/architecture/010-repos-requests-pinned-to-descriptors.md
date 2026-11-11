# 010 — a `--repos` request is pinned to descriptors, and `.sit` is a `/proc` link

**Applies to**: `sit serve <dir> --repos` (`_serve_repo_for` and everything a request reaches), `sit_abs` and the `sf_*` guards in `src/util.cyr`. 1.13.4, audit S3.

## The constraint

Under `--repos`, a request for `/<name>/sit/v1/…` is served from `<dir>/<name>`, and someone who can write under `<dir>` can swap `<name>`, or the `.sit` inside it, for a symlink at any moment. Through 1.13.3 each request checked the path, then opened the store, the lock and the refs by path. A swap between the check and an open reached a repository outside `<dir>`: a racer saw another repository's tip in 119 of 300 refs answers and pushed 35 branches into it.

So **a request opens nothing by `<dir>/<name>` path**. It walks the name once, from `<dir>`'s descriptor, and every later open goes through what that walk found.

## How it holds

- At start, `cmd_serve` opens `<dir>` (`_serve_repos_dirfd`) and checks that `/proc/self/fd/<that fd>` reaches the same directory, by device and inode. If it does, `_serve_repos_pin` is 1.
- Each request, `_serve_repo_walk` opens each segment of `<name>` with `openat(…, O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)` from the previous one, then `.sit` the same way. It also checks `.sit/HEAD` is a regular file with `fstatat(AT_SYMLINK_NOFOLLOW)`. A link anywhere on the way fails the open, so the request is a 404.
- The request's repository root is `/proc/self/fd/<repo fd>`, and `sit_set_repo_dotdir` makes the path `.sit` stand for `/proc/self/fd/<.sit fd>`. `sit_abs` (`_sit_abs_len` / `_sit_abs_fill`) maps every `.sit` and `.sit/…` path there. So the store, the lock, the packs and the refs all resolve inside the directories the walk opened, whatever has been renamed or linked into their place since.
- A kept repository (up to `SERVE_REPOS_OPEN`) keeps its two descriptors and their device and inode in its cell (`SERVE_REPO_CELL`). Each request walks afresh and compares. On a match the fresh descriptors are closed and the kept ones serve, since the kept store handle and lock were opened through them. On a difference, or a failed walk, the kept repository is closed, descriptors included (`_serve_repo_drop`).
- `serve_handle_request` clears the pin after the request (and on a 503), so nothing outside a request resolves `.sit` through a descriptor that eviction may since have closed.

## What code must not do

- **Never `lstat` `.sit` itself during a request.** With the pin set, `sit_abs(".sit")` is `/proc/self/fd/<n>`, a magic link: `lstat` reads it as a symlink. `_sf_parent_symlink` skips that one component for this reason (`_sit_in_dotdir`). A new guard that asks whether `.sit` is a link, or is a directory by `lstat`, must skip it the same way. Components below it (`.sit/refs`, `.sit/packs`) are real and are checked as before.
- **Never build a served repository's path by hand** (`<root> + "/.sit/…"`). Only `sit_abs` and its relatives apply the pin. The functions that take an explicit `root` (`store_lock_shared(root)`, `_sit_packdir(root)`) are for another repository, a file:// remote, never the one being served.
- **Never close a kept cell's descriptors while its store state is in use.** The root and pin strings name them by number, and a reused number would name some other file.

## Where it does not apply

- **No `/proc`** (some containers and chroots), **AGNOS** (no `openat`), **macOS** (`/dev/fd` does not reach below a directory descriptor). `_serve_repos_pin` stays 0, `--repos` prints a warning at start, and each request checks its path as 1.12.2 did (`_serve_repo_by_path`). The window between that check and the opens is the one S3 found.
- **One-repository `sit serve <repo>`.** The repository is the one the operator named, and nothing under it belongs to anyone else.
- **Below `.sit`, within one call.** A guard's `lstat` and the open it guards are still two system calls (`sf_write_atomic` on `.sit/refs/heads/x`, the refs listing reading a ref file it found by `lstat`). That window is one call wide, not one request wide. Closing it would need every `sf_*` wrapper to walk with `openat` too.
