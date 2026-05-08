# 0006 — Batched-want frame format

**Status**: Accepted
**Date**: 2026-05-08

## Context

v0.7.3 made `sit clone http://...` work end-to-end via per-object `GET /sit/v1/objects/<hex>` requests. On the v0.7.3 100-commit / 100-file smoke fixture, the wall-clock budget broke down as:

- Loopback TCP setup + HTTP/1.0 close-delimited round trip: ~700 µs per object
- 300 objects (100 commits + 100 trees + 100 blobs) → ~210 ms total
- Loopback bandwidth + zlib decompression are not load-bearing at this scale

So the per-GET clone is bound by sequential connection setup. The v0.7.x release plan (settled 2026-04-25) calls for a `POST /sit/v1/want` endpoint in v0.7.4 that ships multiple compressed objects per response. The success gate is **≥30% clone speedup vs 0.7.3 OR revert**, plus a frame decoder fuzzed to ≥10M iterations because it parses an attacker-shaped binary stream.

This ADR pins the wire format. The server side, client side, and fuzz harness all read from this document.

## Decision

### Request: `POST /sit/v1/want`

Body is a fixed-shape header followed by exactly `count` 64-byte ASCII hex hashes:

```
+--------+--------+--------+--------+
| count (i64 LE)                    |   8 bytes
+-----------------------------------+
| hash[0]  (64 ASCII hex bytes)     |  64 bytes
+-----------------------------------+
| hash[1]  (64 ASCII hex bytes)     |  64 bytes
+-----------------------------------+
                ...
+-----------------------------------+
| hash[count-1]                     |  64 bytes
+-----------------------------------+
```

- **Total body length**: `8 + count*64` — server validates exactly this; mismatched length → 400.
- **count cap**: structurally bound by sandhi's request buffer (`HSV_REQ_BUF_SIZE = 64 KiB`) — `count <= (HSV_REQ_BUF_SIZE - request_headers - 8) / 64`. Sit's server pins `SIT_WANT_MAX_COUNT = 512` (body size ≈ 32 KiB, leaves ample headroom for headers up to a sane MTU). Clients should chunk at the same boundary; requests over the cap → 413. (Future increase: when sandhi grows a per-handler request buffer override, sit can raise the cap to whatever fits in `SIT_SERVE_MAX_BODY` minus reasonable overhead.)
- **Hash validation**: each 64-byte slot must pass `hex_prefix_valid`; otherwise 400. The hex form is its own validator — corrupt bytes fail-fast on a recognizable boundary.
- **Content-Type**: `application/octet-stream` (the body is not JSON; sandhi doesn't care, this is documentation for proxies / curl).

### Response: `200 OK` with `Content-Type: application/octet-stream`

Body is the concatenation of one frame per hash that the server resolved, in request order. Hashes the server doesn't have are **silently omitted** — clients detect missing objects by counting frames and comparing against the request count.

```
+-------------------------------------+
| hash (64 ASCII hex bytes)           |  64 bytes
+-------------------------------------+
| ty (i64 LE) — patra type code       |   8 bytes
+-------------------------------------+
| clen (i64 LE) — compressed length   |   8 bytes
+-------------------------------------+
| compressed payload (clen bytes)     |   variable
+-------------------------------------+
```

- **`ty`**: `0` = blob, `1` = tree, `2` = commit. Anything else → client refuses the frame.
- **`clen`**: must satisfy `0 < clen <= 16 MiB`. Negative or oversized → client refuses.
- **`compressed`**: zlib-compressed bytes, byte-identical to what `GET /sit/v1/objects/<hex>` would have returned for the same hash. The server never recompresses; it copies straight out of `objects.patra`.
- **Frame walking**: the client reads frames sequentially until exhausting the response body. Partial trailing frame → reject the whole response.

### Capability advertisement

`GET /sit/v1/capabilities` carries an additional `"batch": true` boolean once `/sit/v1/want` is wired:

```json
{"sit":"0.7.4","max_body":16777216,"auth":["none"],"objects":true,"batch":true}
```

Clients probe capabilities once at fetch start. Absent flag, false flag, or any 404 from `/want` → fall back to per-object `GET` (the v0.7.3 path stays intact).

### Endianness

All multi-byte integers are little-endian. Sit is x86_64-first (aarch64 is also LE), and storage on disk via patra is also LE. Network byte order would buy us nothing here but cost a swap on every read.

## Consequences

### Positive

- **One TCP setup amortized over many objects.** Expected dominant win on loopback and on real networks (TCP slow-start amortizes too).
- **Format is its own validator.** ASCII hex hashes self-validate; LE ints are bounded by clen + ty checks. No structural ambiguity for fuzz to exploit beyond the bounds we explicitly check.
- **Fallback is free.** Clients that don't see `"batch":true` (older servers, future minimal servers) just keep per-object GET working. No version negotiation handshake needed.
- **Frames mirror `objects.patra` row layout** (`hash STR`, `ty INT`, `content BYTES`) so the server's serializer is essentially `SELECT hash, ty, content WHERE hash IN (...)` followed by length-prefixed concatenation — no transform layer.

### Negative

- **No per-frame integrity check.** A truncated TCP read mid-frame will be detected (clen vs remaining), but a flipped bit inside a payload won't. `sit fsck` is the canonical roundtrip per CLAUDE.md ("SHA-256 roundtrips belong in fsck, not the hot path") — same trust model as v0.7.3 per-object GET. TLS in v0.7.6 covers MITM.
- **Server can lie about hashes.** A malicious server could ship `compressed_for_X` under `hash=Y`. The client persists into `objects.patra` keyed by the server's claimed hash, so `sit fsck`'s SHA-256 roundtrip catches it after clone. Documented as a fsck-time check, not a hot-path check, per the v0.7.3 trust boundary.
- **No streaming on large clones.** Each request/response is single-shot; a 100-MB response sits in 16 MiB chunks and forces the client to issue multiple POSTs. Acceptable for v0.7.4 — chunked transfer encoding becomes interesting only when individual responses exceed `WIRE_HTTP_MAX_BODY`, which a sensible client batch size avoids.

### Neutral

- **Capability sniffing happens on every fetch.** One extra round trip to `/capabilities` per `do_fetch` invocation. Could be cached on the client but isn't worth it — fetch is rare and the capability response is small. Defer.
- **Frame format is wire-protocol surface.** Breaking changes require a new capability flag (e.g., `"batch_v2": true`) — the server can advertise both during a transition. Same forward-compat shape git uses.

## Alternatives considered

- **Binary 32-byte hashes instead of 64 ASCII hex.** Saves 32 bytes per frame (× 300 frames = 9.6 KB per 100-commit clone). Rejected: the entire `/sit/v1/...` wire is already ASCII hex; mixing forms costs more in code complexity and parser surface than it saves in bytes. The savings are noise next to compressed object payloads.
- **JSON envelope (`{"objects":[{"hex":"...", "ty":0, "compressed_b64":"..."}]}`)**. Rejected: base64 inflates the dominant payload bytes by 33%; JSON parse cost on multi-MiB bodies is non-trivial; no clean way to carry binary in JSON without that inflation. Hand-rolled binary frame is faster to encode and decode on both ends.
- **HTTP/1.1 multipart**. Rejected: parser surface is huge (boundary detection, per-part headers), buys nothing over a length-prefixed binary stream that we control end-to-end.
- **Network byte order on the integers.** Rejected: every reader on x86_64 / aarch64 (the only sit targets) would pay a `bswap`. Sit is LE on disk (patra) and in memory; LE on the wire is the natural form. Documented endianness up front so future big-endian platforms (if any) know what they're paying.
- **Per-frame magic bytes for resync.** Rejected: a partially-corrupted stream is unrecoverable — the next frame's `clen` would be wrong, the parse fails. Magic bytes don't help us resync because we have no application-level meaning beyond "next 80 + clen bytes are a frame." `sit fsck` after clone is the integrity gate.
- **Streaming via HTTP chunked encoding.** Considered for huge responses. Deferred: not needed at v0.7.4 batch sizes (256 objects × ~5 KB = ~1.3 MiB per response). Worth revisiting if someone clones a repo with multi-MiB blobs at scale.
