# 008 — `sit gc` runs alone: the store lock

**Applies to**: every path that opens an object store (`get_object_db`, `remote_objects_open`), and `cmd_gc`. 1.10.0; store sessions 1.11.0.

## The constraint

`sit gc` replaces `.sit/objects.patra` with a compacted copy (rename over the old file) and removes the packs it superseded. A process that opened the store before that rename keeps a descriptor to the *old* file. Every object it writes afterwards lands in an inode no name points at, and is lost when it exits, while the ref it then moves names an object that no longer exists. patra's own locks do not help: they are per file, and after the rename there are two files.

So **gc must run with no other process holding the store open**, and a process must not open the store while gc runs.

## How it holds

- `.sit/objects.flock` is a lock file and nothing else: zero bytes, only ever `flock`ed, opened read-only, created `O_CREAT|O_EXCL` (which refuses a planted symlink), `O_CLOEXEC` so an editor or `ssh` that sit spawns does not inherit it.
- **Every process takes it shared before opening a store.** `get_object_db` does this for the repository's own store, and `remote_objects_open` does it for a file:// remote's (`<repo>/.sit/objects.flock`). A process that finds it held exclusively says `waiting for `sit gc` to finish with the object store` and waits, then opens the store gc left. Since 1.12.2 the wait polls a non-blocking lock every 50 ms, and how long it waits depends on the store:
  - its own repository's, for a command, the read API or a one-repository server: as long as the gc runs;
  - a file:// remote's: 60 s, then the command refuses. Anyone who can read that repository can hold its lock, and the wait had no end (audit P5);
  - under `sit serve --repos`: not at all. That repository's request answers 503, because one repository's wait held up every other repository's requests (X6).
- **The lock file is opened without blocking and checked on the descriptor** (1.12.2). A FIFO raced in after the `lstat` was refused instead of hanging the open.
- **A command holds it until it exits. A long-lived process holds it per stretch of work (1.11.0).** `sit serve` brackets each request, and the read API each call, with `store_enter` / `store_leave` (a *store session*). Between them no lock is held and a gc may run. So `store_enter` compares the store file's device and inode with those of the file it saw at the last session, whether or not a handle is open (1.12.2; through 1.12.1 it compared only while a handle was open, so a `--repos` repository evicted and then gc'd was read from its old pack list). On a difference it drops the handle, that repository's pack list and the mappings of packs that are gone, and the next read opens what gc left. The remote stores a file:// fetch or push opens are held to exit, like a command's.
- **`sit gc` takes it exclusive, non-blocking, before it opens anything.** It refuses when that fails: a command still running, or a request or API call in progress. **`fsck --prune` does the same since 1.12.2.** Under the shared lock it ran beside a fetch or a served push and deleted objects that had arrived but that no ref named yet (audit X2). A push spans requests, so a prune can still run between a push's objects and its ref; a receive-side connectivity check is roadmapped.
- With the lock held, the pack set cannot change under a process, which is why `sit_packs` lists `.sit/packs/` once per store, and a store session lists it again only when the store file changed.

## What it costs, and the gaps

- One `open` and one `flock` per process.
- A store session pays a lock, an unlock and a `stat` per request or API call (about 5 µs of server CPU per `GET /refs`, ADR 0017). Through 1.10.x a long-lived process kept gc out for as long as it ran, `sit serve` above all.
- gc still refuses while a request or a command is in progress, which is what keeps that request's reads consistent.
- A repository whose `.sit/` cannot be written cannot have the lock file created. Its stores open unlocked. Nothing in that process can write them, and gc cannot run there either.
- agnos has only non-blocking `flock` (stdlib note). Through 1.12.1 a command started there during gc went on without the lock, while saying it had waited (audit P11). The polling wait (1.12.2) works there as on Linux.
- sit ≤ 1.9.0 takes no lock. An old binary running alongside gc is unprotected, and an old binary cannot read a packed repository anyway (ADR 0016).
- Deleting `.sit/objects.flock` while processes hold it breaks the protocol for that moment: the next process creates a new file, and gc would lock that one. Like the other files under `.sit/`, it is not the user's to remove.

## Where to look

- `store_lock_shared`, `store_lock_exclusive`, `_store_lock_open`, `_store_lock_wait_shared` and `_store_session_wait_ms` in `src/object_db.cyr`.
- `store_enter`, `store_leave`, `store_drop`, `_store_file_id` and the `store_ctx_*` contexts (one per repository under `sit serve --repos`) in `src/object_db.cyr`; `serve_handle_request` in `src/serve.cyr`; `_api_enter` / `_api_leave` in `src/api.cyr`.
- `remote_objects_open` in `src/wire.cyr`.
- `cmd_gc` in `src/gc.cyr` (the lock is its first act). Integration section 39f covers refusal under `flock -s`, waiting under `flock -x`, and gc while `sit serve` is idle (since 1.11.0); 41b and 41c cover a `--repos` server and the read API.
