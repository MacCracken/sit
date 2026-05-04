# cyrius parser cap (fixup / token table) overflows on `"sandhi"` opt-in — RESOLVED

## Resolution

**Fixed in cyrius 5.8.46** (2026-05-03). The two distinct caps the
issue conflated turned out to require separate handling:

- **Fixup-table cap** — already raised 32768 → 262144 in v5.7.1
  and 262144 → 1048576 in v5.7.7. By v5.8.45 this was no longer
  the binding limit for sit.
- **Token-array cap** (the actual blocker at v5.8.45) — was
  262144 entries (2 MiB per array), with `tok_types` overlapping
  `output_buf` at S+0x94A000. The 2026-05-03 retest's
  `error: token limit exceeded (262144)` came from
  `src/frontend/lex.cyr:95`'s ADDTOK cap check, not the fixup
  table.

**v5.8.46 fix path:**
1. **Step 1 (the issue's "REQUIRED before next cap bump"):**
   `src/frontend/lex.cyr` ADDTOK diagnostic upgraded from
   `error: token limit exceeded (262144)` to
   `error: token limit exceeded: needed M, cap is N` so future
   cap raises target an empirical M. Re-running sit's build with
   the new diagnostic captured the threshold-abort: `needed
   262145, cap is 262144`.
2. **Step 2 (cap raise sized per the issue's heuristic — round
   up to next power-of-2, then double from M):** token cap
   raised 262144 → **1048576** (4×). `tok_types` / `tok_values`
   / `tok_lines` arrays relocated from the
   0x94A000 / 0xD4A000 / 0xF4A000 trio (each 2 MiB at those
   addresses, with `tok_types` overlapping `output_buf`) to a
   fresh post-TS-region high block at
   **0x368C000 / 0x3E8C000 / 0x468C000** (each 8 MiB). Heap
   `brk` extended to `S + 0x4E8C000` (~78.5 MB) in every
   `main_*.cyr`; `main_win.cyr` MMAP raised 0x2000000 → 0x5000000.
3. **Step 3 (verification — sit unblocked end-to-end):** sit
   v0.7.2 manifest changes restored (`net`, `tls`, `ws`, `http`,
   `json`, `sandhi` added to `cyrius.cyml [deps].stdlib`;
   `include "src/serve.cyr"` added to `src/lib.cyr`); sit builds
   to a 1.28 MiB binary; `cyrius test` reports 127/127.

**Discovered:** 2026-04-25 during sit v0.7.2 build attempt (first feature-bearing patch in the v0.7.x line — `sit serve` skeleton + `"sandhi"` in `[deps].stdlib`).
**Severity:** High — hard build failure on a shipping consumer with only a fork-the-stdlib workaround. Blocks every other sandhi consumer named in cyrius CHANGELOG `[5.7.0]` (vidya, yantra, hoosh, ifran, daimon, mela, ark) the moment they pin sandhi.
**Affects:** cyrius 5.7.1 through **5.8.45** verified.
**Resolved at:** cyrius 5.8.46 (2026-05-03). The 5.7.1 cap bump (32,768 → 262,144, 8×) was insufficient; v5.8.46's 4× bump (262,144 → 1,048,576) sized to the empirical M from the new `needed M, cap is N` diagnostic.

Error-message history across the affected range:
- 5.7.0 and earlier: `error: fixup table full (32768)` (fixup-table-bound, pre-v5.7.1)
- 5.7.1: `error: fixup table full (262144)` (fixup-table-bound, pre-v5.7.7)
- 5.8.45: `error: token limit exceeded (262144)` (token-array-bound; was misread as "same fixup limit, renamed")
- 5.8.46: `error: token limit exceeded: needed M, cap is N` (informative diagnostic; cap raised to 1,048,576)

## Summary

Adding `"sandhi"` (cyrius 5.7.0's vendored copy of sandhi v1.0.0, 9,649 lines, 469 public fns; 5.8.39 re-vendored sandhi v1.1.0, ~10K lines, ~620 public fns) to a consumer's `cyrius.cyml [deps].stdlib` overflows cyrius's hardcoded **262,144-entry parser cap** during compile, before DCE can strip unreached symbols. The compiler emits `error: token limit exceeded (262144)` (formerly `error: fixup table full`) and exits rc 1. The build never gets far enough for `CYRIUS_DCE=1` to trim the cross-module call graph.

The 5.7.1 cap raise (32,768 → 262,144) was filed against this issue (preferred fix in the original report) and shipped, but **8× was still insufficient for a real consumer**. sit's own retest at the fresh cap immediately blew through it. The diagnostic is `>= N`, not `needed M`, so the next bump is sized by guess again. Per the original "before retrying" list, **a fixup-count diagnostic must land before the next cap raise** so the bump targets a known number.

Status as of 2026-05-03: **sit v0.7.2 remains parked at v0.7.1**. `src/serve.cyr` (250 lines, ready) stays on disk. cyrius pin advanced 5.7.1 → 5.8.45 separately (95-patch toolchain refresh, no functional change in sit) but the parser cap did not move in that span.

## Reproduction

### Reproduced under cyrius 5.8.45 (2026-05-03 retest)

Working tree state at start: sit at v0.7.1 (commit 9bcd3b9), 127/127 tests, ~709 KB DCE binary.

```sh
cd /home/macro/Repos/sit

# 1. Bump cyrius pin
sed -i 's/cyrius = "5.7.1"/cyrius = "5.8.45"/' cyrius.cyml

# 2. Add "sandhi" + transitive needs to [deps].stdlib
#    (also tried minimal: just "net" + "sandhi" — same failure)
# Append to cyrius.cyml [deps].stdlib:
#    "net", "tls", "ws", "http", "json", "sandhi"

# 3. Wire serve.cyr into the include chain
echo 'include "src/serve.cyr"' >> src/lib.cyr

# 4. Add cmd_serve dispatch + usage line in src/main.cyr (one-line each)

# 5. Build
cyrius deps                                  # 5/5 resolved clean
cyrius build src/main.cyr build/sit
# → compile src/main.cyr -> build/sit [x86_64] error: token limit exceeded (262144)
# → FAIL
```

`CYRIUS_DCE=1` does not help — the cap fills during emit, before DCE runs.

Minimal repro (just `"sandhi"` + `"net"` in stdlib, no http/tls/ws/json) **also overflows** — sandhi alone is enough to blow the cap on a real consumer. Adding the transitive `net`/`tls`/`ws`/`http`/`json` block (which sandhi pulls via `SYS_SETSOCKOPT` etc.) was an attempt to satisfy declared deps, not the source of overflow.

### Original repro (2026-04-25, pre-5.7.1 — kept for history)

Reproduced in sit at the v0.7.2 boundary against cyrius 5.7.0:

- Repo: `/home/macro/Repos/sit` at v0.7.1 (commit producing 127/127 tests, 709 KB DCE binary).
- Change: append `"net"`, `"tls"`, `"ws"`, `"http"`, `"json"`, `"base64"`, `"mmap"`, `"dynlib"`, `"fdlopen"`, `"sandhi"` to `[deps].stdlib`, plus include a 250-line `src/serve.cyr` that uses ~10 sandhi server fns.
- Result: `cyrius build src/main.cyr build/sit` failed with `error: fixup table full (32768)`. `CYRIUS_DCE=1` produced an identical failure plus a 0-byte binary at `build/sit`.

Removing `src/serve.cyr` from the include chain but keeping just `"net"` in `[deps].stdlib` still failed — the table filled before sandhi was even reached, just from sit's own code paths that touch net helpers transitively.

## Why this matters beyond sit

Per [sandhi ADR 0002](https://github.com/MacCracken/sandhi/blob/main/docs/adr/0002-clean-break-fold-at-cyrius-v5-7-0.md), sandhi was vendored *into* the cyrius stdlib explicitly so consumers could opt in via a single `"sandhi"` line in `[deps].stdlib`. Today, that line cannot be added by anyone who also has a non-trivial own-source program — sandhi alone burns ~470 fn × ~5 fixups/fn ≈ 2,350 fixups, and any real consumer's call graph adds thousands more.

Sandhi consumers named in cyrius CHANGELOG `[5.7.0]`:

- vidya (active migration; currently consuming `lib/sandhi.cyr` directly)
- yantra, hoosh, ifran, daimon, mela, ark
- sit (this writeup)

Every one of them hits the same wall the moment they actually pin sandhi.

## Root cause (where the limit lives)

`32768` was originally hardcoded in **at least 5** sites across cyrius (`grep -rn 32768 cyrius/src/` showed 69 hits, most fixup-related):

| File | Lines |
|---|---|
| `src/frontend/parse_expr.cyr` | 294, 762 |
| `src/backend/cx/emit.cyr` | 194 (cap check), 195 (msg), 286/287, 375/376 |
| `src/backend/aarch64/emit.cyr` | 326–329, 407/408, 559/560, 579+ |
| `src/backend/pe/emit.cyr` | 384 |
| (memory layout) `src/main_win.cyr:82` — comment `"fixup_tbl (at 0x170B000 × 16 B × 32768)"` |

The runtime fixup-table buffer itself sits at `0x170B000` per the Linux layout comment; entries are 16 bytes; the table consumes 32,768 × 16 = **512 KiB**.

The per-process counter is at offset `0x8FCA8` (`GFCNT`/`SFCNT` in `src/common/util.cyr`). Diagnostic output already references it (`/8192 fixup=...` strings — note the older `8192` figure, suggesting the cap has been bumped before but the diagnostic strings weren't kept in sync).

5.7.1 raised every `32768` literal at these sites to `262144` (8×). 5.8.x renamed the diagnostic from "fixup table full" to "token limit exceeded" but did not raise the cap further. The underlying table is the same; today's working assumption is that `5.7.0 fixup table` ≡ `5.8.x token limit` until the cyrius agent confirms or refutes.

## Proposed fix

### Step 1 — fixup-count diagnostic (REQUIRED before next cap bump)

Print actual `fc` value at overflow so the next bump targets a known number, not another guess. Currently the message is `error: token limit exceeded (262144)` — change to `error: token limit exceeded: needed M, cap is 262144` (or equivalent). This was the original "Alternative #3" in the message thread; it should land in the same release as the next cap bump so a sit re-test can produce a target M.

### Step 2 — bump the cap (sized to the diagnostic's M)

Once Step 1 ships and sit (or vidya, the other active sandhi consumer) reports an actual M, bump the cap to a comfortable headroom over M. Heuristic: round up to next power-of-2, then double.

For reference, the original 32,768 → 262,144 bump's reasoning still applies, just at a higher target:

- Comfortable headroom for sandhi (~3K fixups under the original count; ~3.5–4K under sandhi v1.1.0's expanded surface) + a 10K-line consumer (~20K fixups) + future stdlib growth.
- 4 MiB (the 262,144 × 16 B sizing) was a rounding-error in a modern compiler's address space; cyrius already maps a 0x170B000 ≈ 24 MiB working area. A further 2× is also rounding-error.
- Power of 2; aligns cleanly with the bridge.cyr layout comment that says the table starts at a page boundary.

### Patch shape

1. **Define a single constant** `CYR_FIXUP_TBL_MAX = <new value>` in `src/common/util.cyr` (or wherever cyrius's "compiler limits" constants live — a quick scan didn't find a central one; if there isn't, this is a good moment to introduce it).
2. **Replace all literal `262144`** at the cap-check sites with the constant.
3. **Update the diagnostic strings** to read the constant — or at minimum update the literal `(262144)` in the error string to match. The aarch64 backend's variant (`"error: fixup table full ("` then `PRNUM(fc)` then `"/32768)\n"`) also needs the trailing literal updated; this style of `"/<old>"` suffix has slipped before (the `/8192` strings still drift in some message paths).
4. **Re-stat the runtime memory layout** in `bridge.cyr:20` and `main_win.cyr:82` comments — the size doc-comments are stale (they reference both `8192`, `32768`, and now `262144` in different places).
5. **Bump the actual table-region size** wherever it's pre-allocated. Compute new region end against the new cap and re-locate anything mapped after it.

### Risk

- **PE/Windows backend** may have layout assumptions that need to follow. Worth doing the patch on Linux first, then mirroring on PE.
- **Existing benchmarks / golden binary sizes** — cyrius's self-host fixpoint asserts byte-identical binary across cc5_a → cc5_b → cc5_c. The bump shouldn't change cc5 itself (cc5 has nowhere near 262K fixups), but the assertion is the right place to check no regression.
- **Reverse-jumps** that encode a fixup index in a smaller-than-i32 field (if any exist) would break. Worth grep'ing for narrower stores into the fixup-index field.

### Validation

After the cyrius patch lands and consumers bump:

```sh
cd /home/macro/Repos/sit
# Bump cyrius.cyml [package].cyrius = "5.X.Y"
# Restore the v0.7.2 manifest changes:
#   add "net", "tls", "ws", "http", "json", "base64", "mmap", "dynlib",
#       "fdlopen", "sandhi" to [deps].stdlib
#   re-add 'include "src/serve.cyr"' to src/lib.cyr
#   re-add the cmd_serve dispatch + usage line in src/main.cyr
cyrius deps
cyrius build src/main.cyr build/sit          # must succeed
cyrius test tests/sit.tcyr                   # must show 127+/127+ pass
./build/sit serve /tmp/some-repo &
curl http://127.0.0.1:8484/sit/v1/capabilities  # → JSON 200
curl http://127.0.0.1:8484/sit/v1/refs          # → JSON 200
```

If those four steps pass, the fix is verified end-to-end against the smallest real consumer.

## Consumer-side workarounds

### (1) Park (current sit posture)

sit v0.7.2 stays at v0.7.1. `src/serve.cyr` and `lib/sandhi.cyr` stay on disk as ready code. Wait for the cyrius cap raise.

### (2) Vendor sandhi-server subset into sit

Copy `sandhi_server_run`, `sandhi_server_recv_request`, `sandhi_server_get_method`, `sandhi_server_get_path`, `sandhi_server_path_only`, `sandhi_server_send_response`, `sandhi_server_send_status`, plus the `_hsv_*` helpers + `INADDR_LOOPBACK()` + a few `sock_*` helpers from `lib/net.cyr` into a sit-internal `src/wire_sandhi_min.cyr`. Drop `"sandhi"` from `[deps].stdlib`. Builds today.

**Rejected as a permanent path** because:

- The fork rots — sandhi's maintenance-mode patches (filed via cyrius releases per ADR 0002) stop propagating.
- Doesn't help the other 7 sandhi-consumer repos. They each end up with their own fork, multiplying the rot.
- Defeats the purpose of vendoring sandhi into stdlib.

**Acceptable as a temporary v0.7.2 path** if the cyrius fix is more than a few days out — the file would be marked clearly with a "DELETE ON CYRIUS <version>" header so it doesn't survive the bump.

### (3) Alternative considered: dynamic fixup table

Make the table a `vec`-shaped grow-on-demand structure. **Rejected for the 5.7.1 bump and still rejected today**: cyrius's runtime memory model is currently fixed-offset / static-layout in `main_win.cyr` and `bridge.cyr`. Introducing a heap-grown table would require touching the layout calculus + the bootstrap path, and benefits no real consumer beyond what a 4–16 MiB cap already covers. Re-evaluate if/when a consumer actually approaches 1M fixups.

## Cross-reference

- sit v0.7.x release plan: [`roadmap.md § v0.7.x`](../roadmap.md#v07x--network-transport-release-sequence).
- sandhi fold details: cyrius CHANGELOG `[5.7.0]` (2026-04-25, "THE SANDHI FOLD"); sandhi v1.1.0 re-fold: cyrius CHANGELOG `[5.8.39]` (2026-05-03); sandhi ADR 0002.
- 2026-04-25 retry log (cyrius 5.7.1 fresh cap, 8× insufficient): captured in this issue's status header above.
- 2026-05-03 retry log (cyrius 5.8.45 — same cap, error renamed): captured in the Reproduction section.
