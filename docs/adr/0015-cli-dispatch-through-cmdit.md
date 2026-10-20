# 0015 — The top-level CLI is dispatched through cmdit

**Status**: Accepted
**Date**: 2026-10-19

## Context

sit had the most hand-rolled CLI of the AGNOS verb tools: `main.cyr` compared `argv(1)` against 35 command names, `print_usage` was a hand-written table beside it, and there was no `--help`, no `--version` and no shell completion. Every usage error exited 1. cmdit is the ecosystem's argument-parsing distlib (getopt-long core, verb dispatch, generated help, completions), and other tools already take it through a `[deps.cmdit]` block.

Three things made this a real choice rather than a default:
- **It is a dependency.** CLAUDE.md asks that every dependency earn its place, and ADR 0012 says the stdlib-folded modules are pinned only through the toolchain. cmdit is not folded, so it needs its own `[deps]` block.
- **The bundles must not see it.** Every `cmd_*` lives in a `[lib]` module that ships in `dist/sit.cyr` (and 22 of them in `dist/sit-read.cyr`). owl and thoth build those bundles on their own toolchain pins; a reachable call into cmdit from a bundled module would be an unresolved dependency in their builds (architecture 006).
- **The commands' own parsing is load-bearing.** Each `cmd_*` reads argv by position, CI and the integration suite pin their exact output, and `sit serve <repo> --stdio` is the remote command line every ssh client builds.

## Decision

`src/main.cyr` registers one cmdit verb per command (with `print_usage`'s descriptions) and calls `cmdit_dispatch`; on a match it calls the same `cmd_*()` as before, which still reads the rest of argv itself. cmdit is used **only in `main.cyr`**, which neither `[lib]` profile lists, so the bundles and their consumers are unchanged.

What this adds:
- `sit --help` / `-h`: the command table on stdout, exit 0 (also when a command follows, `sit --help status`).
- `sit --version` / `-V`: `sit <VERSION>`, from `sit_version_string()`.
- `sit completions <bash|zsh|fish>`: cmdit's completion script for the command table.

What it keeps, byte for byte:
- Everything after the command name reaches the command, flags included: cmdit hands any token after the verb that is not one of its own flags to the verb's scope, and sit has no global flags, so `sit status --version` is `status` with an argument, as it was.
- A usage error — an unknown command, an unknown option before the command, no command — prints "sit: unknown command" (or, with no arguments, just the table) to stderr and exits 1. cmdit's own error text and exit code 2 are not used.
- A `--` before the command is a usage error, because cmdit would consume it and shift every `argv(n)` the handler reads; main checks the matched command is `argv(1)`.

Per-command parsing through cmdit (each `cmd_*` on its own cmdit handle) is not part of this decision; it stays on the roadmap as optional work.

The dependency is a `[deps.cmdit]` git block pinned to a tag (`dist/cmdit.cyr`).

## Consequences

- **Positive** — one command table drives dispatch and completions; `--help`, `--version` and completions exist; an integration test (section 38f) fails if the usage table and the completion verbs list different commands.
- **Negative** — a second-party dependency outside the toolchain pin: its tag is bumped by hand, and `cyrius deps` fetches it. Startup costs about 0.05–0.08 ms more per invocation (DCE build, CPU time: `status` 1.18 → 1.26 ms, `cat-file` 0.75 → 0.80 ms). The usage table is still hand-written text beside the verb table (cmdit's generated help has no synopsis column), kept in step by the drift test rather than by construction.
- **Neutral** — `cyrius distlib` attributes the stdlib leaves cmdit brings (`args`, `alloc`, `string`, `io`, and with them `vec` / `result`) to cmdit, so the bundles' compile-verified requires block no longer lists them. The bundles' consumers compile them against their own stdlib lists, which carry those leaves (owl at cyrius 6.6.2 and thoth at 6.6.6 build unchanged; owl's tests pass); a consumer that relied on the requires block alone would add them to its `[deps] stdlib`.
- **Neutral** — per-command parsing can move onto cmdit later without touching this boundary, as long as the calls stay in `main.cyr` / a `src/cli.cyr` outside both `[lib]` profiles. `-U<N>` (attached short value) is the one flag cmdit cannot parse today; cmdit's roadmap records sit's demand for it.

## Alternatives considered

- **Keep hand-rolling, add `--help` / `--version` by hand.** Cheapest, no dependency — but it adds a third hand-maintained list (help, dispatch, completions) instead of removing one, and completion scripts written by hand drift fastest of all.
- **The stdlib `flags` module.** It has no verbs and no completions; cmdit is that module productized for exactly this.
- **Full per-command parsing in one step.** It changes how 35 commands read their arguments at once (dash-leading paths and messages would need `--`, ignored arguments would become errors), against the CLI's byte-identical contract. Deferred until there is a reason to take that on.
