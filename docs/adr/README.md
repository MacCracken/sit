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
