# 009 — patra's `DELETE` and `UPDATE` scan the table, and a transaction syncs per page

**Applies to**: every write to `.sit/index.patra` (`index_stage`, `rewrite_index`, `rm`, `mv`), and any batch of writes in one patra transaction. Measured on the patra 1.16.6 fold (cyrius 6.7.18), 2026-10-30.

## The constraints

1. **A `WHERE` on an indexed column is a lookup for `SELECT` and a scan for `DELETE` and `UPDATE`.** `tbl_delete` walks every data page of the table and evaluates the condition on each row. The B-tree on the column is updated, but it is not used to find the rows. `entries(path)` has had an index since 1.4.6, and its comment says it makes `DELETE … WHERE path = ?` targeted. It does not.

   Measured over 4,000 rows already present, then one statement per row, in one transaction:

   | statement | 1,000 rows | 4,000 rows |
   |---|---:|---:|
   | `SELECT hash_hex … WHERE path = '…'` | 26 ms | 108 ms |
   | `DELETE … WHERE path = '…'` | 159 ms | 2,084 ms |
   | `UPDATE … SET hash_hex = '…' WHERE path = '…'` | 259 ms | 3,809 ms |

   So deleting one row per path is O(N²) over N paths: 4,000 new files spent 3.0 s of a 3.8 s `sit add` deleting rows that were not there.

2. **Inside a transaction, the WAL syncs once per distinct page the transaction touches.** Each before-image is written to the WAL and `fdatasync`ed before the page itself is written (`wal_log_page`), freshly allocated pages included. A table of `STR` columns stores 256 bytes per string, so 10,000 index rows fill about 1,660 pages, and one transaction that writes them makes about as many syncs: 3.6 s on this host's SSD (ext4) under load, where git's whole `git add .` takes 0.4–0.6 s.

3. **Rows deleted in bulk are reused only in part.** Clearing the table (`DELETE FROM entries`) and inserting it again grew a 10,000-row file from 7.9 MB to 15.9 MB over ten rounds, and each round was slower than the last (339 → 492 ms).

## How sit lives with them

- `index_stage` (1.13.0) reads the index once, then:
  - leaves alone a path already staged at the same id;
  - only inserts a new path;
  - deletes the rows that do go up to 24 in one statement, `OR`-joined. patra takes 32 conditions and 128 tokens per statement; 24 conditions use 99 tokens.
- Up to 24 paths, reading the whole index costs more than it saves: a one-file add went from 1.2 to 1.5 ms of CPU. So their rows are deleted in one statement and inserted again, without reading the index.
- The index is never cleared and rewritten wholesale: that is constraint 3.
- `sit add`'s objects are written in patra's BATCH mode, not in a transaction: that is constraint 2 ([ADR 0018](../adr/0018-object-writes-in-batches.md)). The index stays one transaction, so an add lands whole, and pays constraint 2 for it.

## When this changes

Both 1 and 2 are listed as upstream asks on sit's roadmap. When patra's `DELETE` uses the index, the `OR` batching is no longer needed, though it is still correct. When its WAL syncs once per transaction rather than per page, a large add's index update falls from seconds toward one sync.
