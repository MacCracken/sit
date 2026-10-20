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
