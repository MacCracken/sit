# Security Policy

## Supported versions

sit follows SemVer. Security fixes land on the latest released minor; once `1.0.0` ships, the most recent `1.x` is the supported line. Pre-1.0 releases are not separately patched — upgrade to the latest tag.

## Reporting a vulnerability

**Do not open a public issue for a security report.** Email **robert.maccracken@gmail.com** with:

- a description of the issue and its impact,
- the version / commit (`VERSION` + `git rev-parse HEAD`),
- reproduction steps or a proof-of-concept, and
- any suggested remediation.

You'll get an acknowledgement within a few days. Coordinated disclosure is preferred: please give a reasonable window to ship a fix before publishing. Credit is offered in the `CHANGELOG.md` **Security** section unless you ask otherwise.

## Threat model

sit is a version-control tool, so it routinely handles **untrusted data**: cloned objects, remote refs, commit/tree bodies, `.sitignore` patterns, and remote URLs all originate outside the local trust boundary. The areas that get the most scrutiny:

- **Object & wire parsing** — commit/tree body parsing, hex decoding, ref-name sanitization, the `/sit/v1/...` frame decoders. Every parser path is fuzzed ([`tests/sit.fcyr`](tests/sit.fcyr)).
- **Path traversal** — tree entry names, index paths, `.sitignore` patterns, and clone targets are validated; `sit clone` refuses an absolute target without `--force-absolute` (see [ADR 0005 — local-clone threat model](docs/adr/0005-local-clone-threat-model.md)).
- **No upward repo discovery** — sit never walks parent directories to find a `.sit/` (CVE-2022-24765 shape; [ADR 0003](docs/adr/0003-no-upward-repo-discovery.md)).
- **Transport** — `https://` rides first-party Cyrius TLS 1.3 with TOFU/pinned trust (**no libssl**, [ADR 0007](docs/adr/0007-network-transport-security.md)); `ssh://` reuses the system `ssh` binary as a process boundary, not an FFI dependency ([ADR 0008](docs/adr/0008-ssh-transport.md)), with CVE-2017-1000117-shape leading-dash rejection. Plain `http://` is loopback / private-network / behind-tunnel only.
- **Trust boundary on push** — a server rehashes every uploaded object (sigil SHA-256 over the full framed body) before insert and refuses on hex mismatch.
- **First-party only, no FFI** — every layer (compression, hashing, storage, signing, TLS) is reimplemented in Cyrius rather than binding libgit2 / OpenSSL / zlib, removing that entire class of dependency-CVE exposure ([ADR 0001](docs/adr/0001-no-ffi-first-party-only.md)).

## Audit history

Per-release security audits are recorded under [`docs/audit/`](docs/audit/). The most recent is the v0.9.0 closeout, [`docs/audit/2026-06-13-audit.md`](docs/audit/2026-06-13-audit.md).
