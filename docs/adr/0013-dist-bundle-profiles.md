# 0013 — Two distribution bundle profiles: full and read-only

**Status**: Accepted
**Date**: 2026-10-19 (decided in 1.3.0, 2026-07-03; recorded here when the rationale moved out of `cyrius.cyml`)

## Context

Downstream Cyrius projects consume sit as a library through a concatenated bundle produced by `cyrius distlib` (public surface: [ADR 0009](0009-public-api-contract.md)). Consumers fall into two kinds.

- **Write / sync consumers** need commits, signing, fetch / push and the server: the whole surface.
- **Report-only consumers** need only to read a repo: branch, status and per-file diff. thoth's status bar and owl's gutter markers are the cases in hand. They never sign, write or touch the network.

A single full bundle forces the report-only kind to compile sit's signing module and its whole network stack. That brings dead-code references to stdlib globals that only the server path uses (sandhi's `HSV_REQ_BUF_SIZE`, TLS's `TLS_OK`) plus unresolved transport symbols. Consumers had to add shims and live with wire warnings for code they never run.

## Decision

**sit publishes two bundles, both tracked in-repo and both generated from `cyrius.cyml`:**

| profile | manifest table | command | output |
|---|---|---|---|
| full | `[lib]` | `cyrius distlib` | `dist/sit.cyr` + `dist/sit.deps` |
| read | `[lib.read]` | `cyrius distlib read` | `dist/sit-read.cyr` + `dist/sit-read.deps` |

Membership rules:

- **`[lib.read]` is `[lib]` minus `sign`, `wire`, `wire_http`, `serve`** (and minus `version`, `delta`, `history`, `blame`, `rebase`, which are not on the read path). It **keeps** `reflog`, `index`, `commit` and `merge`. Those are on the read path: status honours `.gitignore` and the index, reading HEAD parses its commit object into a tree, and ref resolution touches the reflog. Dropping them would silently break status / diff.
- **Module order is the same in both profiles** and mirrors `src/lib.cyr`: primitives → storage → refs / objects / commands → `api.cyr` last. (The order is logical grouping; the single-pass constraint once recorded in [architecture 005](../architecture/005-reflog-two-line-invariant.md) no longer holds — 1.6.4.)
- **Transport internals are in neither profile.** `wire_ssh.cyr` (exec of the system `ssh`) and `wire_https.cyr` (the TLS client handshake and TOFU pin store) stay out of consumer bundles. Code inside `[lib]` must therefore never *reach* them; see [architecture 006](../architecture/006-bundle-closure.md).
- **A source change to any module in `[lib]` regenerates `dist/sit.cyr`; a change to one also in `[lib.read]` regenerates both** (`cyrius distlib && cyrius distlib read`), in the same commit as the source.

## Consequences

- **Positive** — report-only consumers compile sit with no shims and no wire warnings, and carry no signing or network code.
- **Positive** — both profiles expose the same public API (`sit_repo_open` / `_branch` / `_status` / `_diff_path`, `ann_*`, `sit_status_*`), so a consumer can move between them without code changes.
- **Negative** — two bundles to keep in sync. CI's dist-sync step and the integration suite's library probe guard the full bundle.
- **Negative** — a few symbols are deliberately left unresolved in each bundle because they sit on paths the profile never executes. In the read bundle these are `load_signing_seed`, `sign_commit_body` and `verify_commit_body`, reachable only from commit's signing path. In the full bundle they are the SSH / HTTPS transport entry points. This is safe only while those paths stay unreachable from consumer code; the compiler refuses a reachable undefined call.
- **Neutral** — owl is a candidate to move onto the read profile alongside thoth.

## Alternatives considered

- **One full bundle only.** Rejected: it forces every report-only consumer to carry and shim the network and signing stack.
- **Per-module bundles that consumers compose.** Rejected for now: every consumer would have to assemble and keep a module set closed under reachability ([architecture 006](../architecture/006-bundle-closure.md)), and two profiles cover the consumers that exist.
