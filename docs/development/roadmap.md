# sit Development Roadmap

Forward-looking only. **Shipped history lives in [`CHANGELOG.md`](../../CHANGELOG.md)** (the tagged-release source of truth); the **live state snapshot** (current version, dep pins, source layout, command inventory) lives in [`state.md`](state.md). This file is just what's *next*.

## Shipped: 1.0.0 (2026-06-13)

The first stable release. The full git-parity surface is in place — local VCS loop + `merge-base`; `fsck` integrity/reachability/`--prune`; ed25519 signing; git-parity `.sitignore`; `log --graph`; shallow clone; network sync (clone/fetch/push) over `file://` / `http://` / `https://` (first-party TLS 1.3) / `ssh://`; `dist/sit.cyr` library export. From 1.0 the CLI, `.sit/` layout, `/sit/v1/...` wire protocol, and the `sit_*` / `ann_*` public API are SemVer-governed. Details in [`CHANGELOG.md`](../../CHANGELOG.md); closeout audit at [`../audit/2026-06-13-audit.md`](../audit/2026-06-13-audit.md).

## Shipped: 1.1.0 (2026-06-25)

**Reflog + recovery.** Git-compatible `.sit/logs/` journal (recorded across commit / reset / merge / checkout / branch-create / clone / pull / fetch); `sit reflog`; `<ref>@{N}` / `HEAD@{N}` resolution (`sit reset --hard HEAD@{1}` undoes a reset); reflog-aware `fsck --prune` grace (reflog-as-roots + 90-day window) with `--prune-now` for the legacy immediate sweep. The recovery net that de-risks the rewrite tools below. Design: [ADR 0010](../adr/0010-reflog-and-recovery.md) · invariants: [arch 005](../architecture/005-reflog-two-line-invariant.md) · full detail in [`CHANGELOG.md`](../../CHANGELOG.md#110--2026-06-25--reflog--recovery).

**Reflog follow-ups (forward):**
- `reflog expire` / `delete` — entries are currently unbounded, so `fsck --prune` reclaims reflogged objects only via `--prune-now` (or a manual log clear) until expiry exists. A small `1.x` (new `reflog` subcommand surface).
- `@{<date>}` selector — only the integer `@{N}` ordinal ships today.
- Hardening pass on the same unsanitized-identity pattern in `commit.cyr` / `merge.cyr` object framing (the reflog path was hardened in 1.1.0; the commit/merge ident chain is the remaining instance) — a no-surface `1.0.x` security patch.

## After v1.0.0

Post-1.0, versioning is SemVer-disciplined (the [1.0.0 commitment](../../CHANGELOG.md)), which is what sorts the backlog into tiers:

- **Patch (`1.0.x`)** — no new *observable* surface: bug fixes, perf, internal refactors, toolchain/dep bumps, consuming upstream fixes. Safe to take blindly.
- **Minor (`1.1.0`, `1.2.0`, …)** — new *backward-compatible* surface: a command, flag, config key, public-API symbol, or wire capability. Each themed minor below is its own `1.x.0`.
- **Major (`2.0.0`)** — reserved for a breaking change to the CLI, `.sit/` layout, wire protocol, or public API. None planned.

The weight tends to track the tier (surface-adding work is the heavier work), with two instructive exceptions called out below: the Myers diff fallback is heavy but adds no surface (→ patch), and bearer-over-SSH is light but adds surface (→ minor). Nothing here blocks anything else; the ordering is a recommendation, not a contract. Each ships under the usual test/fuzz/bench gates.

### `1.0.x` — patch line (no new surface)

Bug fixes, perf, internal work, and dep consumption — nothing a caller observes beyond "faster" / "handles bigger inputs". Shipped patch work moves to the [CHANGELOG](../../CHANGELOG.md) (e.g. 1.0.1: the Myers diff fallback for large files, the `lcs_diff` minimality fix it surfaced, and the ADR-0003 no-upward-discovery test; 1.0.2 + 1.0.3: cyrius toolchain refreshes — `6.2.2 → 6.2.25 → 6.2.44` — and dep bumps, consuming the `random`-stdlib keygen fix and the `fl_free` one-arg API change; 1.0.4: **Ed25519 server-cert consumption** — the `tls_native` gap fixed upstream (sigil 3.9.x X.509 parser), plus serve-banner drift guard and clone host-scan hardening).

- **Consume upstream + dependency fixes** as they land (a dep bump + dropping a workaround, no sit-code change). These are filed on the deps' roadmaps — watch their CHANGELOGs:
  - **patra `patra_insert_row_or_ignore` (BYTES write path)** — ✅ **shipped upstream in patra 1.12.6** (sit's request, filed 2026-06-25). Now consumable: bump the patra pin `1.12.4 → 1.12.6` and route `db_object_insert_raw` through the or-ignore insert to **unblock P-11** (`sit add` index upsert without a full rewrite; drops the inner `db_object_has` probe — one B+ tree op per object on clone/push/add instead of two). A no-new-surface `1.x` patch. The STR-column SQL-interpolation guard (`hex_prefix_valid`) is separable and already covered by patra `patra_bind_text` (1.10.3).
  - **sankoch `zlib_decompress_with_ratio_cap`** — ✅ **shipped upstream in sankoch 2.4.5** (sit's request, filed 2026-06-25): a one-call ratio-capped decompress (distinct from the absolute 16 MB ceiling). Consumable via a pin bump `2.4.4 → 2.4.5` + routing the wire/fsck inflate paths through the ratio-capped variant — defense-in-depth against decompression bombs on untrusted objects. A no-new-surface `1.x` patch.
  - **sankoch match-finder / SIMD** — the 2.x match-finder / SIMD work that targets the `add-1MB` `zlib_compress` floor (~140 ms) and moves the v0.6.x scoreboard. *(Already on sankoch's roadmap as deferred — gated on a wire-identical match-finder speedup.)*

**On hold — keep sandhi.** Dropping sandhi for a hand-rolled `net`-direct loopback HTTP/1.0 server (surface minimization) is deliberately *not* on the patch line: a future cyrius change is expected to make `stdlib`/`lib` consumption easier, which changes both the trade-off and the likely implementation. Until that lands, sit keeps consuming sandhi's `sandhi_server_*` surface and we wait.

### Minor line — `1.2.0` onward (new surface, themed)

Each is a self-contained `1.x.0`; the heavier ones earn their own slot. The reflog shipped first (1.1.0) because it de-risks every history-rewrite tool that follows; `.git/` read-mode (the keystone interop capability, requested by thoth) is the next slot.

- **`1.2.0` — `.git/` read-mode** *(heavy; high interop value; promoted from unscheduled).* Read an *existing git repository* (not just sit-native `.sit/`), so sit's `dist/sit.cyr` consumers (thoth's status bar + tool-call diffs, owl's gutter markers) report branch / status / diff on real-world git repos without shelling out to system `git`. Read-only: **SHA-1** object IDs alongside the existing SHA-256 (git's default mode is SHA-1; sit is SHA-256-native), loose-object decode (sankoch zlib — already in hand) + **packfile + `.idx`** decode with delta resolution (shares the sankoch delta primitives the pack-bundles item below needs), and `.git/HEAD` + `.git/refs/` + `packed-refs` parsing. Surfaces through the SAME `sit_repo_open` / `sit_diff_path` / branch+status accessors (storage-agnostic for callers); `.git/` **write-back stays out of scope** — sit stays `.sit/`-native for its own repos. **Dependency:** the packfile/delta half needs sankoch's delta primitives, still pending as of the 1.1.0 cut — so the loose-object + refs half (SHA-1 IDs, `.git/HEAD`/`refs/`/`packed-refs`, zlib loose decode) lands first and packfile decode follows within the minor once the sankoch work is ready. Requested by thoth.
- **`1.3.0` — Annotated & signed tags + ref ergonomics** *(light; high git-parity value).* Annotated tags (a real tag object with tagger + message, not just a lightweight ref); **ed25519-signed tags** (reuse the sitsig machinery from signed commits); `sit mv` (rename in working tree + index); `sit describe` (nearest tag + offset). Completes the tag + signing story; low risk — a good cadence-setter for the minor line.
- **`1.4.0` — History tools** *(medium; reflog-backed).* `sit revert` (inverse commit); `sit cherry-pick` (apply a commit onto HEAD via the existing 3-way merge + `merge-base`); `sit stash` (save / restore the working tree). Safe to ship now that the reflog (1.1.0) makes them recoverable.
- **`1.5.0` — TLS trust hardening** *(medium).* HTTPS **CA-chain + hostname verification** (opt-in: `http.sslVerify` / `http.caBundle`, system store via `tls_native_set_ca_system`; TOFU stays the default); **mTLS** (client certs — `tls_native_new_server` + verify primitives already exist); **non-loopback `sit serve`** (lift the `127.0.0.1` lock, gated on `--tls`, refuse non-loopback plain HTTP); **bearer auth over SSH** (`_ssh_handle_auth_token` stub → real). A cohesive transport-trust minor.
- **`1.6.0` — Wider merge + inspection.** **Octopus / N-way merge** (`cmd_merge` → N branches; `find_merge_base` already walks N parents correctly); **`sit blame`** (per-line last-touch — also a natural `dist/sit.cyr` library export for owl, alongside `sit_diff_path`); **`.sitignore` directory-only (`build/`) enforcement** (closes the last documented git-parity gap).

### Heavier / unscheduled (their own minors when their time comes)

- **`sit rebase`** — the heaviest rewrite tool; depends on the reflog (1.1.0) for safety and shares cherry-pick's apply machinery (1.3.0). A `1.x.0` of its own.
- **Pack bundles + `gc` / repack** — batched, delta-compressed object transfer (a new negotiated wire capability → minor) plus on-disk repacking; both tie to sankoch delta primitives + patra storage-shape work that isn't ready. The delta primitives are shared with **`1.2.0` `.git/` read-mode** (packfile decode) — whichever lands the sankoch delta work first unblocks the other.
- **Hooks** (`pre-commit`, `pre-push`, …) — a `1.x.0` if a consumer asks.

*(`.git/` read-mode was promoted out of this section into [`1.2.0`](#minor-line--110-onward-new-surface-themed) — it's now a scheduled minor right after the reflog.)*

---

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). The v0.6.x performance scoreboard (`add-1MB −48%`, `add-64KB −43%`, `clone −30%`, `log −17%`, `status −9%` from the v0.6.0 baseline) is carried in [`../benchmarks/`](../benchmarks/).*
