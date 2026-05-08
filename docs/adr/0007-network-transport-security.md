# 0007 — Network transport security: SSH or first-party only

**Status**: Accepted
**Date**: 2026-05-08

## Context

The v0.7.x line lights up sit's network transport. v0.7.2 / v0.7.3 / v0.7.4 / v0.7.5 closed the read-only round trip over plain HTTP (`sit clone http://...` works end-to-end with batched fetch). The next bite is push — `POST /sit/v1/objects` + `POST /sit/v1/refs` — and the obvious first question is "should pushed data be encrypted in transit?"

The conventional answer for any application protocol in 2026 is HTTPS. The conventional path to HTTPS is to bind libssl/libcrypto. Every existing language stack does this — git itself, libgit2 in any language, JGit, go-git, every HTTP client.

**That path is closed for sit by [ADR 0001](0001-no-ffi-first-party-only.md).** No FFI, no C, no binding to OpenSSL/libcrypto/libsha. Cyrius's stdlib does ship a `lib/tls.cyr` that loads libssl.so.3 at runtime via fdlopen — but importing it into sit's call graph would punch the same FFI hole ADR 0001 explicitly forbids. The fact that the dlopen is dynamic rather than static doesn't matter: the binary depends on a C library, the C library brings its own memory-safety surface, and sit's no-C thesis is over.

This ADR settles where transport-layer security comes from in sit, on the assumption that no first-party Cyrius TLS exists today and won't until someone writes one.

## Decision

**HTTPS will not ship in sit until a first-party Cyrius TLS implementation exists.** Period. No libssl. No libcrypto. No fdlopen-bridged dlopen of either. No "exception ADR" justifying a binding.

Consequently, sit's network transport story for v0.7.x is:

1. **HTTP is loopback / private-network / behind-tunnel.** `sit serve` already parse-locks `--listen` to `127.0.0.1:<port>`. Bearer auth (`~/.sit/serve.token`, 0600 perms) protects loopback deployments from local-process snooping. **Operators putting `sit serve` on a public interface MUST tunnel** — VPN, WireGuard, SSH port-forward, kubernetes service mesh, or similar. Sit never offers a "just expose port 8484" mode. The capability response declares this posture so clients can refuse non-loopback HTTP without auth.
2. **SSH is the canonical over-internet transport (v0.7.8).** sit reuses the system SSH binary the same way git does (`ssh user@host -- sit serve --stdio`); the SSH process owns the encryption + authentication, sit's wire travels over its stdin/stdout. **No crypto in sit's address space, no library link.** This is the only encrypted transport sit ships with the no-FFI thesis intact.
3. **First-party Cyrius TLS is the only path that unlocks HTTPS later.** If/when sigil grows a TLS layer, or a separate Cyrius TLS crate appears, sit can add `https://` support. Until then, HTTPS is not on the roadmap. Don't file it as a "blocked on TLS" ticket; file it as "blocked on first-party Cyrius TLS *existing*."

## Consequences

### Positive

- **No-C thesis preserved end-to-end.** Sit's binary genuinely owns its address space. `ldd build/sit` reports `not a dynamic executable`. `lsof` on the running process never opens libssl.so. Memory safety is Cyrius's guarantee from main entry to network egress.
- **Deployment guidance is clear, not aspirational.** "HTTP loopback or SSH" is one sentence. Compare to the OpenSSL approach where every deploy needs to think about cert provisioning, rotation, CRLs, OCSP, ALPN, SNI, TLS-version pinning, and a dozen other concerns whose first failure mode is "fall back to no TLS." Sit just has one path.
- **The no-FFI thesis stays a thesis, not a goal.** Punching the FFI hole "just for TLS" is exactly the path ADR 0001 names as the slippery slope ("zlib + OpenSSL only, everything else first-party"). Holding the line on TLS keeps the thesis credible for the rest of the stack.
- **SSH is a battle-tested security boundary.** Operators already trust `ssh` with code-deploy traffic. Reusing it as sit's encrypted transport inherits decades of crypto review without sit owning any of it.

### Negative

- **No drop-in replacement for `git clone https://github.com/...`.** Sit's HTTP clone works only against `sit serve` instances on networks the operator has already secured. There is no "anyone can `sit clone` over public internet without ceremony" mode until first-party Cyrius TLS exists. Users moving from git will hit this immediately and need to either tunnel or use SSH.
- **CI / hosted-sit deployments are SSH-shaped.** A "sit hosting" service (someone wants the github-of-sit) ships SSH-only. That's a known constraint; matches git's pre-smart-HTTP era and most Mercurial/Fossil deployments today. Acceptable.
- **Bearer auth without TLS is local-process-snoop defense only.** A user with read access to packets on the wire (privileged loopback observer, namespace peer, attached debugger) can lift the token. The `~/.sit/serve.token` posture is not a substitute for TLS; it's a "you can't accidentally curl without a token" gate. Documented as such.

### Neutral

- **First-party Cyrius TLS is a multi-year effort, not a v0.7.x line item.** If it ever lands, sit's `wire_http.cyr` will grow an `https://` branch with the same `_wire_http_post` shape it already has. The wire-protocol layer is TLS-orthogonal; ADR 0006's frame format ships unchanged over plain HTTP, HTTPS, or SSH.
- **The `URL_SCHEME_HTTPS` constant + `https://` validator in `validate.cyr` stay** — they're cheap, future-proof, and reject malformed HTTPS URLs at remote-add time. `wire_transport_check_readable` / `_writable` keep their `"https transport requires sit X.Y+"` errors with `X.Y` left as `(when first-party TLS lands)` rather than a specific minor.

## Alternatives considered

- **Bind libssl via fdlopen.** Pragmatic, fast to ship, gets HTTPS in a v0.7.6 patch. Rejected: it punches the FFI hole ADR 0001 explicitly forbids. The "fdlopen makes it OK because it's dynamic" argument fails — the binary still depends on a C library, the C library still owns its own memory model, and sit's whole reason to exist is "no opaque C blobs in the trust path." If the project is willing to bind libssl, the project is willing to bind libgit2, and we're back to a thin Cyrius wrapper around git's C — at which point we should just use git.
- **A "TLS exception" ADR documenting libssl as the one allowed C dep.** Same critique. ADR 0001 doesn't list crypto as the special case; it lists *no* C deps. Carving out an exception establishes the pattern for the next "we really need this" library, and the pattern keeps growing until sit is libgit2-shaped.
- **Port a TLS implementation to Cyrius.** Best long-term path. ~80 KLOC of crypto + ASN.1 + cert chain validation + cipher suites + protocol versions. Not a v0.7.x scope; not even a v0.x scope.
- **Skip TLS, rely on application-layer encryption (sigil ed25519 of payloads).** Considered for object integrity (already present on signed commits via sitsig). Doesn't solve the network problem — payload-encrypted-and-signed objects still leak metadata (which refs are pushed, which hashes are queried, who's connecting). Same model would need a session-level key exchange = TLS-shaped. Rejected as half-measure.
- **Plain HTTP without bearer auth, full stop.** Could ship today. Rejected: too easy to misdeploy. Bearer auth gives the loopback / trusted-network case a meaningful gate ("you need the token") without claiming security it doesn't deliver. The threat model is documented; the auth is honest about what it does and doesn't cover.
