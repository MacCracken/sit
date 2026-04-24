# 002 — Loose-file object store until patra grows a BLOB type

**Status**: active constraint.
**Related**: [ADR 0001](../adr/0001-no-ffi-first-party-only.md) (first-party only).

## The issue

CLAUDE.md's opening move calls for "patra-backed objects and sigil-hashed refs". Patra today (1.5.5) exposes exactly two column types:

```cyrius
enum ColType { COL_INT = 0; COL_STR = 1; COL_INT_SZ = 8; COL_STR_SZ = 256; }
```

`COL_STR` is a fixed 256-byte column, null-terminated (`COL_STR_SZ - 1` usable bytes). No `COL_BLOB`. A compressed sit object for anything larger than a trivial file will not fit.

## What sit does instead

Objects are stored as loose files, git-compatible layout:

```
.sit/objects/<hex[0:2]>/<hex[2:64]>
```

Contents: `zlib_compress("blob <len>\0<content>")`. The `blob <len>\0` prefix is git's object framing; hashing it makes sit's object IDs byte-equal to git's SHA-256 object IDs for identical content.

The staging index is a plaintext append-only file at `.sit/index`, format `<hex>\t<path>\n`. That's a placeholder — the real index wants to live in patra once we're at the staging layer (path + hash both fit easily in 256-byte `COL_STR` columns).

## What patra is used for today

Nothing, in sit. The dep is declared in `cyrius.cyml` and link-resolves cleanly, but we don't open a patra store yet. That turns on when we implement a proper staging index with mutation (update-in-place on re-add, deletion on `sit rm`).

## When this revisits

- Patra gains a `COL_BLOB` type (variable-length binary column). At that point, objects can migrate into a `patra` table and the loose-file layout becomes the fallback for pre-migration repos (or gets dropped).
- Until then, blobs-as-files is the sovereign-but-pragmatic middle.

## How to apply

- New subcommands that read/write objects should go through loose-file helpers, not patra.
- When the staging index grows features (update, delete, query), it can land in patra as a single `index(path STR, hash STR, mode INT)` table — that's a clean fit for current patra.
