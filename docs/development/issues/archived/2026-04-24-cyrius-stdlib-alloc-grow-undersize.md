# cyrius stdlib `alloc`: grow-by-1MB ignores requested size, SIGSEGV on any single alloc > 1 MiB — RESOLVED

**Discovered:** 2026-04-24 during sit v0.6.1 S-33 triage (`sit status` SIGSEGV on 100-commit / 100-file repo)
**Severity:** Critical
**Affects:** cyrius 5.6.x at the time of filing — verified buggy on 5.6.25, 5.6.30, 5.6.32, 5.6.33. Bug was in `lib/alloc.cyr` (Linux brk path) and `lib/alloc_macos.cyr` (mmap path); both grew by a fixed 0x100000 step per over-end allocation. `lib/alloc_windows.cyr` was not affected in the same shape (never grows; fails cleanly).

## Resolution

**Fixed in cyrius 5.6.34** with the proposed hunks below. sit picks up the fix in v0.6.1 via the `cyrius.cyml [package].cyrius` pin bump from `5.6.25` → `5.6.35` (5.6.35 was the latest patch when the bump landed; 5.6.34 was the first version carrying the fix).

Verification on sit, post-bump:
- `sit status` on the 100-commit / 100-file fixture: 10/10 clean exits (was 0/10 previously).
- Full sit test suite: 101/101 passing.
- No sit-side `fl_alloc` consumer-side workaround needed; the upstream fix landed before v0.6.1 shipped, so the workaround proposed below was not committed.

A separate failure surfaced from the same triage — `read_object` returns "unreadable" for ~20% of objects on the same fixture even after the allocator fix lands. That symptom was originally folded into this issue under a "may or may not be the same bug" framing. The 5.6.35 verification falsified the one-bug hypothesis: bit-for-bit identical bad-object set with the upstream allocator fix as with the locally-patched allocator. The unreadable-at-scale failure is tracked as its own open issue at [`../2026-04-24-read-object-unreadable-at-scale.md`](../2026-04-24-read-object-unreadable-at-scale.md).

## Original report

### Summary

The cyrius stdlib bump allocator grew the heap by exactly 1 MB (`0x100000`) whenever `_heap_ptr` crossed `_heap_end`, without checking whether 1 MB was enough to cover the new `_heap_ptr`. If the triggering `alloc(size)` requested more than 1 MB in a single call, the newly-mapped region ended ~size−1 MB short of the returned pointer. `alloc` reported success; the caller's first write into the tail of the buffer hit an unmapped address and the process SIGSEGV'd.

This was not a "heap exhausted" / OOM failure — it was a silent grow-undersize bug. The caller got what looked like a valid pointer and crashed on first tail-write, not on the allocation itself.

sit hit it in `src/object_db.cyr:read_object` — the retry path allocates a 16 MiB decompression buffer when the first `zlib_decompress` attempt fails:

```
if (dec_cap < 16 * 1024 * 1024) {
    dec_cap = 16 * 1024 * 1024;
    decompressed = alloc(dec_cap);   # <-- 16 MiB, tripped the allocator bug
    ...
}
```

Any cyrius consumer that called `alloc()` for more than 1 MB in a single call would hit this the moment the allocation landed near the current `_heap_end`.

### Reproduction

#### Minimal cyrius-only repro

```cyrius
include "lib/alloc.cyr"
include "lib/syscalls.cyr"

fn main() {
    alloc_init();
    var a = alloc(0xF0000);              # push _heap_ptr near _heap_end
    var b = alloc(4 * 1024 * 1024);      # 4 MiB > 1 MB grow step
    store8(b + 4 * 1024 * 1024 - 1, 42); # write at the tail
    return 0;
}

var r = main();
syscall(SYS_EXIT, r);
```

Expected: exit 0. Actual on cyrius ≤ 5.6.33: SIGSEGV on the `store8`.

#### sit repro (the path that surfaced this)

```
$ cyrius build src/main.cyr build/sit
$ D=$(mktemp -d)
$ cd "$D" && build/sit init
$ for i in $(seq 0 99); do
>   echo "file $i content" > "f$i.txt"
>   build/sit add "f$i.txt"
>   build/sit commit -m "c$i"
> done
$ build/sit status
Segmentation fault (core dumped)      # exit 139, 10/10 runs on cyrius ≤ 5.6.33
```

Under strace + stderr instrumentation of the growth path, the crashing alloc was `size=16777216 need=15813664`:

```
alloc-grow size=16777216 need=15813664
alloc-grow size=32 need=14765120
--- SIGSEGV {si_signo=SIGSEGV, si_code=SEGV_MAPERR, si_addr=0xcbddc20} ---
```

The SEGV_MAPERR address was ~13.5 MiB past the most recent `brk` target — signature of a buffer returned by `alloc` that extends past the newly-mapped region.

### Root cause

`lib/alloc.cyr` lines 55–65 (Linux brk path) at the time of filing:

```cyrius
if (_heap_ptr > _heap_end) {
    # Grow heap by 1MB
    var new_end = _heap_end + 0x100000;     # <-- fixed delta, regardless of how far past
    var result = syscall(12, new_end);
    if (result < new_end) {
        _heap_ptr = ptr;
        return 0;
    }
    _heap_end = new_end;
}
return ptr;
```

After `_heap_ptr = new_ptr` committed the allocation, the grow step only raised `_heap_end` by 1 MB. If `size > 0x100000` (or if the current `_heap_end - old _heap_ptr` slack was smaller than `size - 0x100000`), `_heap_ptr` ended up above the new `_heap_end`. The function returned `ptr` without noticing.

Same shape in `lib/alloc_macos.cyr` lines 46–60 — mmap-based grow also used the fixed `0x100000` step.

### Proposed fix (shipped as-is in cyrius 5.6.34)

**`lib/alloc.cyr` (Linux):**

```cyrius
if (_heap_ptr > _heap_end) {
    # Grow to cover _heap_ptr, rounded up to the next 1MB boundary.
    var new_end = (_heap_ptr + 0xFFFFF) & (0 - 0x100000);
    var result = syscall(12, new_end);
    if (result < new_end) {
        _heap_ptr = ptr;
        return 0;
    }
    _heap_end = new_end;
}
```

**`lib/alloc_macos.cyr`:** loop 1 MB mmaps while `_heap_end < _heap_ptr`, preserving the contiguity guard per step (mmap-at-hint contract is stricter than brk's).

Both shapes shipped in 5.6.34 with comments referencing the original bug.

### Consumer-side workaround (NOT SHIPPED — upstream fix arrived first)

Was planned for sit v0.6.1 in case the upstream fix didn't arrive in time:

1. Route the three big `alloc()` calls in `src/object_db.cyr:read_object` through `fl_alloc` instead. `fl_alloc` for sizes > 4 KB mmaps directly and sidesteps the buggy bump-grow entirely.
2. Same change in any other hot-path alloc that could exceed 1 MB: `hash_blob_of_content`, `read_file_heap`, `write_typed_object`, `lcs_diff`.

The upstream fix landed in 5.6.34 before sit cut v0.6.1, so this workaround was not committed.
