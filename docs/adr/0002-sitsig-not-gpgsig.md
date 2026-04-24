# 0002 — Signed commits use a `sitsig` header, not `gpgsig`

**Status**: Accepted
**Date**: 2026-04-24

## Context

Git signs commits with a `gpgsig` header holding an ASCII-armored OpenPGP signature — multi-line, base64-encoded, produced by shelling out to `gpg` (or compatible) and folded per git's header-continuation rules. The format works, but it pulls in a lot of surface that sit doesn't have and shouldn't acquire:

- OpenPGP armor (`-----BEGIN PGP SIGNATURE-----`, base64 groups, CRC24 checksum) is a format in its own right.
- GPG assumes an external keyring, agent, trust-store, and user interaction model — none of which sit has or wants.
- RSA/DSA/EdDSA-over-OpenPGP all live inside that same envelope; choosing any subset ties us to a crypto profile we don't own.

Sit already ships [sigil](https://github.com/MacCracken/sigil), which exposes ed25519 `sign_data` / `verify_data` / `generate_keypair` as first-party primitives — no GPG, no armor, no keyring. Using sigil directly is the AGNOS-consistent move; the only open question is the *on-wire* shape inside the commit body.

## Decision

Signed sit commits carry a single-line `sitsig` header, placed where git would place `gpgsig`:

```
tree <hex>
parent <hex>
author ... <ts> +0000
committer ... <ts> +0000
sitsig <128-hex-sig> <64-hex-pubkey>
<blank>
<message>
```

- The signature is a raw 64-byte ed25519 signature, hex-encoded (128 chars).
- The pubkey is the signer's raw 32-byte ed25519 public key, hex-encoded (64 chars).
- The signed payload is the *unsigned* commit body — i.e. everything the commit would contain if `-S` had not been passed. Verification re-parses the body, strips the `sitsig` line, and calls `ed25519_verify(pub, stripped_body, sig)`. Same self-consistency trick git uses for `gpgsig`.

Key material lives in `~/.sit/signing_key` (32-byte seed, hex-encoded, chmod 0600) and `~/.sit/signing_key.pub` (32-byte pubkey, hex-encoded, 0644). `sit key generate` creates the pair; `sit commit -S` reads the seed on demand.

## Consequences

- **Positive**
  - No GPG dependency in the build graph, runtime, or documentation. `sit key generate` is a single-command onboarding.
  - Verification is cheap: strip one line, one `ed25519_verify` call. No armor parsing, no CRC24.
  - Header name makes the divergence from git obvious in `cat-file` output — no reader will mistake a sitsig for a gpgsig and try to feed it to `gpg --verify`.
  - Fixed-width line (201 bytes: `sitsig ` + 128-hex sig + space + 64-hex pub + `\n`) means no folding logic, no continuation-line state machine.
- **Negative**
  - A git clone of a sit repo would see `sitsig` and reject it as an unknown header. Sit is intentionally not git-wire-compatible (see ADR 0001 and the v0.5.0 HTTP-transport plan), so this is aligned with project scope rather than a regression — but it does mean that dual-hosted repos (if that ever becomes a pattern) couldn't carry sit signatures inside git's view.
  - Only ed25519 is supported. RSA/ECDSA/mldsa-hybrid signers aren't on the roadmap; if they become necessary, a new `sitsig2` header can be introduced alongside (never renumber).
- **Neutral**
  - The pubkey is embedded in every signed commit. That makes verification self-contained but adds ~75 bytes per commit (on top of the 128-hex sig). For a VCS this is in the noise; for streaming wire protocols later, pack-format compression will eat most of it.
  - `~/.sit/signing_key` is not a full keyring — just a single default signer. Multi-key setups, `commit.signingkey = <fingerprint>` config, and key rotation are v0.5.x-plus concerns.

## Alternatives considered

- **`gpgsig` with OpenPGP armor.** Maximum compatibility with existing git-aware tooling, but pulls GPG into the build and runtime surface. Rejected — see ADR 0001.
- **SSH-style signature blocks (`ssh-ed25519 AAAA...` base64).** Compact and familiar, but base64 inside a commit header still needs folding, and adopting the SSH format without the rest of the SSH signing protocol (`signed-data`, namespace, hash algorithm ID) would be half-doing it. Rejected.
- **Out-of-band signatures (`.sit/signatures/<hex>.sig`).** Keeps the commit object clean but breaks self-consistency — a detached signature can be lost, tampered with, or lie about what it covers. Rejected; inline is the only form that gives `sit verify-commit` a trustworthy single-object check.
- **Sigil hybrid sigs (ed25519 + ML-DSA-65).** Sigil ships `sigil_verify_hybrid` for a PQ-hardened profile. Overkill for sit at v0.4.0; revisit when sigil promotes hybrid as the default.
