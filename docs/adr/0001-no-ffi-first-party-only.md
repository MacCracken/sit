# 0001 — No FFI, first-party only

**Status**: Accepted
**Date**: 2026-04-23

## Context

Every mainstream VCS implementation — git itself, libgit2 bindings in every language, JGit, go-git — eventually reduces to calls into a C library (zlib for compression, OpenSSL/libsha for hashing, libgit2 or direct C for object storage). Re-using those C incumbents is the obvious path: they're battle-tested, fast, and free.

sit sits inside the AGNOS ecosystem, whose thesis is *sovereignty over the stack*: no opaque C blobs, no FFI surface, no toolchain dependencies outside Cyrius. Every layer is first-party Cyrius and measurable against its C incumbent. Accepting C deps in sit would poke a hole in that thesis for a tool that (per the goal statement) is explicitly *not* on the critical path — it's a convenience, not a load-bearing necessity.

## Decision

sit is built entirely from Cyrius stdlib and first-party Cyrius crates. No FFI, no C, no libgit2. Compression comes from [sankoch](https://github.com/MacCracken/sankoch), hashing/trust from [sigil](https://github.com/MacCracken/sigil), object storage from [patra](https://github.com/MacCracken/patra), logging from [sakshi](https://github.com/MacCracken/sakshi). All four are git-tag pinned in `cyrius.cyml`.

## Consequences

- **Positive**
  - No C toolchain on the build path. `cyrius build` is the only requirement.
  - No memory-safety surface from C; the whole binary is subject to Cyrius's guarantees.
  - Forces sankoch/sigil/patra to benchmark against their C incumbents. Every real user of those crates (sit is one) surfaces real perf gaps.
  - Clean packaging story for AGNOS: one Cyrius binary, no dynamic linker drama.
- **Negative**
  - We re-implement layers that already exist in hardened C. Early sit will be slower than git on equivalent operations until sankoch/sigil/patra mature.
  - We hit bugs in first-party crates first — sit is downstream of three active Cyrius projects and their release cadence.
  - Can't directly consume git's test suites or fuzzing corpora against libgit2.
- **Neutral**
  - sit's wire protocol will need its own first-party implementation (no smart-HTTP / ssh reuse). Scoped out for now.

## Alternatives considered

- **libgit2 via Cyrius FFI.** Gets us a functional sit in a weekend, but contradicts the AGNOS thesis and makes sit the project that punched the first FFI hole. Rejected.
- **zlib + OpenSSL only, everything else first-party.** Halfway position — C deps for the "hard" layers, Cyrius for storage and protocol. Still requires a C toolchain, still punches the FFI hole. Rejected on the same grounds as full libgit2.
- **Port git's C source to Cyrius.** Faster bootstrap than pure first-party, but yields Cyrius code shaped like git's C — and we're on the hook for git's architectural debt forever. Rejected; writing from the object-model up produces a better result even if it takes longer.
