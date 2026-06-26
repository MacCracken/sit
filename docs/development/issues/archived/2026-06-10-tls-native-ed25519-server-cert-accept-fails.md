# cyrius `lib/tls_native.cyr` — server handshake fails with an Ed25519 certificate (ECDSA P-256 works)

> **RESOLVED (2026-06-25, sit 1.0.x).** Fixed upstream and confirmed against the
> pinned deps (cyrius 6.2.44 / sigil 3.9.4). Root cause was **not** the TLS layer —
> `tls_native`'s CertVerify already signed/verified Ed25519 — but sigil's X.509
> parser was ECDSA/RSA-only, so the server's `load_creds` rejected the Ed25519 cert
> (`x509_parse → CERT_INVALID`) before the handshake. sigil 3.9.x added id-Ed25519 to
> `_xp_parse_sig_algid` / `_xp_parse_spki` / `_x509_verify_link`; cyrius 6.x folds it
> in. sit needed **no code change** — `sit serve --tls` is cert-algorithm-agnostic.
> Consumed on the 1.0.x line: the getting-started "ECDSA P-256 only" caveat is
> dropped and the https CI smoke now uses an Ed25519 server cert. Archived.

**Discovered:** 2026-06-10 during sit v0.8.8 HTTPS server work (`sit serve --tls`)
**Severity:** Medium — limits `sit serve --tls` (and any `tls_native` server consumer) to ECDSA P-256 / P-384 certs; an Ed25519 server cert fails the handshake. ECDSA P-256 works, so sit ships unblocked, but Ed25519 is a common modern default and the failure mode is opaque ("tls handshake failed").
**Affects:** cyrius `lib/tls_native.cyr` at 6.1.29 (server role). Client role + ECDSA certs unaffected.

## Summary

`sit serve --tls` stands up a TLS 1.3 server via `tls_native_new_server(cert, cert_len, key, key_len)` → `tls_native_server_load_creds` → `tls_native_accept(ctx, fd)`. With an **ECDSA P-256** server cert this works end-to-end (sit's `tls_native` client *and* OpenSSL `s_client` both connect). With an **Ed25519** server cert, `tls_native_accept` returns non-OK and the handshake never completes — even though `tls_native`'s ClientHello advertises Ed25519 in `signature_algorithms` and `_tn_load_privkey` accepts Ed25519 keys.

## Reproduction

```sh
# Ed25519 server cert → handshake fails:
openssl req -x509 -newkey ed25519 -keyout k.pem -out c.pem -days 1 -nodes -subj "/CN=127.0.0.1"
sit serve <repo> --tls --cert c.pem --key k.pem --listen 127.0.0.1:8443 &
sit clone https://127.0.0.1:8443 /tmp/x
# → "sit: tls handshake failed (is the server speaking TLS 1.3?)"

# ECDSA P-256 server cert → works:
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout k.pem -out c.pem -days 1 -nodes -subj "/CN=127.0.0.1"
sit serve <repo> --tls --cert c.pem --key k.pem --listen 127.0.0.1:8443 &
sit clone https://127.0.0.1:8443 /tmp/x   # → TOFU-pinned, fetches, fsck-clean
```

The same Ed25519 failure reproduced earlier against an OpenSSL `s_client` peer during sit's bite-2 client validation, so it is server-side cert / signature handling, not a sit↔sit interop quirk.

## Suspected area

The server CertVerify path (signing the handshake transcript with the leaf key) or the server cert / sig-alg selection — likely the `ed25519` (0x0807) signature scheme not being emitted / honored on the server side the way `ecdsa_secp256r1_sha256` is. Client-side Ed25519 *verification* may also be untested.

## Workaround (sit, today)

Use an ECDSA P-256 cert for `sit serve --tls`. sit's getting-started docs + the v0.8.8 CI smoke standardize on `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1`. No sit-side code change needed — this is purely an upstream `tls_native` gap.

## Owner

cyrius (`lib/tls_native.cyr`). Filed from sit; carry to the cyrius repo's issue tracker / roadmap. When fixed, sit can broaden the CI smoke to also assert Ed25519 server certs and drop the "ECDSA P-256 only" note.
