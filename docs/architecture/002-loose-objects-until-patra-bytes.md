# 002 — Loose-file object store until patra grows a `COL_BYTES` type

**Status**: superseded by patra 1.6.0 (2026-04-23). `COL_BYTES` ships; sit can migrate its object store into a patra table. This ADR is kept for historical context; the "How to apply" section is the current migration guide.
**Related**: [ADR 0001](../adr/0001-no-ffi-first-party-only.md) (first-party only).

## The issue (resolved in patra 1.6.0)

CLAUDE.md's opening move calls for "patra-backed objects and sigil-hashed refs". Patra 1.5.5 exposed exactly two column types:

```cyrius
enum ColType { COL_INT = 0; COL_STR = 1; COL_INT_SZ = 8; COL_STR_SZ = 256; }
```

`COL_STR` is a fixed 256-byte column, null-terminated (`COL_STR_SZ - 1` usable bytes). There was no variable-length binary type — a compressed sit object for anything larger than a trivial file wouldn't fit.

Patra 1.6.0 adds `COL_BYTES = 2` with chain-page overflow storage (`PAGE_BYTES`, 4072-byte payload per page). Row field is 16 bytes `(first_page, length)`. SQL accepts `BYTES` (canonical) and `BLOB` (legacy alias). See [patra CHANGELOG 1.6.0](https://github.com/MacCracken/patra/blob/main/CHANGELOG.md#160---2026-04-23).

## What sit does instead

Objects are stored as loose files, git-compatible layout:

```
.sit/objects/<hex[0:2]>/<hex[2:64]>
```

Contents: `zlib_compress("blob <len>\0<content>")`. The `blob <len>\0` prefix is git's object framing; hashing it makes sit's object IDs byte-equal to git's SHA-256 object IDs for identical content.

The staging index is a plaintext append-only file at `.sit/index`, format `<hex>\t<path>\n`. That's a placeholder — the real index wants to live in patra once we're at the staging layer (path + hash both fit easily in 256-byte `COL_STR` columns).

## What patra is used for today

Nothing, in sit. The dep is declared in `cyrius.cyml` and link-resolves cleanly, but we don't open a patra store yet. That turns on when we implement a proper staging index with mutation (update-in-place on re-add, deletion on `sit rm`).

## Resolution

Patra 1.6.0 ships `COL_BYTES`. Migration is now unblocked:
- Add an `objects(hash STR PRIMARY, type INT, content BYTES)` table via `patra_exec(db, "CREATE TABLE objects (...)")`.
- Write objects through `patra_insert_row` (SQL `INSERT` can't carry binary; this is the only path). Slots: `types[COL_STR, COL_INT, COL_BYTES]`, with `sptrs/slens` for the hash, `ivals` for the type, `bptrs/blens` for the compressed content.
- Read objects through `patra_result_get_bytes_len(rs, row, col)` + `patra_result_read_bytes(db, rs, row, col, out)`. Caller sizes `out` from the len call.
- Keep loose-file reads as a fallback only while migrating pre-1.6.0 repos; drop the loose-file write path once migration lands.

## How to apply

- New subcommands that read/write objects should go through patra once migration lands; use loose-file helpers only as a read-only fallback for pre-migration repos.
- The staging index (when it grows update/delete/query) can still live in a simple `index(path STR, hash STR, mode INT)` patra table — no BYTES needed there.
- `sit commit` can now land blob + tree + commit atomically through patra's WAL — the motivation for biting off `COL_BYTES` in the first place.
