# 001 — `args.cyr` relies on post-return stack memory

**Status**: documented constraint of the Cyrius stdlib we depend on (not a sit decision).
**Affects**: any `argv(n)` call in `src/main.cyr`.

## The issue

Cyrius's `lib/args.cyr` implements `args_init()` by reading `/proc/self/cmdline` into a **stack-local buffer** and stashing its address in a global:

```cyrius
fn args_init() {
    var buf[4096];                              # stack buffer
    var fd = syscall(2, "/proc/self/cmdline", 0, 0);
    var n = syscall(0, fd, &buf, 4096);
    syscall(3, fd);
    _args_base = &buf;                          # address outlives the frame
    _args_len = n;
    return n;
}
```

When `args_init()` returns, its stack frame is gone. `_args_base` now points at memory the runtime is free to reuse. `argc()` and `argv(n)` read from that pointer on every call, so they're technically reading freed stack memory.

It works in practice because nothing between `args_init()` and the `argv()` calls pushes enough stack to clobber the 4 KiB region — the typical pattern (`alloc_init(); args_init(); if (argc() < 2) ...; var cmd = argv(1);`) keeps the same call depth the buffer was written at.

## How to apply in sit

- Call `args_init()` immediately after `alloc_init()` in `main()`, and read the args you need (`argv(1)`, `argv(2)`, …) into heap-owned strings before doing anything with deep call stacks (patra writes, sigil hashing, large allocations via stack-heavy stdlib code).
- If a subcommand needs an argv value later, **copy it** (e.g. `str_from(argv(n))`) at the top of `main()` — do not hold the raw pointer across function calls.
- If we ever get crashes that look like corrupted argv strings, this is the first suspect.

## Upstream

Fixing this requires either capturing `argc`/`argv` from the kernel entry prologue (the approach `args_macos.cyr` already takes via `x28`) or heap-allocating the buffer inside `args_init()`. Not sit's bug to fix — note it here so we don't forget it exists, and revisit if we hit it.
