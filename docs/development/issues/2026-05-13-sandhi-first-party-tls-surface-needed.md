# sandhi — First-party Cyrius TLS surface needed for sit's HTTPS / mTLS slots

**Discovered:** 2026-05-13 during sit v0.8.4 prep
**Severity:** High — blocks sit's v0.8.4 (HTTPS) and v0.8.5 (mTLS) roadmap slots; sit has no path to encrypted-over-internet read/write other than SSH while this stands.
**Affects:** sandhi 1.3.4 (and the cyrius-vendored copy at `lib/sandhi.cyr`), cyrius 5.11.34 (`lib/tls.cyr` is the underlying libssl-via-fdlopen shim)

## Summary

Sit's v0.8.4 roadmap slot is **HTTPS via sandhi first-party Cyrius TLS** (client + server). Per [ADR 0007](../../adr/0007-network-transport-security.md), the gate to ship is: *the underlying TLS implementation must be first-party Cyrius — not libssl-via-fdlopen, not libssh-via-fdlopen, not any C-bound shim.* That decision is load-bearing for sit's no-FFI thesis ([ADR 0001](../../adr/0001-no-ffi-first-party-only.md)); it's exactly why sit invested in SSH (ADR 0008, v0.8.2 / v0.8.3) as the encrypted-over-internet path.

Today the sandhi `tls_policy` surface (which sit would consume) wraps stdlib `lib/tls.cyr`, which is libssl-via-fdlopen. So consuming sandhi's TLS in sit means linking libssl — exactly what ADR 0007 forbids.

Without sandhi growing a first-party Cyrius TLS implementation (or cyrius `lib/tls.cyr` being replaced with a pure-Cyrius one), sit cannot ship v0.8.4 / v0.8.5 without breaking its own architectural rules.

## Reproduction

Verified during sit's v0.8.4 prep on 2026-05-13:

```sh
# 1. Sandhi's tls_policy/mod.cyr header explicitly says it's libssl-bridged:
grep -A2 "FFI-to-libssl" /home/macro/Repos/sandhi/src/tls_policy/mod.cyr
# → "Today this wraps stdlib `lib/tls.cyr` (which is FFI-to-libssl)."

# 2. Sandhi's apply.cyr directly calls libssl symbols via the fdlopen bridge:
grep -E "tls_dlsym\(\"SSL_" /home/macro/Repos/sandhi/src/tls_policy/apply.cyr
# → tls_dlsym("SSL_CTX_load_verify_locations")
# → tls_dlsym("SSL_CTX_use_certificate_file")
# → tls_dlsym("SSL_CTX_use_PrivateKey_file")
# → tls_dlsym("SSL_get1_peer_certificate")

# 3. Sandhi v1.2.0 release notes confirm the direction:
grep "libssl.so.3-bridged" /home/macro/Repos/sandhi/docs/development/state.md
# → "lib/tls.cyr stays libssl.so.3-bridged ... per the 2026-04-24 pure-Cyrius-TLS removal"

# 4. Cyrius lib/tls.cyr header:
head -15 ~/.cyrius/versions/5.11.34/lib/tls.cyr
# → "TLS client via libssl.so.3 (fdlopen bridge)"
```

## Root cause (if known)

The 2026-04-24 cyrius-side decision to remove the pure-Cyrius-TLS plan from the roadmap was made before sit reached the slot that needs HTTPS. The reasoning at the time (per sandhi's release notes): *"sandhi composes, doesn't reimplement"* — TLS work belongs on the cyrius side, against `lib/tls.cyr`, not in sandhi.

At cyrius level there's no active arc to replace `lib/tls.cyr`'s libssl bridge with a first-party implementation. The v5.9.x → v5.10.x optimization arc and the v5.11.x ELF / cap fixes both bypass the TLS surface entirely.

## Proposed fix

Either:

1. **Cyrius `lib/tls.cyr` becomes first-party Cyrius.** Replaces the libssl-via-fdlopen bridge with a pure-Cyrius TLS 1.2+/1.3 client (and server, for sit serve's HTTPS path). Sigil already has SHA-256 / ed25519; needs ECDH (P-256 / X25519), AES-GCM / ChaCha20-Poly1305, X.509 cert parsing + chain verify, ALPN, SNI. Significant effort but unblocks every AGNOS consumer that's holding off encrypted transport for the same ADR 0001 reason.

2. **Sandhi grows a parallel first-party TLS surface** alongside the existing libssl-bridged `tls_policy`. New `sandhi_tls_native_*` verbs that consumers can opt into; legacy `sandhi_tls_*` (libssl) stays for compatibility. Same total work as option 1 minus the cyrius coordination cost, but the implementation belongs in cyrius per the 1.2.0 release-notes framing.

3. **Punt — accept that HTTPS over libssl is the only realistic path.** Would require sit amending ADR 0007 to permit libssl-via-fdlopen as a deliberate exception. Not the right answer (the user invested heavily in SSH precisely to honor ADR 0001 + 0007), but worth naming so the alternatives are clear.

Preference: option 1. Sandhi already factored its policy layer (`tls_policy/`) cleanly above the transport — when cyrius `lib/tls.cyr` swaps under it, sandhi's surface is unchanged (sandhi's own v1.2.0 framing: *"When Cyrius v5.9.x native TLS lands, the surface here does not change — only the transport underneath apply.cyr swaps out."*). The work belongs at the cyrius level.

## Consumer-side workaround (if any)

**SSH remains sit's encrypted-over-internet path** (ADR 0008; v0.8.2 read, v0.8.3 push). Users wanting HTTPS-shape URLs can put sit behind an HTTPS-terminating reverse proxy (nginx / caddy) that talks loopback HTTP to `sit serve`. The hop from client to proxy is encrypted by the proxy; the hop from proxy to sit is loopback and per ADR 0007 doesn't need TLS.

This isn't a satisfying answer for users who want a single sit binary to handle TLS termination, but it's a valid deployment shape that doesn't punch ADR 0001 / 0007.

## Sit roadmap impact

- v0.8.4 (HTTPS) and v0.8.5 (mTLS) slots are blocked on this gate.
- v0.8.x line continues with hardening sweep (`denyCurrentBranch`, `sit fsck` reachability, full `.sitignore`, `log --graph`, shallow clone) — none of which need TLS.
- When sandhi or cyrius ships the first-party TLS surface, sit's `URL_SCHEME_HTTPS` validator + `wire_transport_check_*` dispatch already exist (v0.7.1 scaffolding); the wire-up is a v0.8.x patch at that point, not a multi-release arc.
