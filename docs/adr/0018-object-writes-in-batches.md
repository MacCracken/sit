# 0018 — `sit add` writes its objects as one batch, synced before the index names them

**Status**: Accepted
**Date**: 2026-10-30

## Context

Every object sit writes is one autocommit `INSERT` into `.sit/objects.patra`, and patra's default `FULL` mode ends each with an `fdatasync`. A commit writes a handful of objects, so that never showed. A `sit add` of a whole tree writes one object per file: on this host's SSD (ext4) each file cost about 5 ms, almost all of it the sync, and 10,000 small files took 46.7–64.9 s (git: 0.4–0.6 s). 1.13.0 makes that the ordinary case, because `sit add .` and `sit add <dir>` arrive with it.

patra offers two ways to sync less often:

- **An explicit transaction.** Rolls back as a unit, but its write-ahead log syncs once for every distinct page it touches, new pages included (architecture [009](../architecture/009-patra-delete-scans-wal-syncs-per-page.md)). 10,000 index-sized rows took 6.8 s that way, against 2.2 s per 1,000 in autocommit.
- **`PATRA_SYNC_BATCH`.** Statements stay autocommit, but the header's `fdatasync` runs once per 64 statements and on `patra_flush`. v0.6.10 tried it on the store and reverted it, because the cached handle is never closed: writes after the last flush could be lost on power failure, and nothing marked where durability ended.

Two of sit's rules govern which one fits. An object nothing names is harmless: it is dangling until `fsck --prune` judges it. And CLAUDE.md requires every write's status to be checked before anything points at the row.

## Decision

**`sit add` writes its blobs in BATCH mode and ends the batch before it touches the index.**

- `object_db_batch_begin` puts the cached store into `PATRA_SYNC_BATCH`.
- `object_db_batch_end` puts it back to `FULL`. `patra_set_sync_mode` flushes first, so the batch's writes are synced, and a failed sync is returned.
- `cmd_add` treats a failed `object_db_batch_end` as a failed write. Nothing is staged and the command fails, so the index never names an object that is not known to be on disk.
- The index update stays one patra transaction, so a `sit add` lands whole or not at all (1.12.1's contract).

Scope: `cmd_add` only. Commits, merges, fetches and the server keep their existing paths: `copy_objects` already runs in one transaction, and the rest write too few objects for the sync to matter.

## Consequences

- **Positive.** 10,000 new files on ext4 take 7.8 s instead of 64.9 s (load 10–11 on 16 cores). With 1.13.0's other changes, re-adding them unchanged takes 0.93 s instead of 69.8 s (2026-10-30 benchmark snapshot). A one-file add is unchanged (112.2 → 112.9 ms of CPU over 100 runs).
- **Positive.** The durability point is explicit. Before the batch ends, a crash can lose only objects that nothing names yet. After it ends, the objects are on disk, and only then does the index transaction run.
- **Negative.** Within a batch, a crash can lose up to 63 of the batch's objects. They are lost unnamed (the index was not written), so re-running the add restores them. In patra's autocommit, a crash can also leave a page torn. That is true of `FULL` mode as well; BATCH widens the window from one statement to at most 64.
- **Negative.** In autocommit, patra still ignores `page_write`'s return inside a statement (L12, on patra's roadmap). BATCH does not make that worse: an object row's insert was already autocommit.
- **Neutral.** The index transaction is now the larger cost (3.6 s of the 7.8 s), and it is patra's per-page WAL sync. It is listed as an upstream ask; it is not sit's to remove without giving up the atomic add.

## Alternatives considered

- **One transaction for the objects.** Rejected: the WAL's sync per page made it slower than BATCH for the same rows, and it buys an atomicity the objects do not need.
- **Chunked transactions** (commit every N objects). Same per-page sync, plus N commits; no better than BATCH.
- **Writing the objects with `PATRA_SYNC_BATCH` and never flushing explicitly** (v0.6.10's shape). Rejected for the same reason v0.6.10 reverted it: nothing would mark where durability ends.
- **Skipping the sync altogether, as git does by default** (`core.fsync` off). Rejected: sit's rule is that a write is checked before anything names it, and a write is not known to be on disk until it is synced.
