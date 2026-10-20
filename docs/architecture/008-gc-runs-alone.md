# 008 — `sit gc` runs alone: the store lock

**Applies to**: every path that opens an object store (`get_object_db`, `remote_objects_open`), and `cmd_gc`. 1.10.0.

## The constraint

`sit gc` replaces `.sit/objects.patra` with a compacted copy (rename over the old file) and removes the packs it superseded. A process that opened the store before that rename keeps a descriptor to the *old* file. Every object it writes afterwards lands in an inode no name points at, and is lost when it exits, while the ref it then moves names an object that no longer exists. patra's own locks do not help: they are per file, and after the rename there are two files.

So **gc must run with no other process holding the store open**, and a process must not open the store while gc runs.

## How it holds

- `.sit/objects.flock` is a lock file and nothing else: zero bytes, only ever `flock`ed, opened read-only, created `O_CREAT|O_EXCL` (which refuses a planted symlink), `O_CLOEXEC` so an editor or `ssh` that sit spawns does not inherit it.
- **Every process takes it shared before opening a store, and holds it until it exits.** `get_object_db` does this for the repository's own store, and `remote_objects_open` does it for a file:// remote's (`<repo>/.sit/objects.flock`). A process that finds it held exclusively says `waiting for `sit gc` to finish with the object store` and blocks. Then it opens the store gc left.
- **`sit gc` takes it exclusive, non-blocking, before it opens anything.** It refuses when that fails: a command still running, `sit serve`, an in-process consumer.
- With the lock held, the pack set cannot change under a running process, which is why `sit_packs` lists `.sit/packs/` once per process.

## What it costs, and the gaps

- One `open` and one `flock` per process.
- A long-lived process keeps gc out for as long as it runs. `sit serve` is the one that matters, and gc refuses while a repository is being served. Letting the server release the lock between requests (and re-read the store after a gc) belongs with 1.11.0's serving work.
- A repository whose `.sit/` cannot be written cannot have the lock file created. Its stores open unlocked. Nothing in that process can write them, and gc cannot run there either.
- agnos has only non-blocking `flock` (stdlib note). There a command started during gc does not wait for it. This is accepted, as for sit's other locks there.
- sit ≤ 1.9.0 takes no lock. An old binary running alongside gc is unprotected, and an old binary cannot read a packed repository anyway (ADR 0016).
- Deleting `.sit/objects.flock` while processes hold it breaks the protocol for that moment: the next process creates a new file, and gc would lock that one. Like the other files under `.sit/`, it is not the user's to remove.

## Where to look

- `store_lock_shared`, `store_lock_exclusive`, `_store_lock_open` in `src/object_db.cyr`.
- `remote_objects_open` in `src/wire.cyr`.
- `cmd_gc` in `src/gc.cyr` (the lock is its first act). Integration section 39f covers refusal under `flock -s`, waiting under `flock -x`, and refusal while `sit serve` runs.
