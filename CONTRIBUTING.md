# Contributing to sit

sit is **sovereign version control** — a Cyrius-native git replacement with no libgit2, no C, and no FFI. Contributions are welcome; the bar is correctness and the no-FFI thesis.

## Ground rules

- **First-party only, no FFI.** Every layer is reimplemented in Cyrius and benchmarked against its C incumbent. A change that links libgit2 / OpenSSL / zlib / libssh — directly or transitively — won't be accepted ([ADR 0001](docs/adr/0001-no-ffi-first-party-only.md)).
- **Correctness is the optimum sovereignty.** If it's wrong, you don't own it. Test after every change, not after the feature is "done".
- **One change at a time.** Don't bundle unrelated changes.
- **Read [`CLAUDE.md`](CLAUDE.md) first** — it is the canonical process, conventions, and hard constraints (the Cyrius gotchas list there will save you real time).

## Building and testing

```sh
cyrius build src/main.cyr build/sit       # build
cyrius test tests/sit.tcyr                # unit tests
cyrius run  tests/sit.fcyr                # fuzz harnesses
cyrius bench tests/sit.bcyr               # benchmarks
cyrius lint src/*.cyr                     # static checks
SIT=build/sit tests/integration/run.sh    # end-to-end integration suite
```

Every change must pass the same gates as the existing code:

- **Tests green** — `tests/sit.tcyr` (unit) and `tests/integration/run.sh` (end-to-end). Add coverage for new behavior.
- **Fuzz every parser path** — anything that consumes external data (object bodies, hex, URLs, wire frames) gets a harness in `tests/sit.fcyr`. Edge cases get invariants, not assertions.
- **Benchmark before claiming perf** — numbers in `tests/sit.bcyr` + a snapshot under `docs/benchmarks/`, or it didn't happen.
- **Lint clean** — `cyrius lint`; the only tolerated warning is the 120-char rule on comment/divider lines.
- **dist in sync** — if you touch a module listed in `cyrius.cyml [lib].modules`, run `cyrius distlib` and commit the regenerated `dist/sit.cyr` in the same commit (CI hard-fails otherwise).

## Coding conventions

Cyrius has sharp edges. The full list is in [`CLAUDE.md` § Cyrius Conventions](CLAUDE.md); the ones that bite most often:

- `var buf[N]` is **N bytes**, not N entries. Every buffer declaration is a contract.
- No `break` in a `while` loop that declares `var` — use a flag + `continue`.
- No negative literals (`(0 - N)`, not `-N`); no mixed `&&`/`||` in one expression (nest `if`s).
- All struct fields are 8 bytes via `load64`/`store64` at an offset.
- Never build SQL from unvalidated bytes — validate hex/paths first.

Study a working program before writing new code (`yukti/src/main.cyr`, `patra/programs/demo.cyr`), and skim [`docs/architecture/`](docs/architecture/) for non-obvious invariants you can't derive from the source.

## Documentation

- **Decisions** → an ADR in [`docs/adr/`](docs/adr/) (use [`template.md`](docs/adr/template.md); never renumber).
- **Non-obvious constraints/quirks** → a numbered item in [`docs/architecture/`](docs/architecture/).
- **How-tos** → [`docs/guides/`](docs/guides/); **runnable examples** → [`docs/examples/`](docs/examples/).
- **Changelog** → follow [Keep a Changelog](https://keepachangelog.com/); performance claims need numbers, breaking changes need a migration note, security fixes get a **Security** section.

## Cross-project requests

sit depends on first-party crates (sakshi, sankoch, sigil, patra) and the Cyrius toolchain. **These repos don't use the GitHub issue tracker.** If sit needs something from a dependency, draft a backlog entry on *that repo's* `docs/development/roadmap.md` rather than filing an issue.

## Commits & PRs

The maintainer handles tagging and releases. Keep commits focused, message the *why*, and make sure the working tree is green (`cyrius lint` + tests + dist-sync) before you push. Security-sensitive reports go through [`SECURITY.md`](SECURITY.md), not a public PR.

## Conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
