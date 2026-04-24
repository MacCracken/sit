# 003 — `sit commit` currently requires flat paths

**Status**: active constraint, tracked for v0.3.0.
**Related**: roadmap "Recursive tree structure" backlog item.

## The issue

Git's tree objects are **recursive**: a tree represents one directory, and subdirectories are child tree objects referenced by the parent. To commit a repo with `src/main.cyr`, git emits a root tree (containing one entry for `src`) plus a subtree (containing one entry for `main.cyr`), and the commit references the root tree.

v0.2.0 of sit ships the commit flow with flat trees only — all entries are files in a single top-level tree. If any staged path contains `/`, `sit commit` errors out:

```
sit: subdirectory paths not yet supported
sit:   see docs/architecture/003 for status
```

## Why this was chosen

Recursive trees require:

1. Path segmentation + grouping by first segment.
2. Stable sort with git's special rule (directory entries compared as if they had a trailing `/`).
3. Recursive subtree construction and hash accumulation.
4. Hex→raw-bytes encoding of child hashes inside tree entries.

Each piece is manageable, but together they're ~150 lines of subtle code. Shipping a working flat-tree commit today unblocks the rest of the v0.2.0 loop (`log`, `status`, `diff`) and lets those commands be built against a real commit graph. Recursive trees can land in v0.3.0 once the commit story is in use and the primitives have been validated.

## What works today

- Any staged path that does not contain `/`.
- Multiple files in the repo root: `sit add a.txt && sit add b.txt && sit commit -m "..."`.
- Any number of commits, including linking via `parent <hex>` when `.sit/refs/heads/main` already holds a prior commit.

## What doesn't

- `sit add src/main.cyr` followed by `sit commit` — rejected at commit time (the blob is stored fine; only the tree layer refuses).
- Repositories with any nested structure.

## When this revisits

v0.3.0 — alongside `sit status` / `sit log`, which need to walk tree objects anyway. At that point the tree reader code exists and it's a smaller step to make the writer symmetric.

## How to apply

- New subcommands that walk or build trees should assume flat trees for now. Don't bake the limitation into their public API — take (or return) full relative paths, not segmented ones.
- When v0.3.0 lands recursive trees, only the tree-writer (`build_flat_tree` → `build_tree`) and tree-reader (to be written) need to change; callers continue passing/receiving full paths.
