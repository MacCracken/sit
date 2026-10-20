# Architecture Decision Records

Decisions about sit — what we chose, the context, and the consequences we accept. Use these when a future reader would reasonably ask *"why did we do it this way?"*

## Conventions

- **Filename**: `NNNN-kebab-case-title.md`, zero-padded to four digits. Never renumber.
- **One decision per ADR.** If a decision supersedes a prior one, add a new ADR and set the old one's status to `Superseded by NNNN`.
- **Status lifecycle**: `Proposed` → `Accepted` → (optionally) `Superseded` or `Deprecated`.
- Use [`template.md`](template.md) as the starting point.

## ADR vs. architecture note vs. guide

| Kind | Lives in | Answers |
|---|---|---|
| ADR | `docs/adr/` | *Why did we choose X over Y?* |
| Architecture note | `docs/architecture/` | *What non-obvious constraint is true about the code?* |
| Guide | `docs/guides/` | *How do I do X?* |

## Index

- [0001 — No FFI, first-party only](0001-no-ffi-first-party-only.md) — sit reimplements every layer in Cyrius rather than binding to libgit2/zlib/OpenSSL.
- [0002 — Signed commits use a `sitsig` header, not `gpgsig`](0002-sitsig-not-gpgsig.md) — why sit signs with raw ed25519 via sigil instead of OpenPGP-armored signatures via GPG.
- [0003 — sit does not search upward for `.sit/`](0003-no-upward-repo-discovery.md) — CVE-2022-24765 is structurally impossible.
- [0004 — sit is SHA-256 only](0004-sha256-only.md) — no SHA-1 interop, ever. Immune to Shattered-class attacks.
- [0005 — Local-clone threat model](0005-local-clone-threat-model.md) — what sit does and doesn't trust in a malicious remote, and which validator enforces which boundary.
- [0006 — Batched-want frame format](0006-batched-want-frame-format.md) — wire shape for `POST /sit/v1/want` (request: `[count][hashes…]`; response: per-frame `[hex][ty][clen][compressed]`); fallback to per-object GET when server doesn't advertise `"batch":true`.
- [0007 — Network transport security: SSH or first-party only](0007-network-transport-security.md) — no libssl, no libcrypto, no exception. HTTPS waits for first-party Cyrius TLS to exist. Until then: HTTP is loopback / private-network / behind-tunnel; SSH (v0.7.8) is the canonical encrypted-over-internet transport; bearer auth gates loopback deployments without claiming security it doesn't deliver.
- [0008 — SSH transport: process boundary, not FFI](0008-ssh-transport.md) — sit execs the system `ssh` client rather than linking an SSH library, keeping the no-FFI thesis intact.
- [0009 — Public API contract](0009-public-api-contract.md) — `sit_*` / `ann_*` are the stable surface; everything else is internal and may change without notice.
- [0010 — Reflog and recovery](0010-reflog-and-recovery.md) — file-based, git-compatible `.sit/logs/` journal; `@{N}` ordinal selection; reflog-as-roots + age-window `fsck --prune` grace. Why flat files over a patra table, and why `--prune` now means "grace."
- [0011 — Read-only `.git/` repository support](0011-git-read-mode.md) — sit reads existing git repos (SHA-1 loose+pack+refs) read-only behind the same public API via a storage seam; no FFI, a self-written delta interpreter, and no SHA-1 computation. Scopes the read-only exception to [0004](0004-sha256-only.md)'s SHA-256-only stance.
- [0012 — First-party dependencies are pinned through the toolchain](0012-deps-pinned-through-the-toolchain.md) — sakshi / sankoch / sigil / patra / sandhi are `[deps].stdlib` leaves selected by the `cyrius` pin; never `[deps.<name>]` git blocks, which silently downgrade consumers and drop the module from the bundle sidecar.
- [0013 — Two distribution bundle profiles](0013-dist-bundle-profiles.md) — `dist/sit.cyr` (full, `[lib]`) and `dist/sit-read.cyr` (read-only, `[lib.read]`): what each carries, why the read profile keeps reflog / index / commit / merge, and why transport internals are in neither.
- [0014 — Bearer tokens are bound to remotes](0014-bearer-tokens-bound-to-remotes.md) — a token goes only to a remote named by `remote.<name>.tokenFile`; unbound loopback remotes get `~/.sit/serve.token`; nothing else gets one, and never over plain http off-host (1.7.0, audit C3).
- [0015 — The top-level CLI is dispatched through cmdit](0015-cli-dispatch-through-cmdit.md) — one cmdit verb per command in `main.cyr` only (outside both `[lib]` profiles); adds `--help` / `--version` / `completions`; every argument after the command still reaches it unchanged (1.9.0).
- [0016 — Reachable history is stored in git-format packs, written by `sit gc`](0016-packs-for-storage.md) — `.sit/packs/` in git's SHA-256 pack v2 / idx v2 (git rebuilds sit's `.idx` byte for byte), OFS_DELTA against the newer version at each path; rows are the loose objects; no schema change; the wire carries whole objects (1.10.0). Supersedes the roadmap's delta-column plan.
