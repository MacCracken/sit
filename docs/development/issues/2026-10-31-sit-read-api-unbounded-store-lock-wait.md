# The read API waits forever on a held store lock, and creates `.sit/objects.flock` from a read-only view — OPEN

**Discovered:** 2026-10-31 during owl's P(−1) audit (1.5.3, INFO-005), VCS-path review.
**Severity:** Medium. A viewer hangs with no output for as long as another process holds the lock, and a
read-only consumer writes into the repository it views.
**Affects:** sit 1.11.0 – 1.13.0 (`dist/sit-read.cyr`; the per-call store session arrived at 1.11.0);
consumers `sit_diff_path` / `sit_repo_status` (owl, thoth).

## Summary

Since 1.11.0 the read API brackets each call with `store_enter` / `store_leave`, taking `.sit/objects.flock`
shared. When another process holds it exclusively, the reader waits with `_store_session_wait_ms = -1`,
which means no bound. It prints `sit: waiting for \`sit gc\` to finish with the object store` and blocks.
`flock(2)` needs only read access to the lock file, so in a shared repository any user who can read it can
hold `LOCK_EX` and hang every other user's viewer. Separately, `_store_lock_open` opens the lock file with
`O_CREAT`, so a read-only view **creates** `.sit/objects.flock` when it is missing.

## Reproduction

```sh
sit init && printf 'a\nb\n' > a.txt && sit add a.txt && sit commit -m init
( flock -x .sit/objects.flock sleep 8 & ); sleep 0.5
timeout 4 owl -n --color=never --style=changes --paging=never a.txt
# exit 124 after 4.0 s, 0 bytes on stdout,
# stderr: "sit: waiting for `sit gc` to finish with the object store"
sleep 8; rm .sit/objects.flock
owl -n --color=never --style=changes --paging=never a.txt
ls -l .sit/objects.flock     # recreated, 0 bytes, by a viewer
```

## Root cause

`_store_session_wait_ms = -1` (`lib/sit-read.cyr:6372` in owl's vendored copy), `store_enter` (`:6497`), and
`_store_lock_open` (`:6348`, `O_CREAT`).

## Proposed fix

A public way for a read-only consumer to choose the wait: a zero or bounded timeout, after which the call
returns a distinct "store busy" status instead of blocking. owl would pass 0 and show no markers rather than
hang. And open the lock file without `O_CREAT` on the read path: a missing lock file means no writer has
ever run, so there is nothing to wait for.

## Consumer-side workaround

None. The wait happens inside `sit_diff_path`, before owl renders anything.
