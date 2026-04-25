# 004 — Cyrius string literals are program-lifetime

**Status**: documented invariant of the Cyrius compiler we depend on (not a sit decision).
**Affects**: `src/tree.cyr` (mode literals stored into entry slots), and any pattern that stashes a raw `"..."` literal pointer for later read.

## The invariant

Cyrius compiles string literals into a fixed compile-time **string-data region** that is part of the produced binary's read-only data segment. The pointer the compiler emits for `"100644"` resolves to that region at runtime; the region is mapped for the entire process lifetime. Pointers to literals never go stale.

This is the standard model — equivalent to C's `.rodata` placement of `"..."` literals — but worth spelling out because the codebase exploits it directly:

```cyrius
# src/tree.cyr — store the literal pointer into a 24-byte entry slot
var le = alloc_or_die(24);
store64(le, "100644");          # mode pointer = literal address
store64(le + 8, name);
store64(le + 16, entry_hash(e));

# ...later, in build_tree's body-emission loop:
body_size = body_size + strlen(tlvl_mode(le)) + 1 + strlen(tlvl_name(le)) + 1 + 32;
```

`tlvl_mode(le)` loads back the literal pointer and `strlen`s it. Safe iff the pointer remained valid — which it does, because Cyrius literals are program-lifetime.

## Known limit

Cyrius's own [2026-04-13 security audit](https://github.com/MacCracken/cyrius/blob/main/docs/audit/2026-04-13-security-audit.md) flags the string-data region's compile-time size at **256 KB**. If a single Cyrius program's total string-literal bytes exceed 256 KB, the compiler silently corrupts the next memory region during interning. sit is currently nowhere near that limit (whole binary is < 1 MB and most of that is code, not literals), but anyone adding a doc string or large constant table to sit should keep this ceiling in mind.

## Why we don't switch to integer mode codes

The audit's S-32 fix offered an alternative: switch tree.cyr to store mode codes as integers (e.g. `040000`, `100644` as octal i64s) with a tiny format table that maps int → string at emit time. That works, but trades a free invariant for runtime indirection on the hottest tree-build path. Documented invariants beat rewrites for cases like this.

If the Cyrius string-data region's lifetime ever changes (e.g. a future toolchain version interns into a non-contiguous freelist that can be reclaimed), this note moves to the front of the page and tree.cyr gets the format-table treatment.

## How to apply in sit

- Storing a `"..."` literal pointer into a long-lived structure is fine.
- Storing a `str_from(...)` or `alloc_or_die(...)` heap pointer is also fine (those have heap lifetime, which is process-lifetime under the bump allocator).
- **Don't** store an `argv(n)` pointer (see [001](001-args-stack-buffer-lifetime.md)) — that's stack memory, different rules.
- **Don't** store a `patra_result_get_str(...)` pointer past `patra_result_free` — that points into result-set memory which is freed.
