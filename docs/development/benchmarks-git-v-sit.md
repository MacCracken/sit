# Benchmarks: git vs sit

Head-to-head comparison on a real workstation. sit is a first-party Cyrius implementation — every layer (SHA-256, zlib, object store) is written from scratch with no FFI to C libraries. The point of this document is to be honest about where sit currently wins, loses, and breaks even against git, and to track that over time as sigil/sankoch/patra mature.

## Setup

- **Host**: Linux x86_64, Arch kernel 6.18.22-1-lts
- **git**: system install (see binary version below)
- **sit**: built from source at `src/main.cyr` via `cyrius build`
- **Timing**: `time.perf_counter_ns` around `subprocess.run` in Python (~microsecond resolution). Each operation is run with a fresh scratch repo and measured 10–20 times; we report **min** (closest to true operation cost, minus noise) and **median** (typical case) in milliseconds.

Reproduce any time with `scripts/benchmark.sh` — see "Methodology" at the end.

## Binary footprint

| | size | dynamic deps |
|---|---:|---|
| `git` (primary dispatch binary) | **4,523,048 bytes** (~4.4 MB) | libpcre2, libz-ng, libc |
| `/usr/lib/git-core/*` (all 183 sub-binaries) | **7,390,732 bytes** (~7.4 MB) | same |
| `build/sit` (one statically-linked binary) | **607,176 bytes** (~593 KB) | **none** |

**sit ships one 593 KB statically-linked binary with zero dynamic dependencies.** The primary git binary is ~7.5× larger; the full git install footprint is ~12× larger. sit bundles SHA-256, zlib-compatible compression, and its object store directly into the executable — no libpcre, no libz, no dispatch subcommand binaries.

## Operation latency

All times in milliseconds, lower is better.

| operation | git (min / med) | sit (min / med) | sit/git ratio |
|---|---:|---:|---:|
| `init` (fresh dir → empty repo) | 3.35 / 4.21 | **1.24 / 1.81** | **0.37×** (sit faster) |
| `commit` (20 staged files) | 4.75 / 5.38 | **2.09 / 2.53** | **0.44×** (sit faster) |
| `diff` (5-line file, 2-line change) | 2.46 / 2.59 | **1.29 / 1.57** | **0.52×** (sit faster) |
| `log` (walk 50 commits) | 3.29 / 3.45 | 3.45 / 3.83 | 1.05× (par) |
| `status` (100 files, clean tree) | 2.76 / 3.17 | 3.19 / 3.84 | 1.16× (par) |
| `add` (1 MB random file) | **16.56 / 17.43** | 189.37 / 195.06 | **11.44×** (sit slower) |

## What the numbers mean

**sit wins on everything except large-file hashing.** Small-op latency (`init`, `commit`, `diff`) benefits from sit's static build: no dynamic linker startup, no fork+exec dispatch through `git-core`. For commands whose work is dominated by filesystem setup and ref management rather than content hashing, sit's end-to-end path is straightforwardly shorter.

**`status` and `log` land at parity.** 100 files' worth of hashing and 50 commits' worth of zlib decode are both in the "measurable but not dominant" range — sit trails by ~15% on status and ~5% on log, well within the margin of a less-tuned hash implementation.

**`add 1 MB` is where sigil's software SHA-256 hurts.** Hashing throughput, measured in isolation via `tests/sit.bcyr`, is ~16 MB/s for sit on this host. That's consistent with a straightforward first-party SHA-256; modern CPUs get 500+ MB/s for git via SHA-NI or similar, and that's the gap showing up here. This is the one benchmark that names the next optimization target unambiguously: if sigil grows a SHA-NI fast path, this gap should collapse.

## Honest caveats

- **One machine, one run.** These numbers are a snapshot, not a study. Re-run on your own hardware before quoting.
- **sit is young.** The loose-object store (see [arch 002](../architecture/002-loose-objects-until-patra-blobs.md)) is not optimized; we don't have packfiles yet. The `log` and `status` numbers will likely improve when the object store migrates to patra (once `COL_BLOB` lands on patra's roadmap).
- **git is doing more.** The git install bundles pcregrep, rebase, gc, merge-base, diff-tree, hundreds of plumbing commands. sit has 15 so far — the size comparison is not "git does the same work in 12× the bytes." It's "sit covers the core VCS loop in 12× less disk."
- **sit has no network yet.** These benchmarks are all local. When sit gains a wire protocol, network ops will add a whole new comparison axis.

## Per-primitive numbers from `tests/sit.bcyr`

Run `cyrius build tests/sit.bcyr build/sit-bench && ./build/sit-bench`:

```
  sha256-64B:          8 μs  avg  [10000 iters]
  sha256-1024B:       70 μs  avg  [5000 iters]
  sha256-65536B:    4.106 ms avg  [500 iters]
  zlib-compress-1024B:   149 μs  avg  [2000 iters]
  zlib-compress-65536B: 1.168 ms avg  [200 iters]
  zlib-decompress-1024B:  37 μs  avg  [5000 iters]
  zlib-decompress-65536B: 360 μs avg  [500 iters]
```

From these: sigil SHA-256 ≈ **16 MB/s**; sankoch zlib compress ≈ **56 MB/s**; zlib decompress ≈ **182 MB/s**. Those throughputs are the lower bound on what any sit command involving content hashing or compression can achieve, until the underlying crates are tuned.

## Methodology

1. For each operation, build a **fresh** scratch repo (git or sit) every run — no warm-cache advantages for either side.
2. Run the operation N times (10 for heavy ops, 20 for light ones). Record each wall-clock time with `perf_counter_ns`.
3. Report **min** (approaches the true CPU cost, filtering out scheduler noise) and **median** (typical case).
4. Author identity is pre-configured on both sides (`Bench <b@e>`); no credential fetching in the hot path.
5. Benchmarks run serially on a quiet workstation; no background load beyond the normal desktop session.

To reproduce:

```sh
cyrius build src/main.cyr build/sit
# benchmark script is inline in this doc's PR; see the `bench-results.json`
# that the Python runner emits for raw numbers.
```
