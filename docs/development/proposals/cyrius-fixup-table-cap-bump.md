# Proposal — bump cyrius's fixup-table cap from 32,768

**Status (2026-04-25, post-5.7.1):** **Partially shipped + parked.** Cyrius 5.7.1 bumped 32,768 → 262,144 (8×) per this proposal. Sit retried v0.7.2 against the fresh cap and **still overflowed** — `error: fixup table full (262144)`. `CYRIUS_DCE=1` does not help (table fills during emit, before DCE runs). 8× was insufficient for sit + sandhi + transitive (`net`/`tls`/`ws`/`http`/`json`/`base64`/`mmap`/`dynlib`/`fdlopen`). Real cap need is unknown — the diagnostic is `>= N`, not `needed M`.

User decision 2026-04-25: **no v5.7.2 fixup re-bump now.** cyrius v5.7.2 slot is the cyrius-ts P1.1+P1.2 cherry-pick (preserved on `wip/cyrius-ts-p1` branch per CHANGELOG `[5.7.1]`). Fixup re-bump comes in a post-ts release; user will signal when ready. Sit v0.7.2 is parked at v0.7.1 commit until then; `src/serve.cyr` (250 lines, ready) stays on disk.

When the next cap bump ships, before retrying:

1. Add a fixup-count diagnostic to cyrius — print actual `fc` value at overflow so the next bump targets a known number, not another guess. (Original "Alternative #3" in the message thread; should land in the same release as the next cap bump.)
2. Try the v0.7.2 manifest re-add against the new cap.
3. If overflow again, the structural issue is real — re-evaluate vendor-subset (Alternative #2 below) or sandhi modular re-split as the path forward.

---

## Original proposal (filed pre-5.7.1)

**Affects:** cyrius (upstream). Blocks every downstream consumer that adds the sandhi-fold stdlib member to its `[deps].stdlib`.
**Affects:** cyrius (upstream). Blocks every downstream consumer that adds the sandhi-fold stdlib member to its `[deps].stdlib`.
**Original target release:** cyrius 5.7.1 (shipped 2026-04-25). **Insufficient — see status header above.**

## Problem

Adding `"sandhi"` (cyrius 5.7.0's vendored copy of sandhi v1.0.0, 9,649 lines, 469 public fns) to a consumer's `cyrius.cyml [deps].stdlib` overflows cyrius's hardcoded **32,768-entry fixup table** during compile, before DCE can strip unreached symbols. The compiler emits:

```
error: fixup table full (32768)
FAIL
```

and exits with rc 1. The build never gets far enough for `CYRIUS_DCE=1` to trim the cross-module call graph.

Reproduced in sit at the v0.7.2 boundary:

- Repo: `/home/macro/Repos/sit` at v0.7.1 (commit producing 127/127 tests, 709 KB DCE binary).
- Change: append `"net"`, `"tls"`, `"ws"`, `"http"`, `"json"`, `"base64"`, `"mmap"`, `"dynlib"`, `"fdlopen"`, `"sandhi"` to `[deps].stdlib`, plus include a 250-line `src/serve.cyr` that uses ~10 sandhi server fns.
- Result: `cyrius build src/main.cyr build/sit` fails with the message above. `CYRIUS_DCE=1` produces an identical failure plus a 0-byte binary at `build/sit`.

Removing `src/serve.cyr` from the include chain but keeping just `"net"` in `[deps].stdlib` still fails — the table fills before sandhi is even reached, just from sit's own code paths that touch net helpers transitively.

## Why this matters beyond sit

Per [sandhi ADR 0002](https://github.com/MacCracken/sandhi/blob/main/docs/adr/0002-clean-break-fold-at-cyrius-v5-7-0.md), sandhi was vendored *into* the cyrius stdlib explicitly so consumers could opt in via a single `"sandhi"` line in `[deps].stdlib`. Today, that line cannot be added by anyone who also has a non-trivial own-source program — sandhi alone burns ~470 fn × ~5 fixups/fn ≈ 2,350 fixups, and any real consumer's call graph adds thousands more.

Sandhi consumers named in cyrius CHANGELOG 5.7.0:

- vidya (active migration; currently consuming `lib/sandhi.cyr` directly)
- yantra, hoosh, ifran, daimon, mela, ark
- sit (this writeup)

Every one of them hits the same wall the moment they actually pin sandhi.

## Where the limit lives

`32768` is hardcoded in **at least 5** sites across cyrius (`grep -rn 32768 cyrius/src/` shows 69 hits, most fixup-related):

| File | Lines |
|---|---|
| `src/frontend/parse_expr.cyr` | 294, 762 |
| `src/backend/cx/emit.cyr` | 194 (cap check), 195 (msg), 286/287, 375/376 |
| `src/backend/aarch64/emit.cyr` | 326–329, 407/408, 559/560, 579+ |
| `src/backend/pe/emit.cyr` | 384 |
| (memory layout) `src/main_win.cyr:82` — comment "fixup_tbl (at 0x170B000 × 16 B × 32768)" |

The runtime fixup-table buffer itself sits at `0x170B000` per the Linux layout comment; entries are 16 bytes; the table consumes 32,768 × 16 = **512 KiB**.

The per-process counter is at offset `0x8FCA8` (`GFCNT`/`SFCNT` in `src/common/util.cyr`). Diagnostic output already references it (`/8192 fixup=...` strings — note the older `8192` figure, suggesting the cap has been bumped before but the diagnostic strings weren't kept in sync).

## Proposed fix (preferred)

**Bump the cap from 32,768 to 262,144 (8×).** New table size: 262,144 × 16 B = **4 MiB**. Justification:

- Comfortable headroom for sandhi (~3K fixups) + a 10K-line consumer (~20K fixups) + future stdlib growth.
- 4 MiB is a rounding-error in a modern compiler's address space; cyrius already maps a 0x170B000 ≈ 24 MiB working area.
- Power of 2; aligns cleanly with the bridge.cyr layout comment that says the table starts at a page boundary.
- Single change: the `32768` constant moves to `262144` everywhere, the layout offset for the *next* region after the fixup table moves accordingly (currently nothing follows on Linux per the comment; on Windows `main_win.cyr` may have layout that needs to shift).

### Patch shape

1. **Define a single constant** `CYR_FIXUP_TBL_MAX = 262144` in `src/common/util.cyr` (or wherever cyrius's "compiler limits" constants live — a quick scan didn't find a central one; if there isn't, this is a good moment to introduce it).
2. **Replace all `32768` literals** at the cap-check sites with the constant. List from the table above.
3. **Update the diagnostic strings** to read the constant — or at minimum update the literal `(32768)` in the error string to match. The aarch64 backend's variant (`"error: fixup table full ("` then `PRNUM(fc)` then `"/32768)\n"`) needs the trailing `/32768` updated.
4. **Re-stat the runtime memory layout** in `bridge.cyr:20` and `main_win.cyr:82` comments — the size doc-comments are stale (they reference both `8192` and `32768` in different places).
5. **Bump the actual table-region size** wherever it's pre-allocated. The 0x170B000 base + 32,768 × 16 = 0x170B000 + 0x80000 = 0x178B000 end; new end is 0x170B000 + 0x400000 = 0x1B0B000. Anything mapped above the old end needs to relocate.

### Risk

- **PE/Windows backend** may have layout assumptions that need to follow. Worth doing the patch on Linux first, then mirroring on PE.
- **Existing benchmarks / golden binary sizes** — cyrius's self-host fixpoint asserts byte-identical binary across cc5_a → cc5_b → cc5_c. The bump shouldn't change cc5 itself (cc5 has nowhere near 32K fixups), but the assertion is the right place to check no regression.
- **Reverse-jumps** that encode a fixup index in a smaller-than-i32 field (if any exist) would break. Worth grep'ing for narrower stores into the fixup-index field.

### Validation

After the cyrius patch lands as 5.7.1 and consumers bump:

```sh
cd /home/macro/Repos/sit
# Bump cyrius.cyml [package].cyrius = "5.7.1"
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

## Alternative considered: dynamic fixup table

Make the table a `vec`-shaped grow-on-demand structure. **Rejected for 5.7.1**: cyrius's runtime memory model is currently fixed-offset / static-layout in `main_win.cyr` and `bridge.cyr`. Introducing a heap-grown table would require touching the layout calculus + the bootstrap path, and benefits no real consumer beyond what 4 MiB already covers. Re-evaluate if/when a consumer actually approaches 256K fixups.

## Alternative considered: vendor sandhi-server subset into sit

Copy `sandhi_server_run`, `sandhi_server_recv_request`, `sandhi_server_get_method`, `sandhi_server_get_path`, `sandhi_server_path_only`, `sandhi_server_send_response`, `sandhi_server_send_status`, plus the `_hsv_*` helpers + `INADDR_LOOPBACK()` + a few `sock_*` helpers from `lib/net.cyr` into a sit-internal `src/wire_sandhi_min.cyr`. Drop `"sandhi"` from `[deps].stdlib`. Builds today.

**Rejected as a permanent path** because:

- The fork rots — sandhi's maintenance-mode patches (filed via cyrius releases per ADR 0002) stop propagating.
- Doesn't help the other 7 sandhi-consumer repos. They each end up with their own fork, multiplying the rot.
- Defeats the purpose of vendoring sandhi into stdlib.

**Acceptable as a temporary v0.7.2 path** if cyrius 5.7.1 is more than a few days out — the file would be marked clearly with a "DELETE ON CYRIUS 5.7.1" header so it doesn't survive the bump.

## Decision needed

User to confirm:

1. Cyrius patch goes ahead (preferred), targeted as cyrius 5.7.1 in the next ~day.
2. sit v0.7.2 stays parked on its v0.7.1 commit until cyrius 5.7.1 ships; then resume per the v0.7.x plan in `roadmap.md`.

Or, if (1) is more than a few days out:

3. Vendor the sandhi-server subset into sit (Alternative #2 above) as a temporary v0.7.2 path; rip it out at v0.7.3 once cyrius 5.7.1 is in.

## Cross-reference

- sit v0.7.x release plan: [`roadmap.md § v0.7.x`](../roadmap.md#v07x--network-transport-release-sequence).
- sandhi fold details: cyrius CHANGELOG `[5.7.0]` (2026-04-25, "THE SANDHI FOLD"); sandhi ADR 0002.
- Cross-project bug-writeup convention (this proposal lives sit-side, not in cyrius's repo, per sit's standing pattern): [`feedback_cross_project.md`](../../../.claude/projects/-home-macro-Repos-sit/memory/feedback_cross_project.md) (memory note, not in-tree).
