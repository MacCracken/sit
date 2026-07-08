# sit Development Roadmap

Forward-looking only. **Shipped history lives in [`CHANGELOG.md`](../../CHANGELOG.md)** (the tagged-release source of truth); the **live state snapshot** (current version, dep pins, source layout, command inventory) lives in [`state.md`](state.md). This file is just what's *next*.

## Shipped

Rolled up here so the forward sections stay uncluttered — full detail per release in [`CHANGELOG.md`](../../CHANGELOG.md).

- **1.0.0** (2026-06-13) — first stable release. Full git-parity surface: local VCS loop + `merge-base`; `fsck` integrity / reachability / `--prune`; ed25519 signing; git-parity `.sitignore`; `log --graph`; shallow clone; network sync over `file://` / `http://` / `https://` (first-party TLS 1.3) / `ssh://`; `dist/sit.cyr` library export. From here the CLI, `.sit/` layout, `/sit/v1/...` wire protocol, and `sit_*` / `ann_*` API are SemVer-governed. Closeout audit: [`../audit/2026-06-13-audit.md`](../audit/2026-06-13-audit.md).
- **1.1.0** (2026-06-25) — **reflog + recovery.** Git-compatible `.sit/logs/` journal; `sit reflog`; `<ref>@{N}` / `HEAD@{N}` resolution (`sit reset --hard HEAD@{1}` undoes a reset); reflog-aware `fsck --prune` grace (reflog-as-roots + 90-day window, `--prune-now` for the legacy sweep). [ADR 0010](../adr/0010-reflog-and-recovery.md) · [arch 005](../architecture/005-reflog-two-line-invariant.md).
- **1.2.0** (2026-07-03) — **`.git/` read-mode.** Reads an existing git repo (SHA-1 + SHA-256) read-only — loose objects + packfiles (`.idx` v2 + a first-party OFS/REF delta interpreter) + refs (`HEAD` / `refs/` / `packed-refs`) — behind the same `sit_repo_open` / `sit_diff_path` public API, plus new `sit_repo_branch` / `sit_repo_status` accessors. So `dist/sit.cyr` consumers (thoth, owl) report branch / status / diff on real-world git repos without shelling out to system `git`. Read-only (no `.git/` write-back — sit stays `.sit/`-native); no FFI (the delta interpreter is self-written). Folds in the cyrius `6.2.44 → 6.3.36` toolchain + dep refresh. [ADR 0011](../adr/0011-git-read-mode.md) (scoping [ADR 0004](../adr/0004-sha256-only.md)).
- **1.3.0** (2026-07-03) — **read-only dist profile (`dist/sit-read.cyr`).** A new `cyrius distlib read` profile (`[lib.read]` in `cyrius.cyml`) emits a lean read-only bundle (8.6k vs 13.5k lines) from just the read path — dropping `sign` + the network stack (`wire` / `wire_http` / `serve`) — so a read-only consumer (thoth's status bar, owl's gutter markers) compiles it with **no shim constants and no wire warnings** (it references none of `HSV_REQ_BUF_SIZE` / `TLS_OK` / `wire_ssh`). Same public `sit_repo_*` API; packaging-only (no source/API change; 273 unit / 58 integration unchanged). The artifact thoth's 0.13.0 git producer consumes. **Took the 1.3.0 slot ahead of the themed minor line below (resequenced +1).**

## SemVer tiers (post-1.0)

- **Patch (`1.x.y`)** — no new *observable* surface: bug fixes, perf, internal refactors, toolchain/dep bumps, consuming upstream fixes. Safe to take blindly.
- **Minor (`1.x.0`)** — new *backward-compatible* surface: a command, flag, config key, public-API symbol, or wire capability.
- **Major (`2.0.0`)** — reserved for a breaking change to the CLI, `.sit/` layout, wire protocol, or public API. None planned.

Nothing below blocks anything else; the ordering is a recommendation, not a contract. Each ships under the usual test / fuzz / bench gates.

## `1.2.x` — patch line + carried follow-ups (no new surface)

Consumption, hardening, and deferred no-surface work. The dep **pins are already current** (bumped in 1.2.0); what remains is the *wiring*.

- **Wire patra `patra_insert_row_or_ignore` (P-11).** Pin is current (patra 1.12.9 ships it). Route `db_object_insert_raw` through the or-ignore insert so `sit add` upserts the index without a full rewrite and drops the inner `db_object_has` probe — one B+ tree op per object on clone / push / add instead of two.
- **Wire sankoch `zlib_decompress_with_ratio_cap`.** Pin is current (sankoch 2.4.9 ships it). Route the wire / fsck inflate paths through the ratio-capped variant — defense-in-depth against decompression bombs on untrusted objects, distinct from the absolute 16 MiB ceiling. (Now also relevant to the `.git/` packfile read path.)
- **Reflog `expire` / `delete` + `@{<date>}` selector** *(carried from 1.1.0).* Reflog entries are unbounded today, so `fsck --prune` reclaims reflogged objects only via `--prune-now`; expiry closes that. `@{<date>}` complements the integer `@{N}` ordinal.
- **Unsanitized-identity hardening in `commit.cyr` / `merge.cyr`** *(carried from 1.1.0; security patch).* The reflog ident chain was hardened in 1.1.0; the commit / merge object-framing ident path is the remaining instance of the same pattern.
- **Nested `.gitignore` / `info/exclude`** for `.git/` read-mode. Only the top-level `.gitignore` is honoured today.
- **sankoch match-finder / SIMD** *(upstream-pending perf).* Targets the `add-1MB` `zlib_compress` floor (~140 ms). On sankoch's roadmap, gated on a wire-identical speedup.

## Minor line — `1.3.0` onward (new surface, themed)

Each is a self-contained `1.x.0`; the heavier ones earn their own slot. **Next: `1.4.0`** (the themed line resequenced +1 after 1.3.0 shipped the read-only dist profile).

- **`1.4.0` — Annotated & signed tags + ref ergonomics** *(light; high git-parity value).* Annotated tags (a real tag object with tagger + message, not just a lightweight ref); **ed25519-signed tags** (reuse the sitsig machinery from signed commits); `sit mv` (rename in working tree + index); `sit describe` (nearest tag + offset). Completes the tag + signing story; low risk — a good cadence-setter for the minor line.
- **`1.5.0` — History tools** *(medium; reflog-backed).* `sit revert` (inverse commit); `sit cherry-pick` (apply a commit onto HEAD via the existing 3-way merge + `merge-base`); `sit stash` (save / restore the working tree). Safe now that the reflog (1.1.0) makes them recoverable.
- **`1.6.0` — TLS trust hardening** *(medium).* HTTPS **CA-chain + hostname verification** (opt-in: `http.sslVerify` / `http.caBundle`, system store via `tls_native_set_ca_system`; TOFU stays the default); **mTLS** (client certs — the `tls_native` verify primitives already exist); **non-loopback `sit serve`** (lift the `127.0.0.1` lock, gated on `--tls`, refuse non-loopback plain HTTP); **bearer auth over SSH** (`_ssh_handle_auth_token` stub → real). A cohesive transport-trust minor.
- **`1.7.0` — Wider merge + inspection.** **Octopus / N-way merge** (`cmd_merge` → N branches; `find_merge_base` already walks N parents correctly); **`sit blame`** (per-line last-touch — also a natural `dist/sit.cyr` library export for owl, alongside `sit_diff_path`); **`.sitignore` directory-only (`build/`) enforcement** (closes the last documented git-parity gap).
- **`.git/` CLI parity** *(new surface; unscheduled).* `sit status` / `log` / `diff` and `@{N}` on git repos — the 1.2.0 *library* API already works on git; the CLI commands stay `.sit`-gated. Needs a shared `_compute_status_records()` in `diff.cyr` so it doesn't back-reference `api.cyr` in single-pass dist order. A `1.x.0` when a consumer wants CLI parity.

## Heavier / unscheduled (their own minors when their time comes)

- **`sit rebase`** — the heaviest rewrite tool; depends on the reflog (1.1.0) for safety and shares cherry-pick's apply machinery (1.5.0). A `1.x.0` of its own.
- **Pack bundles + `gc` / repack** — batched, delta-compressed object transfer (a new negotiated wire capability → minor) plus on-disk repacking. The git-delta *read* interpreter now exists (1.2.0, `src/git_pack.cyr`); what remains is delta *generation* + on-disk repack + the wire capability, tied to patra storage-shape work that isn't ready.
- **Hooks** (`pre-commit`, `pre-push`, …) — a `1.x.0` if a consumer asks.

## On hold — keep sandhi

Dropping sandhi for a hand-rolled `net`-direct loopback HTTP/1.0 server (surface minimization) is deliberately *not* scheduled: a future cyrius change is expected to make `stdlib` / `lib` consumption easier, which changes both the trade-off and the likely implementation. Until that lands, sit keeps consuming sandhi's `sandhi_server_*` surface.

---

*Process, conventions, and the per-release work loop live in [`../../CLAUDE.md`](../../CLAUDE.md). The v0.6.x performance scoreboard (`add-1MB −48%`, `add-64KB −43%`, `clone −30%`, `log −17%`, `status −9%` from the v0.6.0 baseline) is carried in [`../benchmarks/`](../benchmarks/).*
