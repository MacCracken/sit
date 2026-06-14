# sit Development Roadmap

Forward-looking only. **Shipped history lives in [`CHANGELOG.md`](../../CHANGELOG.md)** (the tagged-release source of truth); the **live state snapshot** (current version, dep pins, source layout, command inventory) lives in [`state.md`](state.md). This file is just what's *next*.

## Now: the v1.0.0 cut

The v0.9.0 closeout / stabilization pass is complete (full suite, bench vs the v0.6.x scoreboard, dead-code audit, code review, security re-scan, refactor, downstream check, doc sweep, clean build — audit at [`../audit/2026-06-13-audit.md`](../audit/2026-06-13-audit.md)). The full git-parity surface is in place:

- Local VCS loop (init → add → commit → branch → merge → tag), ed25519-signed commits + `verify-commit`.
- `fsck` with integrity + reachability (`dangling`) + `--prune`.
- Git-parity `.sitignore` (negation, `**`, char classes, anchoring).
- `log --graph`, shallow clone (`--depth N`), `merge-base` (full-DAG LCA).
- Network sync over `file://` / `http://` / `https://` (first-party TLS 1.3, TOFU-pinned) / `ssh://` — clone, fetch, push on all four; `sit serve` host side.

**v1.0.0 is the ceremonial cut on a green tree**: VERSION → 1.0.0, CHANGELOG header, version-verify gate, tag. No feature or fix work is planned before it.

## After v1.0.0

Genuinely open work, none of it blocking the 1.0 cut. Ordered roughly by readiness, not committed to specific minors. Each is a small bite under the usual test/fuzz/bench gates.

### sit-side features

- **Reflog + `fsck --prune` grace period.** `fsck --prune` is immediate/unrecoverable today (`git gc --prune=now` semantics). A reflog (`.sit/logs/`) is the prerequisite for a real grace period — record ref movements so a recently-orphaned object can be recovered and a prune can honour an age window. The reflog is the larger feature; the prune grace period falls out of it.
- **`sit serve` non-loopback exposure.** Now unblocked (HTTPS shipped). Today `--listen` is parse-locked to `127.0.0.1`; lift the validator restriction so a TLS-fronted `sit serve` can bind a public interface, gated on `--tls` being present (refuse non-loopback plain HTTP).
- **HTTPS CA-chain + hostname verification (opt-in).** Decided 2026-06-10: TOFU/pinned trust is the default; add an opt-in CA path for public-CA-signed deployments. Git-shaped knobs — `http.sslVerify` to toggle, `http.caBundle` to point at a PEM, default to the system store via `tls_native_set_ca_system` — driving `tls_native_client_verify_chain` + `tls_native_client_verify_hostname`. Lets a Let's-Encrypt-fronted `sit serve` be cloned without a first-use prompt.
- **mTLS.** Builds on HTTPS; `tls_native_new_server` + client-cert verify primitives already exist. Slot when a deployment wants it.
- **Bearer auth over SSH** (belt-and-suspenders). `_ssh_handle_auth_token` flips from stub to real; `wire_ssh_open`'s capabilities probe detects `"auth":["bearer"]` and loads `~/.sit/serve.token` like the HTTP path. SSH's own key-exchange auth covers the canonical case, so this is on-demand.
- **Octopus / N-way merge.** `find_merge_base` already walks N parents correctly, but `cmd_merge` only does a 2-way merge, so 3+-parent commits can't be created. A future N-way merge would close the gap.
- **Myers O((N+M)D) diff fallback (P-14).** The LCS DP table is O(N·M) and caps at the 8192-per-dimension / 16M-cell cliff (see the `lcs-diff-4000x4000` bench). A Myers fallback would handle large diffs the DP table refuses.
- **`sit add` index upsert without full rewrite (P-11).** Gated on patra growing an `or_ignore` flag on `patra_insert_row` (see cross-project asks). Until then the index is rewritten wholesale.
- **Pack bundles.** Batch object transfer using sankoch delta primitives, to cut the per-object wire cost further. Ties to sankoch + patra storage-shape work that isn't ready.
- **Surface minimization — drop sandhi for a hand-rolled loopback HTTP/1.0 server.** sit uses ~6 of sandhi's ~11.7k lines (`sandhi_server_*`). The cyrius cap raise made this non-blocking, but the surface argument holds — the same `net`-direct pattern `wire_http.cyr` already uses client-side. ~500 lines of new `src/serve.cyr` parser; trades share-with-AGNOS-consumers for surface-area minimization.

### Open upstream issue

- **Ed25519 server certs fail the `tls_native` handshake** ([`../development/issues/2026-06-10-tls-native-ed25519-server-cert-accept-fails.md`](issues/2026-06-10-tls-native-ed25519-server-cert-accept-fails.md)). ECDSA P-256 server certs work; Ed25519 is an upstream cyrius gap. `sit serve --tls` is documented to use an ECDSA P-256 cert until it lands.

### Cross-project asks (filed on dep roadmaps)

When any of these ship, sit gets the improvement or drops a workaround with no further sit-side code — watch their CHANGELOGs.

- **patra** — `or_ignore` flag on `patra_insert_row` (unblocks P-11 and lets `db_object_insert_raw` drop its inner `db_object_has` probe); bound parameters for STR columns (the structurally-correct fix for the SQL-string interpolation that `hex_prefix_valid` currently guards).
- **sigil** — a `hex_decode` that strictly fails on an invalid character instead of partial-decoding.
- **sankoch** — a `zlib_decompress_with_ratio_cap` primitive so every consumer gets a one-call decompression-bomb defense; and the larger 2.x match-finder / ring-buffer / SIMD work that targets the remaining `add-1MB` `zlib_compress` floor (~140 ms).

---

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). The v0.6.x performance scoreboard (`add-1MB −48%`, `add-64KB −43%`, `clone −30%`, `log −17%`, `status −9%` from the v0.6.0 baseline) is carried in [`../benchmarks/`](../benchmarks/).*
