# 0017 — One server, many repositories: base-path routing under `--repos`

**Status**: Accepted
**Date**: 2026-10-20

## Context

`sit serve <repo>` serves one repository at `/sit/v1/…`. Hosting more meant one process and one port per repository. The client also refused any URL with a path (`http://host/repos/foo` was "base paths are not supported"), so a reverse proxy could not put several repositories behind one origin either.

Three things stood in the way, and all three had to move together:

- **Routing.** The server had to learn which repository a request is for.
- **Per-repository state.** The store handle, the store lock, the index handle and the pack lists are process globals, so the second repository opened in a process was read through the first one's store and index (the roadmap's R6). This hit owl and thoth switching repositories through the read API, and it would hit a multi-repository server on every request.
- **gc on a served repository.** The server held the store lock from its first request until it exited, so `sit gc` (architecture 008) refused for as long as it ran.

## Decision

**`sit serve <dir> --repos` serves every sit repository under `<dir>`. A request for `/<name>/sit/v1/…` goes to `<dir>/<name>`. Clients put the base path in the URL: `http://host:port/<name>`.**

- **Names.** A name is one or more path segments. Each segment is 1–255 bytes of `[A-Za-z0-9._-]` and does not start with `.`, so `..` and hidden directories are never names. A name has at most 16 segments and 1,024 bytes. It runs from the leading `/` to the first `/sit/v1/`. The check is lexical and happens before anything touches the filesystem.
- **Resolution.** Every directory from `<dir>` down to the repository must be a real directory, not a symlink (`lstat`), and the last must hold `.sit/HEAD`. Every other path gets a 404, the same answer whether something is there or not. That includes no name, an unknown name, a directory without `.sit`, a symlink, and any traversal spelling (`..`, `%2e%2e`, `//`); integration 41a sends them raw. `--repos` and `--stdio` are exclusive, because an `ssh://` URL names its repository by path already.
- **Per-repository store state.** Each repository's handle, lock descriptor and store identity is a context (`store_ctx_*`, `object_db.cyr`), loaded for its request and saved after it. Up to 64 are kept open, and past that the least recently used is closed. Pack lists are keyed by the repository's root, and pack mappings by resolved path, so repositories never share one.
- **Store sessions.** Every request, in either mode, is a store session: `store_enter` takes the shared lock, and `store_leave` gives it back when the response is sent. On entry, the store file's device and inode are compared with the ones the open handle has. A difference means a gc replaced the file, so the handle, the pack lists and the mappings of vanished packs are dropped and the request reads what gc left. gc therefore runs on a served repository between its requests. The read API does the same per call. A command, being one process, still holds the lock until it exits (architecture 008).
- **The client.** `wire_http_open` keeps the URL's path, trailing `/` dropped, as the base of every request. It refuses an empty, `.` or `..` segment, and `remote_url_valid` already limits the bytes. `sit clone` names the target after the last path segment, as git does. A 404 on the refs list now says "the server has no sit repository at that URL (404)".
- **The single-repository endpoint is unchanged:** `sit serve <repo>` still serves `/sit/v1/…`, and old clients and servers interoperate as before. An old client cannot reach a `--repos` server, because its URL can carry no path. That is the reason the flag exists rather than a change of the default.

## Consequences

- **Positive.** One process and one port serve any number of repositories. A reverse proxy can put them under one origin, because the base path survives to the server. gc no longer needs the server stopped.
- **Positive.** The R6 fixes reach every in-process consumer. Two `.sit` repositories opened in turn no longer show the second one's clean files as new, and two `.git` repositories with different packs of the same name no longer read each other's bytes. Integration 41c asserts both through the shipped read bundle.
- **Negative.** Each request pays a lock and unlock and, once the store is open, a `stat`: about 5 µs of server CPU per `GET /refs`, and within noise on object reads (measured at host load ~25, so the bound is loose).
- **Negative.** Mappings of packs that still exist stay mapped for the process, including those of repositories evicted from the 64. They cost address space, not memory, and are reused if the repository comes back. Packs a gc removed are unmapped at the next session (`_git_file_forget_missing`).
- **Neutral.** The `Host:` header is still the literal `127.0.0.1`. A proxy that routes by name needs its default server, or a rewrite, for now.

## Alternatives considered

- **Virtual hosting by `Host:`.** One repository per hostname needs DNS or proxy work for every repository, and the client sends a fixed Host today. The path is what a proxy can pass through untouched.
- **A query parameter (`?repo=foo`).** Every handler already routes on the path, and sandhi strips the query before routing. A path also reads as an ordinary repository URL.
- **One port per repository.** That is what was possible before. It needs a process per repository, and each would hold its own lock for its lifetime.
- **Close and reopen the store on every request instead of comparing its identity.** Simpler, but it puts a `patra_open` (about 30 µs) and a pack listing on every request to catch an event, gc, that is rare. The identity check costs one `stat`.
- **A generation number written by gc instead of the inode.** A 1.10.x gc would not write it, yet could run against a 1.11 server between requests. The inode changes whatever replaced the file.

## Amendment — 1.12.2: checked on every request, and one repository's lock is its own

The 1.12.2 closeout (audit [`2026-10-20-1.12.2-audit.md`](../audit/2026-10-20-1.12.2-audit.md)) found three ways the decision above did not hold as written:
- **A name was checked once.** "Every directory … must be a real directory" held for a repository's first request only. After that its cached path, store handle and lock descriptor were used as they were, so a directory swapped for a symlink served, and took pushes into, a repository outside `<dir>` (S3).
- **Eviction kept the pack list.** The pack lists are keyed by root and outlive a context. A repository evicted from the 64 came back with no handle, so the store-identity check never ran, and after a gc its packed objects answered 404 (S1).
- **Lock waits were shared.** The server is one loop. While a gc held one repository's lock, the request waiting on it held up every other repository's (X6).

Now:
- **Every request re-checks its repository** (`_serve_repo_kept`: at most 17 `lstat`s, no allocation). The directory must also be the one kept, by device and inode. One that fails either is closed and resolved afresh, with a new handle and lock descriptor. That also covers a repository replaced by another real directory, such as one restored from a backup. A narrow race remains between the check and the opens within one request. Closing it means opening everything relative to a directory descriptor opened `O_NOFOLLOW` from `<dir>`, which is roadmapped. It needs write access to a directory under `<dir>`.
- **Every store session compares the store file's identity** with the one seen at the last session, handle or not. On a change it forgets that root's pack list and the mappings of packs that are gone.
- **Under `--repos`, a store whose lock is held answers 503 at once** (`_store_session_wait_ms = 0`). A one-repository server, and the read API, still wait for the gc.
- **Only regular files are served as packs, and refs only from real directories.** A ref that is a link is listed only when it stays in the refs tree: relative, no `..`, through real directories to a regular file. Packs, refs, and a `refs/heads` linked in from another repository were served as the repository's own (S4, K4).

**Eviction and mappings: kept.** The roadmap asked whether eviction should also unmap a repository's packs. It does not. The mappings of packs that still exist cost address space only: two per packed repository, 200 for 100 gc'd repositories, against a `max_map_count` near a million. They are reused if the repository comes back. Mappings of packs a gc removed are now forgotten at that repository's next session. Before, they were kept until some other repository's gc happened to forget them.

**One token, every repository.** `--token` authorizes a push to every repository the server serves. There is no per-repository credential, as forges have. Put repositories that need different push rights behind different servers, or behind a proxy that authorizes by path (X7).

**Measured** (`--repos`, a repository at a two-segment name, server CPU over 4,000 requests, minimum of 6 alternating runs, two runs at host load 13–15): the per-request check is inside the noise. `GET /refs` cost +12.5 µs and then +0.0 µs, and an object read −47.5 µs and then +7.5 µs, against 1.12.1. The clock's resolution here is 2.5 µs per request. A request for a repository whose lock a gc holds now takes 0.3 ms. Before, it waited for the whole gc, and so did every other repository: 3.7 s for an unrelated one under a 4 s lock.
