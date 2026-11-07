# `sit_diff_path` reports "unreadable" as "absent" and "too big to diff" as "unchanged" — OPEN

**Discovered:** 2026-10-31 during owl's P(−1) audit (1.5.3, INFO-006), VCS-path review.
**Severity:** Medium. Silent wrong answers in both directions: a consumer marks an unchanged file entirely
new, or reports a heavily changed file as unchanged, and cannot tell either from the truth.
**Affects:** sit 1.13.0 (verified); `sit_diff_path` consumers (owl's change-marker gutter and `--diff`).

## Summary

1. **Unreadable → absent.** When the HEAD side cannot be read, `sit_diff_path` treats the path as absent at
   HEAD, so every worktree line becomes an ADD. Ways to get there: the blob is over `_OBJ_INFLATE_MAX`
   (16 MiB), the object is missing or corrupt, or the pack directory is larger than ~10K entries. An
   unchanged 22.9 MB tracked file therefore shows all `+`; `sit status` calls it modified too.
2. **Too big → unchanged.** When the Myers diff hits its cap (`dcap` 4096), the call returns 0 with no ops,
   which a consumer cannot distinguish from "no changes".

## Reproduction

```sh
git init -q . && python3 -c "
open('big.txt','w').write(''.join(f'line {i}\n' for i in range(2_000_000)))
open('alt.txt','w').write(''.join(f'v{i}\n' for i in range(8000)))"
git add -A && git -c user.name=x -c user.email=x@x commit -qm base
printf 'line 0\nline 1\nCHANGED\n' > big.txt          # HEAD blob is 24.9 MB
python3 -c "
L=[f'v{i}\n' for i in range(8000)]
for i in range(0,8000,2): L[i]=f'w{i}\n'
open('alt.txt','w').write(''.join(L))"

git diff --numstat big.txt     # 1  1999998   (lines 1-2 unchanged)
owl -n --color=never --style=changes --paging=never big.txt
#  1 + │ line 0
#  2 + │ line 1          <- unchanged lines marked new: HEAD side read as absent
#  3 + │ CHANGED

git diff --numstat alt.txt     # 4000  4000
owl --diff --color=never --paging=never alt.txt; echo $?   # prints nothing, exit 0
```

## Root cause

The read API has one success shape (an op list, possibly empty) and folds "could not read HEAD" and "diff
budget exceeded" into it.

## Proposed fix

Distinct results from `sit_diff_path`, at least: OK, HEAD side unreadable (with reason: too big, missing,
corrupt), and diff budget exceeded. owl would then skip markers and, under `--diff`, say why (it already does
for its own limits: "file too large to diff"). A caller-supplied budget (bytes / lines / cells) would also
let a consumer cap the HEAD side, which today only sit's 16 MiB inflate cap bounds; owl can pre-check only
the worktree side.

## Consumer-side workaround

Partial. owl 1.5.3 skips markers for worktree files over 8 MiB or 524,288 lines (FINDING-020), which avoids
some of the large-file cases from the worktree side. It cannot detect either case above.
