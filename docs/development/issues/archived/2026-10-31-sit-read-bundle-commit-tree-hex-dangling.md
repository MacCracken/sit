# `dist/sit-read.cyr` references `commit_tree_hex`, which the read profile does not define — RESOLVED

**Resolution:** Closed in sit 1.13.2: `commit_tree_hex` moved to `commit.cyr`, and integration section 49 fails on any unresolved symbol outside architecture 006's table.

**Discovered:** 2026-10-31 during owl's 1.5.1 dependency bump (cyrius 6.7.18, sit 1.13.0); recorded as the
audit's INFO-008.
**Severity:** Low. No consumer can reach it today, but it is an undocumented hole in the bundle's closure.
**Affects:** sit 1.7.6 – 1.13.0 `dist/sit-read.cyr` (introduced by `d476d1b`, 2026-10-19, "audit and
repairs").

## Summary

Every consumer build against the read bundle now prints a fourth unresolved symbol:

```
warning: undefined function 'commit_tree_hex'
```

alongside the three ADR 0013 documents as deliberate dead-path placeholders (`load_signing_seed`,
`sign_commit_body`, `verify_commit_body`). `cmd_show` (`src/diff.cyr:1701` at 1.13.0) calls
`commit_tree_hex`, which is defined in `src/history.cyr:47`, and `[lib.read]` includes `src/diff.cyr` but not
`src/history.cyr`. (`src/rebase.cyr:350` calls it too, outside the read profile.)

## Reproduction

```sh
cd sit && git show 1.13.0:dist/sit-read.cyr | grep -n commit_tree_hex   # referenced, never defined
git grep -n '^fn commit_tree_hex' 1.13.0 -- src                         # src/history.cyr:47
git show 1.13.0:cyrius.cyml | sed -n '/^\[lib\.read\]/,/^\]/p'          # no src/history.cyr
```

Any consumer build (owl 1.5.1+) shows the warning.

## Why it is harmless today

cyrius 6.6.9+ refuses to emit a binary with a *reachable* undefined function, and `cmd_show` is a CLI
command no library entry point reaches. owl's builds succeed, and its call graph never touches it.

## Proposed fix

Any of:
- move `commit_tree_hex` (or the part `cmd_show` needs) into a read-profile module;
- keep CLI commands such as `cmd_show` out of the read bundle;
- if it is meant to dangle, add it to ADR 0013's list.

A downstream compile check (sit's consumer probe) that fails on any unresolved symbol outside the documented
list would catch the next one.

## Consumer-side workaround

None needed. owl documents the fourth warning in `cyrius.cyml` and `state.md` so it is not mistaken for a
regression.
