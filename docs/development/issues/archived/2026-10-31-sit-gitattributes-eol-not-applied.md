# `.gitattributes` eol / text / filter rules are not applied in git read mode — RESOLVED

**Resolution:** Closed in sit 1.13.2: `src/git_attr.cyr`. `filter`, `ident` and `working-tree-encoding` are `SIT_NOT_COMPARABLE`. `core.autocrlf` and the global attribute files are not read. See ADR 0011's amendment.

**Discovered:** 2026-10-31 during owl's P(−1) audit (1.5.3, INFO-007), VCS-path review.
**Severity:** Low. Wrong change markers for files git considers clean; no crash, no data risk.
**Affects:** sit 1.13.0 git read mode (verified); `sit_diff_path` consumers.

## Summary

git normalises a `text eol=crlf` file to LF in the blob and compares with conversion applied, so a CRLF
working copy is clean. sit compares the CRLF working copy byte for byte against the LF blob, so every line
differs. The same holds for `text`/`eol` in general, and for `filter` (an LFS pointer file is likely to behave
the same; git-lfs was not installed to confirm the clean side).

## Reproduction

```sh
git init -q . && printf '*.bat text eol=crlf\n' > .gitattributes
printf 'echo one\r\necho two\r\necho three\r\n' > run.bat
git add -A && git -c user.name=x -c user.email=x@x commit -qm base
git status --short                 # (empty: clean)
git cat-file -p HEAD:run.bat | od -c | head -1    # LF in the blob
owl -n --color=never --style=changes --paging=never run.bat
#  1 ~ │ echo one
#  2 ~ │ echo two
#  3 ~ │ echo three
```

## Proposed fix

Apply the worktree → blob conversion git would (at least `text` / `eol` / `crlf` from `.gitattributes`) to the
worktree side before diffing in git read mode. Treating `filter`ed paths as "cannot diff" would be better
than a wrong answer, and could use the distinct status asked for in
`2026-10-31-sit-diff-path-unreadable-reads-as-absent.md`.

## Consumer-side workaround

None.
