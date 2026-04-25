# `read_object` returns "unreadable" for ~20% of objects on a 100-commit / 100-file sit repo — RESOLVED

**Discovered:** 2026-04-24 during sit v0.6.1 S-33 triage. Originally folded into the cyrius allocator-grow issue under a "may or may not be the same bug" framing; proven independent on 2026-04-24 when the cyrius 5.6.34 fix resolved the SIGSEGV but left this symptom bit-for-bit unchanged.
**Severity:** Critical
**Affects:** sit 0.6.0 against sankoch 2.0.1.

## Resolution

**Fixed in sankoch 2.0.3.** sit picks up the fix in v0.6.1 via the `cyrius.cyml [deps.sankoch].tag` bump from `2.0.1` → `2.0.3`.

Verification on sit, post-bump (sankoch 2.0.3, cyrius 5.6.35):
- `sit status` on the 100-commit / 100-file fixture: 10/10 clean exits, output `nothing to commit, working tree clean` (was every-tracked-file-as-"new file:" previously).
- `sit fsck`: `checked 300 objects, 0 bad` (was `checked 247 objects, 53 bad` previously). The total object count corrected from 247 to the expected 300 (100 commits + 100 trees + 100 blobs), confirming sankoch 2.0.1 was failing on the **write side** too — some `zlib_compress` calls were producing buffers that `zlib_decompress` later rejected, AND some objects were never landing in patra at all. Both surfaces fixed by the dep bump.
- Tests: 101/101 passing.
- Sibling allocator-bug crash also stays gone — sankoch 2.0.3 succeeds on the first `zlib_decompress` attempt, so the 16 MiB retry path that tripped the cyrius alloc grow bug never fires in sit. The cyrius pin still bumped to 5.6.35 in the same release for defense-in-depth (any future sit code that trips a > 1 MB alloc gets the upstream fix), but sankoch alone was empirically sufficient to resolve both surfaces of S-33 in sit's hot path.

The triage plan in the original report ("Bytes roundtrip at patra layer / sankoch compress-decompress symmetry / instrument sit's write path") was not run — the user already had context that sankoch had a fix in 2.0.3 and the empirical bump verified it. Hypothesis #2 (sankoch zlib_decompress rejects bytes that zlib_compress produced in the same process) was correct.

## Original report

### Independence from the sibling allocator bug — proven

## Independence from the sibling allocator bug — proven

Originally filed alongside the cyrius stdlib `alloc` grow-undersize bug as a "may or may not be the same bug" merged report. The hypothesis being tested was: a single cyrius memory-corruption bug (e.g. stale pointer into reused bump-heap) producing two symptoms — hard SIGSEGV on > 1 MiB allocs, quiet bytes corruption everywhere else.

That hypothesis is now **falsified**. cyrius 5.6.34 shipped the allocator grow-rounding fix matching the proposed patch. sit picked it up via the `cyrius.cyml [package].cyrius` pin bump from `5.6.25` to `5.6.35`. Re-running the same 100-commit / 100-file fixture against the bumped sit binary:

| symptom | before bump (cyrius 5.6.25) | after bump (cyrius 5.6.35) |
|---|---|---|
| `sit status` SIGSEGV (sibling issue) | 10/10 crashes (exit 139) | 10/10 clean (exit 0) |
| `sit fsck` "unreadable" objects | 53/247 | **53/247 (identical hashes)** |

Bit-for-bit identical bad-object set across the bump. The two symptoms are independent. Sibling RESOLVED writeup: [`2026-04-24-cyrius-stdlib-alloc-grow-undersize.md`](2026-04-24-cyrius-stdlib-alloc-grow-undersize.md).

## Summary

On a freshly-built 100-commit / 100-file sit repository (each commit adds one ~17-byte text file), `sit fsck` reports ~20% of objects as "unreadable":

```
checked 247 objects, 53 bad     # N=100, sit @ cyrius 5.6.35
```

`read_object` returns a nonzero error for these hashes. The failing path is the `zlib_decompress` retry inside `src/object_db.cyr:read_object` — the first decompress attempt returns `dlen <= 0`, the retry with `dec_cap = 16 * 1024 * 1024` also returns `dlen <= 0`, and the function returns `0 - 7`. (Pre-bump, the retry's 16 MiB `alloc()` was what crashed via the sibling allocator bug; that crash was hiding this failure mode behind a SIGSEGV.)

Scaling:

| N (commits / files) | total objects | bad (unreadable) |
|---|---:|---:|
| 5   | 15  | 0  |
| 20  | 59  | 1 (first bad at ~commit 15) |
| 50  | 122 | 28 |
| 100 | 247 | 53 |

Commit chain reads fine — `sit log` walks all 100 commits cleanly; `sit cat-file HEAD` reads the HEAD commit. What breaks is specifically a subset of the tree + blob objects written at higher commit indices. The HEAD commit's `tree <hash>` reference resolves but `sit cat-file <that-hash>` returns `sit: cannot read object (corrupt or missing)`, which is why `sit status` (which flattens the HEAD tree) sees zero entries in HEAD and labels every index entry as "new file:" — silent data correctness failure on top of the resolved SIGSEGV.

## Reproduction

```sh
$ cyrius build src/main.cyr build/sit               # cyrius >= 5.6.34
$ D=$(mktemp -d)
$ cd "$D" && build/sit init
$ for i in $(seq 0 99); do
>   echo "file $i content" > "f$i.txt"
>   build/sit add "f$i.txt"
>   build/sit commit -m "c$i"
> done
$ build/sit fsck
unreadable 119cdebc22bb910e5b9c422222680be4fcac1487ee024425c1d1b171bedf147c
unreadable 8b1447a87332bd3ff82d59ddf88f4066760c991e2937b184b0a4b1429911fa05
... (51 more)
checked 247 objects, 53 bad
$ build/sit status | head -3
On branch main

Staged for commit:
  new file:  f0.txt          # WRONG — these are committed; HEAD tree was unreadable
```

Threshold for the first bad object is between ~15–20 commits for this content shape.

Ground-truth: each commit writes three objects (blob, tree, commit). None of these should be > ~4 KB uncompressed at this fixture's scale (blob ~17 B, tree ~4 KB at N=100, commit ~300 B). None can plausibly exceed the default `dec_cap = blen * 16` first-attempt budget, so the retry path (the sole path that succeeds on truly high-ratio zlib streams) should not fire at all. That it does fire, and then also fails, is the anomaly.

## Root cause — uncertain, needs triage

The error surface is `zlib_decompress` returning `<= 0` on two successive calls with different `dst_cap` arguments against the same `compressed` buffer. Three families of root cause are consistent:

1. **patra stored bytes that differ from what was asked to be stored.** Page-boundary / WAL-flush / serialization bug in patra 1.6.0 such that the row's `content` BYTES column comes back truncated, mis-aligned, or cross-row-contaminated at higher row counts. Most likely given the scaling behavior — first failure at ~commit 15 correlates with patra transitioning from page 1 to page 2 at ~40 rows × ~100 B/row. Would make this a **patra** issue.
2. **sankoch `zlib_decompress` rejects bytes that `zlib_compress` produced in the same process.** Bytes-on-wire are correct but not parseable. Would make this a **sankoch** issue. Against: if purely shape-sensitive, should show at low N with the same content, not scale.
3. **Memory corruption in cyrius unrelated to the now-fixed allocator grow bug.** A different bug shape — e.g. stale pointer into reused bump-heap memory, double-commit of `_heap_ptr` somewhere, race against patra's `fl_alloc` mmap regions. Less likely after independence proof, but not ruled out.

### Triage plan — run before proposing any patch

1. **Bytes roundtrip at patra layer.** Standalone cyrius program: open a fresh `.patra` DB, `patra_insert_row` compressed buffers matching sit's tree/blob shapes, close, reopen, `SELECT content`, `patra_result_read_bytes`, `memcmp` vs. the original. Run at row counts 10 / 50 / 100 / 500. If bytes diverge at any count → **patra confirmed**. If bytes match across the board → rule patra out.
2. **sankoch compress/decompress symmetry on sit-shaped inputs.** Standalone: zlib_compress → zlib_decompress → memcmp, across the exact compressed byte patterns sit produces for the 100-commit fixture (dump them first). If any single-process roundtrip fails → **sankoch confirmed**.
3. **Instrument sit's write path.** Inside `src/object_db.cyr:write_typed_object`, immediately after `zlib_compress` succeeds, call `zlib_decompress` on the just-produced buffer and compare to `full`. If the in-process roundtrip passes but the cross-process `read_object` fails, the corruption is between `patra_insert_row` and the next `SELECT`. If the in-process roundtrip ALSO fails on a just-compressed buffer, the bug is in sankoch or in cyrius's memory behavior around sankoch's scratch buffers.
4. **Only if (1) (2) (3) all come back clean:** stale-pointer / double-commit search in cyrius's bump allocator beyond the fixed grow bug. Do not start here.

Do not guess. Pin the layer first.

## Proposed fix

None — need to triage before proposing. The workaround below is a safety-net only; it does not fix what's actually being corrupted.

## Consumer-side workaround

**Available for sit v0.6.1** (not yet committed; awaiting decision):

1. **Loud-fail mitigation.** Add a post-commit verification step in `cmd_commit`: after `write_typed_object` returns the hash, immediately `read_object` the three just-written hashes and hard-fail the commit with a clear error if any come back unreadable. Turns silent scale-repo corruption into a refused commit. Does not recover already-corrupt bytes.

No consumer-side change can recover the already-unreadable bytes if symptom is genuinely patra-side. Until the underlying bug is pinned and fixed, **sit at scale (≥ ~20 commits, scaling with N) is not trustworthy for real trees**, matching the user's assessment that S-33 is a release-blocker for anyone using sit on real codebases. The cyrius pin bump in v0.6.1 fixes the SIGSEGV but not the data-correctness failure; v0.6.1 should ship without a "scale-repo parity" claim.

## Notes for the triage agent

- The cyrius stdlib allocator grow bug is no longer a confounder. cyrius 5.6.34 shipped the rounding fix; the symptom persists bit-for-bit identically. Anything still broken is in patra, sankoch, or cyrius elsewhere.
- Write-side allocator activity during the 100-commit fixture shows no `alloc-grow size > 1 MB` events (instrumented during the original triage), so even the original allocator bug never fired during writes at this scale. The bytes that get stored are produced by `zlib_compress` writes that completed without the allocator misbehaving.
- `read_object` retry path is the sole observable failure surface: `dlen <= 0` from `zlib_decompress(compressed, blen, decompressed, dec_cap=16 MiB)`. `patra_result_get_bytes_len` returns positive `blen` and `patra_result_read_bytes` returns 0 — patra claims the row exists and the bytes were read; the decompressor is what rejects them.
- `sit log` walks 100 commits fine → commit objects roundtrip cleanly at this scale. Failures cluster in trees + blobs written later in the sequence. Whether that's "later rows in the patra file" or "larger compressed buffers" is part of what the triage needs to separate.
- `sit fsck` uses the exact same `read_object` path as `status` / `log` / `cat-file`, so a fix here repairs all consumers uniformly.
