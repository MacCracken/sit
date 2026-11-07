# `sit_diff_path` flattens the whole HEAD tree on every call: a 200 KB `.git` costs gigabytes to diff one file — RESOLVED

**Resolution:** Closed in sit 1.13.2: `sit_diff_path` reads one tree per path component through `tree_path_find`, and `flatten_tree` is bounded at 256 MiB with `SIT_TREE_TOO_BIG`. Peak on the repro, N = 100 and N = 2,000 alike: 5.2 MB. See the CHANGELOG's 1.13.2 entry.

**Discovered:** 2026-10-31 during owl's P(−1) audit (1.5.2 → 1.5.3, INFO-004), VCS-path review.
**Severity:** High. A repository is hostile input to a viewer: a 200 KB crafted `.git` makes any in-process
reader of `sit_diff_path` allocate gigabytes, or die with "sit: out of memory", just by viewing one file in it.
owl has no workaround short of turning change markers off.
**Affects:** sit 1.13.0 (`dist/sit-read.cyr`, verified); every consumer of `sit_diff_path` / `sit_repo_status`
(owl, thoth). The code path dates from the read API itself.

## Summary

To diff one path, `_sit_diff_path_in` → `read_head_tree_entries` → `commit_tree_entries` → `flatten_tree`
materialises **every** entry of HEAD's tree, each with its full path (depth × up to 255 bytes), on the
never-freed heap. `_TREE_MAX_NODES` (2M) bounds the number of entries, not the bytes: a tree that reuses one
subtree object many times stores almost nothing on disk but expands to millions of long paths in memory.

Measured on owl 1.5.3 (sit 1.13.0), viewing a clean 12-byte `README` with change markers on (peak RSS from
`getrusage`, transparent huge pages at the distribution default; the audit reviewer measured lower absolute
figures on another configuration, with the same linear shape):

| HEAD tree (20-deep chain of 255-byte names, N subtrees × 1,000 empty blobs) | `.git` size | owl peak RSS | time |
|---|---:|---:|---:|
| markers off (`--style=no-changes`) | 200 KB | 13.5 MB | 0.00 s |
| N = 25 | 200 KB | 436 MB | 1.8 s |
| N = 100 | 200 KB | 1,731 MB | 7.3 s |
| N = 2,000 (at `_TREE_MAX_NODES`) | — | "sit: out of memory", file never shown (≈ 13 GB uncapped) | — |

In a real 100K-file repository the same walk costs ~34 MB and 0.34 s per viewed file, and it accumulates
across one process (`owl a b c …`: 50 files, 1.72 GB).

## Reproduction

```sh
python3 repros/2026-10-31-sit-tree-bomb.py tb 20 100 1000 255   # repo dir, depth, N, leaf size, name length
cd tb
owl -n --color=never --style=changes --paging=never README      # ~1.7 GB, 7 s
owl -n --color=never --style=no-changes --paging=never README   # 13.5 MB
```

Any `sit_diff_path` caller reproduces it; owl is just the viewer that found it.

## Root cause

`flatten_tree` is the only way the read API reaches HEAD's blob for a path. It is O(entries × path length)
in time and memory, where diffing one path needs only O(depth) tree reads.

## Proposed fix

Resolve the single path by walking its own components: read the root tree, find the first component, read
that subtree, and so on, freeing (or freelist-allocating) each tree buffer as it goes. That is O(depth) reads
and O(1) retained memory per call, and it makes the bomb inert. `sit_repo_status` legitimately needs the
whole tree, but should bound **bytes** (path bytes and entries) rather than entries alone, and fail closed
with a status the caller can see.

## Consumer-side workaround

None that keeps markers. owl 1.5.3 bounds the **worktree** side before calling sit (8 MiB / 524,288 lines,
FINDING-020), which does nothing here, since the viewed file is 12 bytes. Running VCS in a forked,
rlimited child is the only owl-side containment, and owl has not taken it (a design change).
