# 0016 — Reachable history is stored in git-format packs, written by `sit gc`

**Status**: Accepted
**Date**: 2026-10-20

## Context

sit stores every object as one row of `objects(hash STR, ty INT, content BYTES)` in `.sit/objects.patra`, compressed whole. At 1,600 commits of the benchmark fixture (one file added per commit, so each root tree is the previous one plus an entry), that store is **62.8 MiB**. git keeps the same history, in the same SHA-256 object format, in **1.03 MB** after `git gc` (measured 2026-10-20, git 2.56). Two things add up:

- **No deltas.** Successive trees are near-identical and were stored whole. Tree content is quadratic in commit count.
- **A page per value.** patra keeps each BYTES value in a chain of 4 KiB pages, never sharing one. So 4,800 objects cost at least 19 MiB whatever they hold.

The roadmap planned the first fix: a column naming each row's delta base, a migration for existing stores, `read_object` reconstructing, `fsck` reconstructing before it hashes, and transfer ordering bases first. That plan would have left the second cost untouched. A 100-byte delta row still takes a 4 KiB page, so the fixture floors at about 21 MB, 13 times git. Small objects need to share storage, and a BYTES value cannot be read in part. So the shared storage has to be files read by offset.

sit already reads such files. Since 1.2.0 `git_pack.cyr` has read git packs for `.git/` repositories: idx v2 lookup, OFS/REF delta chains bounded in depth and output, and mapped files. It has been fuzzed and hardened through three audits (S-24, D3–D6, R3–R5). The objects sit writes are byte-compatible with git's SHA-256 mode, so git's pack format can hold them unchanged.

## Decision

**`sit gc` writes every reachable object into a pack, `.sit/packs/pack-<id>.pack` with its `.idx`, in git's SHA-256 pack v2 / idx v2 format. The read path serves packs first, then rows. objects.patra keeps only loose objects. The wire does not change.**

- **Format.** The format is git's: pack header, entries of type, size and zlib data, OFS_DELTA against an earlier entry, and a SHA-256 trailer. The idx has fanout, sorted ids, CRC-32s, 4- and 8-byte offsets and both checksums. A pack is named by its trailer, as git names its packs. `git index-pack --object-format=sha256` rebuilds sit's `.idx` byte for byte, and `git verify-pack` accepts the pack. The integration suite asserts both (39i).
- **Self-contained.** sit packs carry OFS_DELTA only. The reader refuses a REF_DELTA in one (`_pack_obj_ex(…, allow_ref = 0)`), because resolving it would reach into `.git/`. No sit pack depends on another.
- **Deltas.** gc walks newest commit first and uses Subversion's skip-deltas. Counting the versions at a path newest first, version *k* is a delta against version `k & (k-1)` when that is under half its size, else against the adjacent version, else whole. A chain is at most popcount(*k*) links, so the newest version, the one a checkout reads, is whole, and the old ones are a few deltas from it. In the fixture the deepest chain is 10 and one tree of 1,600 is whole. The first cut chained each version to the next, held to 50 (git's default depth), and kept 33 whole trees, 62% of the pack.
- **Reading.** `read_object` tries the packs first, then rows (once a repository has any packs). Packs are found by their `.idx` and listed once per process. They change only under gc, which runs alone (see the store lock, architecture 008). A small delta base cache in `_pack_obj_ex` (32 MiB, keyed by pack mapping and offset) makes a chain read in order cost one delta per object. Without it, fsck re-applied whole chains. git mode uses the same cache.
- **Rows are loose objects.** Everything written since the last gc is a row, and so is everything gc found unreachable. When gc stops reaching a packed object, it writes it back as a row ("loosens" it, as `git repack -A` does). The patra schema does not change. A store written by 1.9.0 needs no migration and is simply all rows.
- **`fsck`** checks rows and packs apart, each through its own reader, and hashes every object against its id. It also checks each pack's and `.idx`'s trailing SHA-256, and that the `.idx` names its pack's. `--prune` deletes rows only. A packed dangling object is reported as kept, and the next gc loosens it so a later `--prune` can judge it by the grace window. Delta bases need no fsck edge, because a pack is self-contained and is never pruned in part.
- **Transfer.** Every reader of stored bytes for the wire goes through `db_object_read_raw` / `db_object_read_both`. There a packed object is reconstructed and compressed once, as it leaves the store. The receiving side is unchanged: it verifies each object against its id (`_object_verify`) and stores the bytes as they came. A `has` check counts packed objects as present, so a fetch or push never adds a row duplicating one. Shipping packs or deltas on the wire is a separate, negotiated step (roadmap).
- **gc's order** keeps every object readable throughout. First the pack and `.idx` are written under temporary names, synced, and read back through the reader every command uses, each object hashed against its id. Only then are they named and the directory synced. Next objects.patra is rewritten beside itself without the packed objects, with every row verified going in and again from the new file, and renamed over the old. Last the older packs are removed. A crash leaves duplicates, never a gap. gc refuses to start on a repository with a missing or mismatched object.

## Consequences

- **Positive.** The fixture's store goes from 62.8 MiB to 875 KiB (pack 683 KB, idx 193 KB, rows 20 KB). git stores the same history in SHA-256 in 1.03 MB (pack 819 KB, idx 193 KB, rev 19 KB). Reads get faster too: `log` takes 62 ms against 116 ms, and `fsck` 2.0 s against 7.1 s. git can read sit's packs, which gives a differential test of the writer for free.
- **Positive.** No schema change and no migration. The pack reader that gets the new duty is the most heavily fuzzed code in the tree.
- **Negative.** A repository gc'd by 1.10.0 needs sit ≥ 1.10.0 to read its history. Older binaries do not know `.sit/packs/` and find the packed objects missing, so they fail closed: their `fsck` reports `missing` and refuses `--prune`. This also covers consumers built against an older `dist/sit-read.cyr`. gc is opt-in, so nothing changes until someone runs it.
- **Negative.** Serving a packed repository costs a compression per object sent, because the wire carries whole objects. Level 1 keeps a clone of the packed fixture to +20% over the same history unpacked (level 6 cost 43%), and the receiver stores everything loose until its own gc. The receiver still never recompresses. The CLAUDE.md transfer rule now says this.
- **Negative.** gc needs the store to itself, so it refuses while `sit serve` (or any sit process) has the repository open. That limitation belongs with 1.11.0's serving work.
- **Neutral.** Every gc repacks everything reachable (`repack -a -d`). Incremental packing, keeping old packs and adding a new one for recent objects, is later work if repack time ever matters. The fixture takes 5.3 s the first time (2.8 s of it reading 63 MB of rows) and 2.6 s after; git takes 0.6 s.

## Alternatives considered

- **A delta-base column in `objects` (the roadmap's plan).** It needs a migration, and the reader, fsck, prune (delta-base edges) and transfer ordering all have to learn it. It still pays a 4 KiB page per delta. The fixture's floor is about 21 MB.
- **Flag a delta in `ty` and keep the base id in the row.** That avoids the migration, but has every other cost of the column, the page floor included.
- **Packs inside patra, one BYTES value per pack.** patra reads a BYTES value whole, so every object read would read its whole pack.
- **A sit-native pack format.** It would need a new reader, with no git-checked differential and no fuzz history, to store bytes git's format already stores. That is not the kind of on-disk compatibility "that costs nothing" sit aims for.
- **No gc, deltify on write.** That puts a delta search on every commit and pull. The win comes from history, so it belongs in a maintenance pass that sees all of it, as in git.
