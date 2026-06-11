# sit Development Roadmap

> **v0.8.x active — release 7 of N shipped.** Line opener and arc summary:
>
> | tag | date | summary |
> |---|---|---|
> | v0.8.0 | 2026-05-12 | toolchain `5.9.37 → 5.11.34` + dep major bumps + CI lint/fuzz |
> | v0.8.1 | 2026-05-13 | `dist/sit.cyr` library export + diff primitive cleanup + ADR 0009 (public-API contract) |
> | v0.8.2 | 2026-05-13 | SSH transport read-only (`ssh://` clone/fetch) + ADR 0008 + CVE-2017-1000117 defense |
> | v0.8.3 | 2026-05-13 | SSH push — `ssh://` round trip complete |
> | v0.8.4 | 2026-05-13 | `denyCurrentBranch` default refuse — first v0.7.6 footgun closed |
> | v0.8.5 | 2026-05-15 | `sit fsck` reachability walk + cyrius `5.11.34 → 5.11.55` — second v0.7.6 footgun closed |
> | v0.8.6 | 2026-06-10 | cyrius `5.11.55 → 6.1.27` major + dep bumps + stdlib reorg (bayan/slice); `tls_native` unblock |
> | v0.8.7 | 2026-06-10 | wire-walker multi-parent fix — third v0.7.6-era footgun closed |
>
> **Slot note:** v0.8.6 shipped as the cyrius 6.x toolchain refresh (not the originally-planned wire-walker fix); the wire-walker fix landed at **v0.8.7**, so `.sitignore` slid to v0.8.8 and `log --graph` / shallow-clone to v0.8.9.
>
> **Next: HTTPS via `tls_native` (now unblocked) or `.sitignore` semantics.** The wire-walker footgun is closed (v0.8.7): `parse_commit_body` exposes every parent via a vec at `out+48`; `walk_reachable_phased` / `is_ancestor` / `is_ancestor_in_db` follow all edges so clone/fetch/push no longer drop merge subgraphs.
>
> **HTTPS / mTLS slots are now UNBLOCKED (as of v0.8.6 / cyrius 6.x).** cyrius 6.x ships [`lib/tls_native.cyr`](../adr/0007-network-transport-security.md) — a sovereign pure-Cyrius TLS 1.3 stack on sigil primitives (ChaCha20-Poly1305 / AES-GCM / HKDF / X25519 / ECDSA / X.509; **no fdlopen, no libssl**; interops with OpenSSL 3.x). This is exactly what [ADR 0007](../adr/0007-network-transport-security.md) required and what `issues/archived/2026-05-13-sandhi-first-party-tls-surface-needed.md` was waiting on — the gate is clear. sit's existing scaffolding (`URL_SCHEME_HTTPS` validator + `wire_transport_check_*` dispatch, v0.7.1) is ready; wiring `tls_native` into `wire_http.cyr` (client) + `serve.cyr` (server) is the work. Known caveats in `tls_native`: `set_alpn` / `set_version_range` return `NOT_IMPLEMENTED` (irrelevant — sit speaks HTTP/1.0, no ALPN), TLS 1.2 backport in progress (irrelevant — both ends are sit, 1.3-only is fine).
>
> The v0.6.x perf arc remains the cumulative scoreboard against `add-1MB -48%`, `add-64KB -43%`, `clone -30%`, `log -17%`, `status -9%` from v0.6.0 baseline; v0.8.x releases haven't moved that scoreboard.

Historical per-sub-version notes were collapsed into the 0.4.0 entry; see [`CHANGELOG.md`](../../CHANGELOG.md) for the tagged artifacts.

## Released

### v0.8.7 — Wire-walker multi-parent fix

- **Closes the third v0.7.6-era footgun** (surfaced during v0.8.5's fsck work). `parse_commit_body` captured only the *last* `parent` header, so the three commit-graph traversals that consumed `out+8` followed just one edge per merge commit. Cloning / fetching / pushing a merge-bearing repo silently dropped every object reachable only through a non-last parent — and the incomplete clone still passed `sit fsck` ("0 dangling").
- **Reproduced + verified**: a 3-commit + merge fixture. Pre-fix clone = **9 objects** (dropped the first-parent commit + its tree); fixed clone = **11 objects** (complete, both merge parents resolve). The pre-fix clone's `sit fsck` reported "0 dangling" while missing data — the dangerous part.
- **`parse_commit_body` (`src/commit.cyr`)** now collects every `parent` line into a vec at the previously-unused struct slot `out+48` (body order). `out+8` is unchanged (last parent) so single-parent-chain readers — `cmd_log`, `merge_base` — are byte-identical; only the traversals switch to the vec.
- **`walk_reachable_phased` (`src/wire.cyr`)** — the clone/fetch/push enumerator — and **`is_ancestor_in_db` (`src/wire.cyr`)** — the server/push FF gate — enqueue all parents from `out+48`.
- **`is_ancestor` (`src/commit.cyr`)** rewritten from a naive single-parent chain into a full-DAG BFS (queue + seen-set) enqueuing all parents; a first-parent-only walk would falsely report "not an ancestor" across a merge.
- **Test**: `tests/sit.tcyr` multi-parent group (merge → both parents in order, single → one, root → none, plus the `out+8` back-compat invariant). File now `include`s `src/lib.cyr` to reach `parse_commit_body`. **138 assertions** (was 127). Lint/fuzz green; DCE binary **2.12 MB** (+672 B vs v0.8.6).
- **Out of scope (tracked):** `merge_base` (`src/merge.cyr`) and `cmd_log` still walk the single `out+8` chain. For `cmd_log` that's intended; for `merge_base` it's a latent LCA limitation (correct across diamond/octopus merges wants a full DAG walk) — queued, not slotted.

### v0.8.6 — cyrius 6.1.27 toolchain refresh + dep bumps + stdlib reorg

- **Major toolchain line bump.** cyrius `5.11.55 → 6.1.27` (6.x major). No sit source changes — the work was absorbing the cyrius 6.x stdlib reorganization in `cyrius.cyml`. **Originally slotted as the wire-walker fix**; shipped as the toolchain refresh instead, pushing wire-walker to v0.8.7.
- **Dep bumps**: sakshi `2.2.4 → 2.2.10`, sankoch `2.2.5 → 2.3.0`, sigil `3.1.1 → 3.7.8`, patra `1.9.4 → 1.11.0`. sit's consumed surface unchanged; signed-commit verify confirmed end-to-end against sigil 3.7.8.
- **Stdlib list reorg.** `bigint` / `base64` / `json` removed — cyrius 6.x folded all three into the **`bayan`** omnibus bundle (functions gained a `bayan_` prefix; back-compat aliases keep sigil's `u256_*` working). Added **`slice`** — cyrius 6.x's `agnosys` module requires it. `async` deliberately omitted: sandhi 1.4.10's `sandhi_server_run_async` references it, but sit's `cmd_serve` uses the synchronous `sandhi_server_run`, and adding `async` overflows the 256-global cap (hard build fail) — so the four `undefined function 'async_*'` warnings are accepted as benign DCE-stripped dead-code refs.
- **`tls_native` unblock** (noted, not consumed): cyrius 6.x ships `lib/tls_native.cyr`, sovereign pure-Cyrius TLS 1.3 — clears ADR 0007's HTTPS gate. See the "Blocked → now unblocked" note in the header.
- **DCE binary 2.12 MB** (up from 1.39 MB at v0.8.5 — cyrius 6.x stdlib/sandhi heft). 127/127 tests; lint/fuzz green. **Shipped undocumented** (tag changed only `VERSION` + `cyrius.cyml` + `dist/sit.cyr`); recorded retroactively during v0.8.7 prep.

### v0.8.5 — `sit fsck` reachability walk + cyrius 5.11.55 toolchain refresh

- **Closes the second v0.7.6 footgun.** `sit fsck` previously only flagged objects whose stored bytes didn't sigil-rehash to their key. v0.8.5 adds a reachability pass that surfaces objects no ref / index entry points at. Output gains a third counter + per-object dangling lines (git-shaped):

  ```
  $ sit fsck
  dangling tree 497a926fc6e399...
  dangling commit a870bbd76ced31...
  checked 6 objects, 0 bad, 2 dangling
  ```

- **Walker** (`fsck_walk_reachable` in `src/object_db.cyr`) is BFS over the object graph. Classifies by framing prefix (`commit `/`tree `/`blob `), enqueues every referenced hex: trees push every entry hash from `parse_tree` + `tree_entry_hash`; commits push the `tree` line + **every** `parent` line via the new `fsck_collect_commit_parents`. The multi-parent collector is distinct from `parse_commit_body`, which captures only the last parent header — a pre-existing limitation that `walk_reachable_phased` inherits but fsck explicitly does not (queued separately as v0.8.6 work).

- **Roots** (`fsck_collect_roots`) cover `.sit/refs/heads/<*>` + `.sit/refs/tags/<*>` + `.sit/refs/remotes/<*>/<*>` (via `dir_walk` — recurses into the per-remote namespaces automatically) + `.sit/HEAD` when detached (raw hex, not symbolic). Symbolic HEADs are skipped because the matching ref file is already a root. Every `parse_index()` entry contributes its blob hex as a root via `hex_encode(entry_hash(e), 32)` — without this, every `sit add` not yet committed would look dangling.

- **Dangling does not fail the command.** Matches git's policy: integrity errors set non-zero exit; dangling objects are normal after resets, rewinds, or aborted merges. The exit code is governed solely by `bad > 0`. Existing CI assertions of the form `grep -q "0 bad"` keep matching because the substring is preserved verbatim in the new output shape `checked N objects, M bad, D dangling`.

- **Integrity SELECT widened** from `SELECT hash FROM objects` to `SELECT hash, ty FROM objects` so the dangling pass can emit `dangling <blob|tree|commit> <hex>` without a second read per dangling object. The `ty_map` (cstr-hex → ty + 1; the +1 keeps `map_get`'s 0 sentinel distinct from `ty == 0` blobs) is consulted only on the dangling pass.

- **Toolchain bump** `5.11.34 → 5.11.55` (21 patches; binaries byte-identical to 5.11.54, so the bump is mostly a tag-line refresh). One known upstream wart: bundled `lib/sandhi.cyr` calls retired `hashmap_*` symbols (renamed to `map_*` in 5.11.x stdlib). The four "undefined function" warnings during build / test / fuzz are TLS session-cache code (sandhi 1.3.4) that sit doesn't reach — DCE strips them and the binary is clean.

- **CI smoke step** `Smoke — fsck reachability (v0.8.5)`: 2-commit linear history → assert `0 bad, 0 dangling`; rewind `main` to root → assert `0 bad, 2 dangling` (commit + tree) plus `^dangling commit ` / `^dangling tree ` lines; merge commit (base → feature + main → merge) + `rm .sit/refs/heads/feature` → assert `0 bad, 0 dangling` (proves both-parent walk; if the walker fell back to parse_commit_body's single-parent capture, the on-main commit + its tree would appear dangling).

- **Build / test / lint / fuzz green.** DCE binary **1.39 MB** (+30 KB vs v0.8.4). 127/127 tests pass. Lint clean (one pre-existing `ERR_BUFFER_TOO_SMALL` enum reference at `src/object_db.cyr:122` predates this release). Known-footgun list (in `docs/development/state.md`) has its second item closed.

### v0.8.4 — `denyCurrentBranch` default refuse + HTTPS/mTLS slots blocked upstream

- **Closes the v0.7.6 documented footgun.** `sit push` used to silently advance a remote's `refs/heads/<branch>` while leaving its working tree stale. v0.8.4 refuses by default — all three transports (file://, http://, ssh://) check whether the target ref is the remote's checked-out HEAD; if yes AND the ref already exists, refuse. Initial pushes to empty remotes still succeed (matches git's `denyCurrentBranch=refuse` default).
- **Server-side check** in `serve_handle_put_ref`: read `read_head_ref_path()`, compare against incoming refname, return `423 Locked` with body `"refusing to update checked-out branch (denyCurrentBranch)"` if matched + ref exists. 423 distinguishes denyCurrentBranch from 409 Conflict (non-FF) on the wire.
- **Client-side surface**: `http_remote_push_ref` / `ssh_remote_push_ref` gained a third return code (`2 = 423 denyCurrentBranch`); `_do_push_http` / `_do_push_ssh` surface a distinct user-visible message rather than the misleading "non-fast-forward". `_remote_current_branch(repo_path)` helper added to `src/wire.cyr` so file:// push enforces the same gate without crossing the wire.
- **CI smoke step** in the SSH block: separate fixture with HEAD attached to main + an initial commit; clone, second commit, push — assert REJECTED with denyCurrentBranch message + origin's ref unchanged. Then detach HEAD on origin, assert push succeeds. Plus all three existing smoke steps (file:// wire, ssh://, http push) detach ORIG's HEAD right after setup so prior push-to-main assertions keep working (a real server-shaped remote is bare or has a non-current branch checked out anyway).
- **Cross-repo issue filed** at [`issues/archived/2026-05-13-sandhi-first-party-tls-surface-needed.md`](issues/archived/2026-05-13-sandhi-first-party-tls-surface-needed.md). v0.8.4 prep verified that sandhi's `tls_policy/` wraps libssl-via-fdlopen (per sandhi v1.2.0 release notes: *"lib/tls.cyr stays libssl.so.3-bridged per the 2026-04-24 pure-Cyrius-TLS removal"*); ADR 0007 forbids sit from consuming. HTTPS (was v0.8.4) and mTLS (was v0.8.5) re-slotted to "Blocked on upstream sandhi / cyrius work" section; v0.8.x slot table promotes `denyCurrentBranch` / `fsck` reachability / `.sitignore` / `log --graph` / shallow-clone into numbered slots.
- **Build / test / lint / fuzz green.** DCE binary stays at **1.36 MB**. Known-footgun list (in `docs/development/state.md`) has its first item closed.

### v0.8.3 — Push over SSH

- **Closes the v0.8.2 read-only gap.** `sit push origin main` works over `ssh://` URLs end-to-end. Pipeline mirrors v0.7.6 HTTP push (capabilities probe → FF preflight → walk reachable → per-object POST → ref POST → up-to-date short-circuit), layered onto v0.8.2's persistent SSH stdio session — one ssh handshake per push, many HTTP/1.1 requests through the same SSH-encrypted pipe.
- **Transport-agnostic server.** Server-side `POST /sit/v1/objects/<hex>` (sigil rehash-verify before insert) and `POST /sit/v1/refs/<refname>` (FF gate via `is_ancestor_in_db`) both shipped in v0.7.6 — they consume `buf+n` the same way over a TCP socket or the stdio pipe, so v0.8.3 is purely client-side wire-up.
- **New surface in `src/wire_ssh.cyr`** (~120 lines net): `_wire_ssh_post_xhdr(h, sub_path, body, body_len, extra_hdr, out_body)` (POST with arbitrary extra header — used for `X-Sit-Type`), `_wire_ssh_recv_response(rfd, out_body)` (response-parse extracted from `_wire_ssh_request` so GET + POST share it), `ssh_remote_push_object(h, hex, ty, compressed, clen)`, `ssh_remote_push_ref(h, refname, hex)`, `_ssh_handle_auth_token(h)` stub.
- **`_do_push_ssh`** in `src/wire.cyr` (~115 lines net): full pipeline mirroring `_do_push_http`. `cmd_push` URL-scheme dispatch gains a third arm (`URL_SCHEME_SSH` → `_do_push_ssh`); `wire_transport_check_writable` accepts ssh now (the v0.8.2 placeholder error is gone).
- **Bearer auth over SSH** skipped in v0.8.3 — SSH already authenticates end-to-end via key exchange + authorized_keys, so a server-side `--require-auth` token on top is redundant for the canonical use case. `_ssh_handle_auth_token` is a 0-returning stub; `_wire_ssh_post_xhdr` skips the Authorization header when the handle has no token. A v0.8.3.x patch can wire belt-and-suspenders auth by flipping the accessor — no caller-side change needed.
- **CI smoke step** extended past the v0.8.2 clone + CVE assertions: full ssh push round trip (clone → second commit → push → assert origin advances), re-push asserting `"everything up-to-date"`, non-FF rejection (rewind clone to parent + divergent commit + push must fail with the non-fast-forward error and leave origin's ref intact).
- **Build / test / lint / fuzz green.** DCE binary stays at **1.36 MB** — DCE strips the unused Authorization-injection branch in `_wire_ssh_post_xhdr` since `_ssh_handle_auth_token` returns 0.

### v0.8.2 — SSH transport (`ssh://`), read-only

- **Closes ADR 0007's encrypted-over-internet read-side gap** without breaking the no-FFI thesis. `sit clone ssh://user@host/path/to/repo` works end-to-end via fork+exec on the system's `ssh` binary; SSH owns the crypto + auth handshake; sit's wire is the same HTTP/1.1 it speaks over TCP, riding the SSH-managed stdin/stdout pipes. No libssh-link, no FFI hole. Matches git's `ssh://` shape.
- **[ADR 0008](../adr/0008-ssh-transport.md)** pins the architecture (process boundary, not FFI), the CVE-2017-1000117 three-layer defense, the curated-env rationale, and the four rejected alternatives (libssh2 link, native Cyrius SSH, libssh-via-fdlopen, no-SSH-wait-for-HTTPS).
- **Server: `sit serve --stdio`** mode. Reads HTTP/1.1 requests from STDIN, writes responses to STDOUT, no TCP socket. Pipelining-safe via `_stdio_recv_request` — preserves carryover bytes between requests. Reuses `sandhi_server_recv_request` / `_send_response` directly since `sock_send` / `sock_recv` are just `sys_write` / `sys_read`.
- **Client: `src/wire_ssh.cyr`** (~530 lines). `_ssh_parse_url` (CVE defense), `_ssh_find_binary` ($PATH walk — `sys_execve` doesn't do PATH lookup), `_ssh_push_env` (curates HOME / USER / LOGNAME / SSH_AUTH_SOCK / TERM / PATH; no full-env inheritance), `wire_ssh_open` (pipe×2 + fork + raw `sys_execve` + capabilities probe), `wire_ssh_close` (close + waitpid), `_wire_ssh_request` (build + send HTTP/1.1 GET, recv until Content-Length satisfied), `_wire_ssh_parse_content_length`, `ssh_remote_read_refs`, `ssh_remote_resolve_branch`, `ssh_remote_read_raw`, `ssh_remote_read_both`.
- **`obj_src` extension.** `OBJ_SRC_SSH = 2` tag + `obj_src_for_ssh(handle)`; `obj_src_read_raw` / `_read_both` dispatch to the SSH path. `walk_reachable_*` / `copy_objects` are unchanged — transport-agnostic since v0.7.3.
- **CVE-2017-1000117 three-layer defense.** (1) `remote_url_valid` URL-body whitelist; (2) `_ssh_parse_url` explicit leading-dash rejection on user / host / first-path-segment; (3) `--` argv sentinel + `sys_execve` (no shell interpolation). 100K-round fuzz against `_ssh_parse_url` clean.
- **CI sshd-loopback smoke step.** Stands up `sshd` on `127.0.0.1:22422` with a passphrase-less ed25519 key, exposes the build's `sit` at `/usr/local/bin/sit`, runs `sit clone ssh://sit-test<repo-path>`, asserts content + fsck. Also asserts `sit clone ssh://-oProxyCommand=touch+/tmp/PWNED/host/repo` fails before any exec and `/tmp/PWNED` is never created.
- **Build / test / lint / fuzz green.** DCE binary **1.36 MB** x86_64 (+60 KB from v0.8.1's 1.30 MB; growth concentrated in `wire_ssh.cyr` + `_serve_run_stdio`).
- **Push over SSH** still gated — `wire_transport_check_writable` rejects `ssh://` with `"push over ssh requires sit 0.8.3+ (read-only ssh is available now)"`. v0.8.3 mirrors the v0.7.6 HTTP push pipeline onto the persistent stdio session.

### v0.8.1 — Library export (`dist/sit.cyr`) + diff primitive cleanup (owl-blocker resolved)

- **Library export.** New `[lib].modules` block in `cyrius.cyml` drives `cyrius distlib`; generated `dist/sit.cyr` (9,765 lines) is tracked in-repo per the sandhi / cyim convention. Downstream pin shape: `[deps.sit] git = "..." tag = "0.8.1" modules = ["dist/sit.cyr"]`.
- **Public API surface in `src/api.cyr`** (93 lines, all `sit_*`-prefixed): `sit_repo_open(cwd)` (chdir + verify `.sit/HEAD`, returns 1/0), `sit_repo_close(repo)` (no-op in v0.8.1, reserved for forward compat), `sit_diff_path(repo, path)` (HEAD-blob vs working-tree → annotated-ops vec; handles add-only / delete-only / both-present uniformly via empty-buffer convention). The existing `ann_kind` / `ann_line` / `ann_old` / `ann_new` accessors in `src/diff.cyr` become part of the same stable surface.
- **[ADR 0009](../adr/0009-public-api-contract.md) — Public API contract.** `sit_*` / `ann_*` identifiers are stable and SemVer-governed; rename / remove / arity-change is a major bump, new public fns are minor, internal `_`-prefixed refactors are patch. Pre-1.0 caveat: sit commits to the contract _as if_ post-1.0; breaking changes flagged in CHANGELOG's **Breaking** section. Operational gate: every release diff `dist/sit.cyr` against the prior tag and filter `^[+-]fn (sit_|ann_)`.
- **Diff primitive cleanup.** Two correctness gaps owl surfaced:
  - **`-U<N>` threading**: `cmd_diff` and `cmd_show` now parse `-U<N>` and thread `ctx` through `print_file_diff` → `group_hunks` (was hardcoded to 3). 13 `print_file_diff` callers updated to pass the new trailing `ctx` arg. Default stays at 3 to match prior behavior; matches `git diff -U<N>` / `git show -U<N>` byte-shape.
  - **`compute_file_diff` extracted**: pure-compute layer (no I/O) factored out of `print_file_diff`; the print path now calls compute + emits stdout. Consumers (`sit_diff_path` first) can ask for ops without paying for stringification.
- **CI guards.** New `Verify dist/sit.cyr is in sync` step (asserts `cyrius distlib` is idempotent vs the tracked bundle; asserts the public symbols `sit_repo_open` / `sit_repo_close` / `sit_diff_path` / `compute_file_diff` / `ann_kind` / `ann_line` / `ann_old` / `ann_new` are present so the `[lib]` block can't silently drop a module). New `Smoke — diff -U<N> context width` step (asserts U0 / U1 / default-3 hunk-header byte-shape against the canonical unified-diff layout).
- **One source change** outside the new module: `src/config.cyr:176` consecutive blank lines collapsed (pre-existing lint warning).
- **Build / tests / lint / fuzz green.** DCE binary stays at **1.30 MB** (sit_repo_close / sit_diff_path strip in main builds — DCE doesn't reach them since `main()` doesn't call them; they're for library consumers).
- **Downstream impact.** owl can drop the `execve("git", "diff", "-U0", "--", path)` shell-out in `src/vcs.cyr` for a `sit_diff_path` library call returning the same annotated-ops shape. owl pin: `[deps.sit] tag = "0.8.1" modules = ["dist/sit.cyr"]`.

### v0.8.0 — Line opener: cyrius 5.11.34 toolchain refresh + dep major bumps + CI lint/fuzz

- **Minor-line opener.** Toolchain + dep refresh + small CI / repo-hygiene wins; no new feature work. v0.7.x ended at v0.7.6 ahead of the originally-slotted v0.7.7 (`dist/sit.cyr` library export + diff-primitive cleanup) and v0.7.8 (SSH) — both moved into the v0.8.x slot table.
- **Cyrius 5.9.37 → 5.11.34.** Spans 100+ patches. Load-bearing pickups: **v5.10.x SLOT 19** transitive `[deps]` include; **v5.11.33** `PP_IFDEF_PASS` cap raise 2 MB → 8 MB (filed by sit at 2026-05-12 ([cyrius issue](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/archived/2026-05-12-pp-2mb-cap-blocks-sit-on-sandhi-fold.md)); fix shipped same day — sandhi-fold accretion to 11,729 lines via TLS 1.3 0-RTT + HTTP/2 + RPC + retry + SSE pushed sit's expanded source 2,441 bytes over the prior 2 MB cap). v5.11.29 / .30 / .31 / .32 / .34 are the ELF section-header table fixes (`e_shoff = 0` on every emitter path now closed; `readelf -S` / `objdump -d` / IDE indexers see real section info on every sit binary).
- **Dep major bumps.** sakshi `2.1.0 → 2.2.4`, sankoch `2.1.0 → 2.2.5`, sigil `2.9.3 → 3.1.1` (**major** — `ct_eq` retired in favor of cyrius stdlib `ct_eq_bytes_lens`; `TRUST_COMMUNITY` enum slot 2 retired; `-D SIGIL_BATCH_PARALLEL` flag retired; **audit clean** since sit calls `hash_data` / `hex_*` / ed25519 verbs only), patra `1.8.3 → 1.9.4`.
- **Stdlib list grew.** Added `base64` / `mmap` / `dynlib` / `fdlopen` for sandhi's TLS 1.3 0-RTT path (sandhi v1.3.2+ references `TLS_EARLY_DATA_*` constants + `fdlopen_*` verbs that cyrius v5.10.x SLOT 19's transitive resolution doesn't reach through enum / constant references). `bigint` / `ct` / `keccak` kept explicit for sigil 3.x's crypto primitives (`u256_*`, `ct_eq_bytes_lens`, `_keccak_*`, `shake256`) — same transitive-follow-through gap.
- **Repo hygiene.** `lib/` + `src/lib/` + `cyrius.lock` added to `.gitignore`; 40 stale `lib/*.cyr` files + `cyrius.lock` untracked via `git rm --cached`. Mirrors the sandhi / cyim convention — `lib/` is a build artifact populated by `cyrius update` (stdlib snapshot) + `cyrius deps` (`[deps.X]` git crates); `src/lib/` is a compiler scratch directory cc5 5.11.x creates adjacent to the entry point.
- **CI modernization.** `.github/workflows/ci.yml` gains `Lint` step (per-file `cyrius lint`; 120-char divider tolerance whitelisted; hard-fails on any other warning — cyim shape) and `Fuzz` step (`cyrius run tests/sit.fcyr`; bounded harnesses for sigil hash_data / sankoch zlib_decompress / hex_decode / URL validators / `want_frame_decoder`; ~60s total). CI install step on both `ci.yml` and `release.yml` now creates `$HOME/.cyrius/versions/$CYRIUS_VERSION/lib/` alongside `$HOME/.cyrius/lib/` — cyrius 5.11.x's version-pinned stdlib resolution path needs the former. "Resolve dependencies" step now runs `cyrius update` (stdlib → `./lib/`) before `cyrius deps` (`[deps.X]` git crates → `./lib/`); `cyrius deps` alone doesn't pull stdlib.
- **One source change.** `src/config.cyr:176` consecutive blank lines collapsed (single lint warning surfaced by adding the lint CI step).
- **Build / test / lint / fuzz green.** DCE binary **1.30 MB** x86_64, flat from v0.7.6 (no source-level adds). file:// wire smoke clean.
- **Sandhi first-party Cyrius TLS arc shipped** (sandhi v1.3.2+, `src/tls_policy/`, TLS 1.3 0-RTT). Sit's ADR 0007 "blocked on first-party Cyrius TLS *existing*" backlog (HTTPS, mTLS) is **unblocked**; slots into v0.8.x — see "v0.8.x slot table" below.
- **Issue filed + archived (cross-repo).** [`cyrius/.../archived/2026-05-12-pp-2mb-cap-blocks-sit-on-sandhi-fold.md`](https://github.com/MacCracken/cyrius/blob/main/docs/development/issues/archived/2026-05-12-pp-2mb-cap-blocks-sit-on-sandhi-fold.md) — RESOLVED in cyrius v5.11.33.

### v0.7.6 — HTTP push + bearer auth + ADR 0007 (no libssl, ever)

- **Closes the symmetric round trip over HTTP.** `sit push origin main` works end-to-end against `sit serve` over `http://...`. Server-side `POST /sit/v1/objects/<hex>` rehashes every uploaded object (sigil's `hash_data` over the full `<type> <len>\0<content>` frame) and refuses on hex mismatch — the trust boundary for client→server data. `POST /sit/v1/refs/<refname>` fast-forward gates `refs/heads/*`, treats `refs/tags/*` as immutable (any non-equal update = 409 Conflict), refuses `refs/remotes/*` always.
- **[ADR 0007](../adr/0007-network-transport-security.md) is the load-bearing decision.** Sit's no-FFI thesis is non-negotiable. The `lib/tls.cyr` path (libssl.so.3 via fdlopen) punches the same FFI hole [ADR 0001](../adr/0001-no-ffi-first-party-only.md) explicitly forbids. Five alternatives considered + rejected; HTTPS via libssl is not on the v0.7.x roadmap and won't ship until first-party Cyrius TLS exists. SSH is the canonical encrypted-over-internet transport (sit consumes the SSH binary as a process boundary, not an FFI dep — same separation as git's ssh:// support).
- **Bearer auth** via `~/.sit/serve.token` (0600). `--require-auth` flag in `cmd_serve`; `_serve_load_token` enforces strict 0600 perms + ≥16 chars + no control bytes + refuses to start on any failure (auth posture is "strictly enforced or absent," never silent fall-through). `_serve_auth_ok` does constant-time compare across `max(presented_len, token_len)` so timing doesn't leak prefix matches. Capabilities advertise `"auth":["bearer"]` when `--require-auth`, `"auth":["none"]` otherwise; `"push":true` always. Read endpoints stay anonymous in both modes.
- **Client side**: `cmd_push` branches on URL scheme. `_do_push_http` runs the full pipeline — capabilities probe → optional `~/.sit/serve.token` load → FF preflight via `http_remote_resolve_branch` → `walk_reachable_phased` → per-object `http_remote_push_object` → `http_remote_push_ref`. "everything up-to-date" short-circuit when `remote_tip == local_tip`. Counts only fresh inserts (201) in the summary, not idempotent already-present (200). Helpful error when client missing token but server requires bearer.
- **CI smoke step** generates a 0600 token, asserts capabilities advertise bearer, asserts 401 on no-auth POST, runs full push + verify, asserts "everything up-to-date" on re-push, asserts anonymous clone still works against the auth-required server, asserts client without token fails with the documented error message.
- **127/127 tests pass.** Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`. DCE binary: **1.30 MB** x86_64, 1.43 MB aarch64. file:// wire smoke (clone + push + re-clone) clean — no regression. End-to-end smoke verified all four bearer auth cases (capabilities advertise correctly, 401 without auth, 401 with wrong token, success with right token) plus the anonymous-read-against-auth-required-server case and the client-without-token error path.
- **Roadmap impact**: mTLS (was v0.7.7) and HTTPS (was v0.7.6) dropped from the v0.7.x slot table — both blocked on first-party Cyrius TLS that doesn't exist. SSH (was v0.7.8) moves up to v0.7.7 as the v0.7.x line's encrypted-over-internet path; v0.7.x ends at SSH.
- **No issue archived this release.**

### v0.7.5 — Walk-side phasing + cache-aware tree walk + frame-decoder fuzz

- **Realises the v0.7.4 protocol scaffolding into actual clone speedup.** `walk_reachable_phased` replaces the sequential `walk_reachable_from_commit` (which is now deleted along with `walk_reachable_tree`, ~95 lines of dead code). Three phases: phase 1 walks the commit chain sequentially collecting (commit_hex, tree_hex) pairs; phase 2 batch-prefetches every tree hex via `POST /sit/v1/want` (one POST per `WIRE_HTTP_BATCH_CHUNK = 256` chunk); phase 3 walks each tree from `raw_cache` via the new cache-aware `walk_reachable_tree_batched`. Per-level sub-tree batching for nested directories. `obj_src_batch_prefetch` re-enabled in `copy_objects` (held in v0.7.4). For OBJ_SRC_DB the batch hooks are no-ops so file:// is unchanged.
- **`_decompress_raw_into(raw, deco_out)`** extracted from `db_object_read_both`. Cache-aware tree walker checks `raw_cache` first; on hit, decompresses cached compressed bytes directly without going back to the transport — **the load-bearing fix that turned the phasing from a regression (220 ms with batch on but cache unconsulted) into a real win (185 ms with cache-first)**. Without this, phase 2's batch-prefetch was pure overhead because phase 3's `obj_src_read_both` re-fetched every tree it had just batched.
- **Frame-decoder fuzz target** in `tests/sit.fcyr` — `_wire_http_decode_frames` extracted from `http_remote_read_batch` so the harness drives the parser without a TCP socket. **10,000,000 iterations clean** through pseudo-random bytes (~46 s on the bench host) — no crashes, OOB reads, infinite loops, or oversized allocs. Validation invariants documented in the function's doc-comment: header fits, hex passes `hex_prefix_valid`, `0 ≤ ty ≤ 2`, `0 < clen ≤ 16 MiB`, `off + 80 + clen ≤ blen`. Fuzz harness now `include "src/lib.cyr"` (DCE strips everything not reached from `main`).
- **Bench (100-commit / 100-file fixture, 10 runs each, median)**: v0.7.4 baseline 213 ms → v0.7.5 phased + cache-aware **185 ms (−13%)** on loopback. Per-RT cost extracted from the bench: 0.14 ms/RT (28 ms saved by replacing 198 round trips). Loopback is structurally too fast for batching to dominate — per-frame allocation + parsing overhead is comparable to per-RT cost. The gate was set at realistic RTT, not loopback:

  | RTT | v0.7.4 ms | v0.7.5 ms | Speedup | Gate? |
  |----:|---:|---:|---:|:--:|
  | 0.14 ms (loopback measured) | 213 | 185 | 13% | ✗ |
  | 0.5 ms (very fast LAN) | 321 | 222 | 31% | ✓ |
  | 1 ms (typical LAN) | 471 | 273 | **42%** | ✓ |
  | 2 ms (home / cable) | 771 | 375 | 51% | ✓ |
  | 5 ms (regional internet) | 1668 | 680 | 59% | ✓ |

  Projection methodology: each variant has a fixed per-RT count (300 for v0.7.4, 102 for v0.7.5 = 100 commit GETs + 1 cap probe + 1 tree POST + 1 blob POST). Above-loopback RTT contributes (RTT − 0.14) ms × per-RT count to the wall clock; everything else (patra inserts ~90 ms, decompression ~30 ms, file materialization, etc.) stays constant.
- **127/127 tests pass.** file:// wire smoke (clone + push + re-clone) clean, no regression vs v0.7.4. aarch64 cross-build clean (1.41 MB ELF). DCE binary: **1.29 MB** (essentially flat from v0.7.4's 1.28 MB — phased walker code now live, replaces ~95 deleted lines).
- **No issue archived this release.**

### v0.7.4 — `POST /sit/v1/want` protocol scaffold (no perf change)

- **Wire-protocol scaffolding release.** Server endpoint `POST /sit/v1/want` lights up in `serve_handle_want` (`src/serve.cyr`): fixed-shape request body validation (`[8B count][count*64 hex]`), `SIT_WANT_MAX_COUNT = 512` cap (binding constraint is sandhi's `HSV_REQ_BUF_SIZE = 64 KiB` request buffer), `hex_prefix_valid` pre-pass on every requested hash, growing fl_alloc response buffer with per-frame emission per ADR 0006. Status mapping: 200 happy / 400 length-or-hex mismatch / 411 missing Content-Length / 413 over `SIT_WANT_MAX_COUNT` or `SIT_SERVE_MAX_BODY` / 500 DB or OOM. Capabilities now advertise `"batch":true,"batch_max":512`.
- **[ADR 0006](../adr/0006-batched-want-frame-format.md)** pins the wire format. Request: `[8B i64 LE count][count × 64 ASCII hex hashes]`. Response: concatenated frames `[64 hex][8B i64 LE ty][8B i64 LE clen][clen bytes compressed]`. LE because cyrius is x86_64/aarch64 first and patra stores LE on disk — no per-read byteswaps. Hashes the server doesn't have are silently omitted from the response; clients detect via short-count and demote to per-object GET fallback. Trust boundary unchanged from v0.7.3 — server doesn't recompress, client doesn't re-hash, `sit fsck` is the canonical roundtrip.
- **Client primitives in `src/wire_http.cyr`** (`_wire_http_post`, `http_remote_check_batch`, `http_remote_read_batch`) and the `obj_src_batch_prefetch` dispatcher in `src/wire.cyr` exist in source but are intentionally **not called from `copy_objects`** — DCE-stripped because the integration is held for v0.7.5+. Handle layout extended 16 → 32 bytes (adds `batch_probed` + `batch_supported` fields) so the cap probe runs once per fetch when v0.7.5 plumbs it in.
- **Why no perf change in v0.7.4.** With the batch wired into `copy_objects`, the measured speedup on the 100-commit / 100-file loopback fixture was **7%** (213 → 198 ms median, 10 runs). The blob batch saves ~15 ms; the remaining 198 ms is dominated by the walk's 200 sequential GETs for commits + trees (~30 ms total at ~0.15 ms/loopback-RT) and patra's batched-but-still-load-bearing object inserts (~90 ms — the v0.6.5 transaction-wrap floor). Per the v0.7.4 ≥30%-or-revert gate, the perf-affecting integration is held; the wire surface ships as scaffolding so v0.7.5 can extend without re-doing wire work. The real-network picture is different — at 1 ms RTT, replacing 99 GETs with 1 POST saves ~99 ms, comfortably exceeding 30%; loopback understates the win, and v0.7.5 will measure with realistic latency.
- **Smoke verified end-to-end.** `curl -X POST /sit/v1/want` round trips: 200 happy path with full frame body; 411 on zero-length body; 400 on count/length mismatch; 400 on non-hex hash; 413 on count > 512. Per-object http clone unchanged from v0.7.3 (213 ms median, `sit fsck` 300/300 clean, log byte-identical to file:// clone).
- **127/127 tests pass.** Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`. DCE binary: **1.28 MB** (slightly smaller than v0.7.3's 1.30 MB because more of the v0.7.4 code is currently DCE-stripped scaffolding than v0.7.3 added in live functions).
- **No issue archived this release.**

### v0.7.3 — HTTP client transport (fetch + clone over `http://`)

- **Closes the v0.7.x server/client read-only round trip.** `GET /sit/v1/objects/<hash>` lights up on the server side (raw compressed bytes, `X-Sit-Type: <patra-ty>` response header, 400/404/413 status mapping that doesn't leak miss-vs-error). `src/wire_http.cyr` (530 lines) lights up on the client side (sit-side HTTP/1.0 built directly on `lib/net.cyr` to dodge stdlib `http_get`'s 64 KiB recv cap; growing fl_alloc-backed recv buffer up to 16 MiB matching `db_object_read_both`'s decompression ceiling). `wire_transport_check_readable` (file + http) and `wire_transport_check_writable` (file only — push over http is v0.7.5+) replace the v0.7.1 single-shape check.
- **`obj_src` abstraction** in `src/wire.cyr` — 16-byte tagged handle (`OBJ_SRC_DB` / `OBJ_SRC_HTTP` + payload pointer); `walk_reachable_*` and `copy_objects` now run unchanged over either transport. The roadmap's "HTTP-backed `db_object_read_both` shim" lands as `obj_src_read_both` dispatching into either the patra reader or the http one. The walk-cache (P-04, v0.6.7) is transport-independent and benefits HTTP fetches identically.
- **`do_fetch`** branches on URL scheme: file:// + bare paths still call `remote_objects_open` for the patra source; `http://` URLs call `wire_http_open` and resolve the branch via `http_remote_resolve_branch`. **`cmd_clone`** target-derive: file:// + bare paths take the last path segment; `http://` URLs take the host (port + path stripped). The walk + copy pipeline downstream is fully transport-independent.
- **Toolchain**: cyrius 5.8.51 → **5.9.37** — picks up the cc5_aarch64 cap-propagation fix that was filed during the v0.7.2 release run. cc5_aarch64 grew 438896 → 449624 bytes; `cyrius build --aarch64 src/main.cyr build/sit-aarch64` now produces a 1.45 MB statically-linked aarch64 ELF without firing the workflow's best-effort swallow.
- **Stdlib**: `[deps].stdlib` unchanged from v0.7.2 — the new HTTP client uses `net` directly and `sandhi`'s `sandhi_net_parse_ipv4` indirectly, both already present.
- **Smoke gate met**: 100-commit / 100-file fixture, `sit clone http://127.0.0.1:8484` → `sit fsck` reports `300 objects, 0 bad`, log byte-identical to a `file://` clone of the same fixture. **211 ms (http) vs 167 ms (file) = 1.26×** — success gate was 3×.
- **127/127 tests pass.** CI gains a `sit serve + http clone + fsck` step alongside the existing file:// wire smoke. DCE binary: **1.30 MB** (vs 1.28 MB at v0.7.2; +18 KB net for the HTTP client). Lint: only the pre-existing >120-char warning at `src/commit.cyr:609`.
- **2026-05-04 issue archived RESOLVED**: [`issues/archived/2026-05-04-cyrius-cc5-aarch64-token-cap-not-propagated.md`](issues/archived/2026-05-04-cyrius-cc5-aarch64-token-cap-not-propagated.md). Verified at cyrius 5.9.37; the consumer-side workaround in `.github/workflows/release.yml` is no longer load-bearing for sit but stays in place as defence against future aarch64 backend regressions.

### v0.7.2 — `sit serve` skeleton (read-only HTTP) + sandhi opt-in

- **First feature-bearing release of the v0.7.x network-transport line.** Two endpoints live: `GET /sit/v1/capabilities` (server identity + advertised limits) and `GET /sit/v1/refs` (every `.sit/refs/heads/*` and `.sit/refs/tags/*` that passes `refname_valid` and resolves to a 64-hex hash; nested ref names like `refs/heads/feature/foo` work via `dir_walk` recursion). 404 on unknown paths and on POST (read-only, GET-only).
- **`sit serve <repo> [--listen 127.0.0.1:<port>]`** — loopback-only HTTP daemon, default port 8484. One repo per process; `chdir`s into `<repo>` before serving. `--listen` is parse-locked to `127.0.0.1:<port>` in v0.7.2; non-loopback exposure is gated on the auth model that arrives in v0.7.5+ (push + bearer).
- **`src/serve.cyr`** (255 lines) — wired into `src/lib.cyr`. Hand-rolled JSON builders; uses sandhi server primitives (`sandhi_server_run`, `sandhi_server_get_method`, `sandhi_server_get_path`, `sandhi_server_path_only`, `sandhi_server_send_response`, `sandhi_server_send_status`) + `INADDR_LOOPBACK()` from `lib/net.cyr`. `cmd_serve` + usage line in `src/main.cyr` — command count: **24 → 25**.
- **Toolchain**: cyrius 5.7.1 → **5.8.51**. Spans 95+ patches; the load-bearing changes are v5.8.46 (token-array cap raise 262144 → 1048576, plus the `needed M, cap is N` diagnostic that sized the bump) and v5.8.39 (sandhi v1.1.0 vendored into stdlib with per-request-arena Allocator-aware `_a` verbs).
- **Stdlib opt-in**: `[deps].stdlib` adds `"net"`, `"tls"`, `"ws"`, `"http"`, `"json"`, `"sandhi"`. Only `sandhi` (server bits) and `net` (`INADDR_LOOPBACK`) are directly called; the rest are sandhi's transitive needs (no cyrius transitive stdlib resolution today).
- **`wire_transport_check` error strings synced** for v0.7.2: `http` → `0.7.3+` (server-side ships in 0.7.2 but the wire.cyr path is the *client*; HTTP CLIENT lands in 0.7.3 per the table below); `https` → `0.7.6+` and `ssh` → `0.7.8+` pointers unchanged; `(this is 0.7.1)` → `(this is 0.7.2)` everywhere.
- **Two sit-side bugfixes caught in smoke** (4-ref fixture: 3 heads incl. `feature/foo` nested + 1 tag): `serve_read_ref_file` `<= 0` → `< 0` (`read_file_heap` returns `0` on success, negative on error — the original check rejected success); `serve_emit_refs_subtree` Str/cstring boundary on `dir_walk` (the function expects a `Str` object and pushes `Str` objects into the results vec; the original code passed and read raw cstrings, so the walk silently returned 0 entries). Fix wraps in `str_from(dir)` and uses `str_len`/`str_data` to read the entries; matches the pattern every other `dir_list` caller in sit (`refs.cyr`, `object_db.cyr`, `diff.cyr`, `wire.cyr`) already follows.
- **127/127 tests pass.** DCE binary: 707 KB (v0.7.0) → **1.28 MB** (v0.7.2; +576 KB / +82%). Sandhi opt-in is the dominant driver — DCE strips most of the ~10K-line sandhi.cyr but the residue is real.
- **2026-04-25 issue archived RESOLVED**: [`issues/archived/2026-04-25-cyrius-fixup-table-cap.md`](issues/archived/2026-04-25-cyrius-fixup-table-cap.md). Original 32,768 → 262,144 cap raise (v5.7.1) was insufficient; v5.8.46's 4× raise to 1,048,576 was sized to the empirical M from the new diagnostic. The two distinct caps the issue conflated (fixup-table vs token-array) turned out to require separate handling.

### v0.7.1 — URL scheme detection + transport dispatch stubs

- **`url_scheme(url)`** + **`url_authority_path_valid(s, len)`** in `src/validate.cyr`; **`wire_transport_check(url)`** in `src/wire.cyr`. URL classification covers `file://` / `http://` / `https://` / `ssh://` / bare paths; whitelist body validator accepts `[a-zA-Z0-9.-_/:@%~]` (rejects shell metachars + leading dash for second-layer CVE-2017-1000117 defense).
- **`remote_url_valid()` extended** to accept http/https/ssh URLs that pass control-char + leading-dash + body-whitelist gates. URLs validate at remote-add time so users wire config in advance; transport itself ships in later v0.7.x patches.
- **`cmd_clone` / `do_fetch` / `cmd_push`** dispatch on URL scheme after validation. Network schemes return rc 1 with per-scheme version pointers (`http transport requires sit 0.7.2+`, `https → 0.7.6+`, `ssh → 0.7.8+`); file/path schemes proceed unchanged.
- **127/127 tests pass** (101 + 26 new). `fuzz_url_validators` runs 10K rounds clean on `url_scheme` + `remote_url_valid`; debug surfaced a Cyrius missing-include footgun (undefined fn refs compile clean, SIGILL at call site) — fuzz file now `include "src/validate.cyr"` explicitly.
- **Sandhi opt-in deferred** to v0.7.2 — adding `"sandhi"` to `[deps].stdlib` requires co-adding `net`/`tls`/`ws`/`http`/`json` (sandhi pulls `SYS_SETSOCKOPT` etc.). Per "ONE change at a time," that whole block lands alongside v0.7.2's first real sandhi caller (`sit serve`).
- DCE binary: 709 KB (+2 KB vs 0.7.0; new validators + dispatch helper).

### v0.7.0 — sandhi-fold toolchain unlock, v0.7.x line opens

- **Minor-line opener.** Toolchain-only — picks up cyrius 5.7.0 ("the sandhi fold"; `sandhi` v1.0.0 vendored into stdlib as `lib/sandhi.cyr`, `lib/http_server.cyr` deleted from stdlib per [sandhi ADR 0002](https://github.com/MacCracken/sandhi/blob/main/docs/adr/0002-clean-break-fold-at-cyrius-v5-7-0.md)).
- **Removed**: stale local `lib/http_server.cyr` orphan (15579-byte regular-file copy of the pre-fold stdlib snapshot; zero callers in sit). Cyrius 5.7.0's downstream worklist names "delete orphan only" as the action for sit.
- No sit source changes. Build clean, 101/101 tests pass, DCE binary 707 KB (down from 710).
- v0.7.x architectural settle: sit-native JSON/REST wire protocol under `/sit/v1/...` (reject git-smart-HTTP — wrong hash, can't carry raw compressed bytes), `sit serve <path>` daemon (one repo per process), bearer-token auth (`~/.sit/serve.token`, 0600), TLS in v0.7.6, SSH in v0.7.8.

### v0.6.12 — sigil SHA-NI + sankoch 2.1 throughput release (biggest single-release win)

- Pure dep-bump release: **cyrius 5.6.40 → 5.6.43**, **sigil 2.9.1 → 2.9.3** (SHA-NI hardware path), **sankoch 2.0.3 → 2.1.0** (DEFLATE micro-tuning). No sit source changes.
- **Sigil SHA-256 throughput up 32×** on 64 KB inputs (5.153 ms → 161 µs). Cascades into `sit add`:
  - **`add-64KB` -41%** (16.40 ms → 9.62 ms; sit/git ratio 4.5× → **2.55×**)
  - **`add-1MB` -48%** (211.52 ms → 112.39 ms; sit/git ratio 12.5× → **6.50×**)
  - `status-100files` -8% (sigil portion was small relative to file I/O at this scale)
- Sankoch 2.1.0's standard zlib path moves modestly (~5-7% on compress, within noise on decompress); larger sankoch 2.x match-finder / ring-buffer / SIMD work queued for follow-up sankoch releases. The remaining `add-1MB` budget is now ~140 ms of `zlib_compress(1MB)` — exactly what sankoch's roadmap is targeting next.
- Cumulative 0.6.0 → 0.6.12: `add-1MB **-48%**`, `add-64KB **-43%**`, `clone **-30%**`, `log **-17%**`, `status **-9%**`. The `add-1MB` ratio drop from 12.5× to 6.5× is the largest user-visible improvement of the v0.6.x arc.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.12.md`](../benchmarks/2026-04-25-v0.6.12.md).

### v0.6.11 — P-20 + multi-insert-transaction investigation (negative result)

- **P-20**: `parse_index` query gains `ORDER BY path`. Downstream `sort_entries` is now O(N) on already-sorted input instead of O(N²) on unsorted. Saves ~50µs at 100 entries, ~5ms at 1K, ~500ms at 10K. No 100-fixture bench movement (under noise floor at this scale).
- **Investigated and reverted**: multi-insert transaction wraps on `cmd_commit` (tree + commit) and `rewrite_index` (DELETE + N INSERTs). A/B measured 5-10% regression on a 50 add+commit cycle workload. patra's per-transaction setup/teardown (~30µs) exceeds saved fsyncs at small batch sizes on modern SSDs (where per-insert fsync is already kernel-batched). The pattern that worked for `copy_objects` (300+ inserts amortized one setup) doesn't generalize to 2-3-insert batches. Reverted before shipping; full investigation in [`docs/benchmarks/2026-04-25-v0.6.11.md`](../benchmarks/2026-04-25-v0.6.11.md).
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.11.md`](../benchmarks/2026-04-25-v0.6.11.md).

### v0.6.10 — dep bumps + S-31 closeout

- **cyrius 5.6.35 → 5.6.40**, **patra 1.6.0 → 1.8.3**.
- **S-31 RESOLVED**: `parse_index` now calls `patra_result_get_str_len(rs, i, 0)` directly (patra 1.6.1 API) instead of the v0.6.3 `strnlen(s, 256)` workaround. Helper deleted.
- **patra 1.7.0 `INSERT OR IGNORE`**: filed but not consumed (SQL-level only; sit's BYTES-column inserts use `patra_insert_row` which doesn't expose the flag).
- **patra 1.8.x WAL group commit (`PATRA_SYNC_BATCH`)**: investigated, reverted before shipping. No measurable bench gain (`copy_objects` already uses explicit transactions; `cmd_commit` doesn't trip the every-64-writes auto-flush; cached handle never closes so BATCH-pending writes would sit in the kernel writeback window across a power loss). Reasoning documented at both `get_object_db` and `get_index_db` call sites for future revisit.
- **No bench movement.** Cumulative 0.6.0 → 0.6.10 unchanged from v0.6.9: `log -18%`, `clone -31%`.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.10.md`](../benchmarks/2026-04-25-v0.6.10.md).

### v0.6.9 — P-06 + P-15: sit-side v0.6.x perf arc closed

- **P-06 — smarter decompression sizing.** Three sites (`read_object`, loose-migration path, `db_object_read_both`): initial multiplier dropped from 16× to 4× (most sit objects fit at ratio ~2-3); retry only on confirmed `-ERR_BUFFER_TOO_SMALL` (other negative codes mean the stream is genuinely corrupt — more memory won't help, fail fast). 75% memory reduction in the decompression-buffer alloc for objects with `blen > 1024`; bench fixture's tiny objects don't show it (4096-byte floor dominates).
- **P-15 — LCS DP table to `fl_alloc`.** `src/diff.cyr:lcs_diff` allocates via `fl_alloc` (mmap-direct for large allocs) and `fl_free`s before returning. Previously the up-to-128MB table squatted on the bump heap for the life of the process; now it goes back to the kernel after the computation. Pure memory hygiene.
- **No synthetic-bench movement** (both items are hygiene/edge-case). Final v0.6.x cumulative scoreboard: `log` **-18%**, `clone` **-30%**.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.9.md`](../benchmarks/2026-04-25-v0.6.9.md).
- **Sit-side v0.6.x perf arc closed.** Every P-NN audit item targeting sit-side code is shipped or explicitly out of scope (see backlog below). Next sit-side headline-mover requires upstream work — see "Waiting on dep updates" subsection.

### v0.6.8 — P-17: buffered stdout

- 206 `syscall(SYS_WRITE, STDOUT, ...)` sites across 9 src files swapped to a single buffered `stdout_write(data, len)` helper backed by a 64KB heap buffer (`src/util.cyr`). Auto-flush on buffer-full; large writes go straight to the kernel after flushing pending bytes. `main.cyr` trailer flushes before `SYS_EXIT`. STDERR stays direct.
- `write_sanitized` rewritten to build a sanitized copy in one heap buffer + single `stdout_write` (was emitting one byte per syscall + bypassing the buffer entirely). Caught an output-ordering bug introduced by the bulk swap (`print_commit_header` was emitting author bytes before the "Author: " prefix because `write_sanitized` was unbuffered while the surrounding writes were); fixed in the same change.
- **No measurable bench movement** on the 100-file synthetic — the `diff-edit` fixture only emits ~30 writes per run. Real win at scale (1000+ line diffs ~ 1000+ syscalls collapsed). Structural improvement (lower syscall pressure, in-order output guarantee).
- Cumulative 0.6.0 → 0.6.8: `log` **−17%**, `clone` **−32%**.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.8.md`](../benchmarks/2026-04-25-v0.6.8.md).

### v0.6.7 — P-04: walk-reachable compressed-bytes cache

- New `db_object_read_both(db, hex, raw_out, deco_out)` in `src/wire.cyr` returns BOTH compressed (formerly thrown away after the internal call) AND decompressed view. `db_object_read_decompressed` becomes a thin wrapper.
- `walk_reachable_tree` + `walk_reachable_from_commit` gained a `raw_cache` parameter; they call `db_object_read_both` and stuff the raw bytes into the cache keyed by hex. `copy_objects` checks cache first; cache misses (blobs only — walk doesn't visit them) fall back to `db_object_read_raw`. Caller (`do_fetch`, `do_push`) creates a fresh `map_new()` per operation and passes it through.
- **Win**: `sit clone-100commits` **−21.7%** (215.27 → 168.53 ms min, 13.64x git → 11.08x git). 500 source SQL ops → 300 (−40%). Other ops within noise.
- Cumulative 0.6.0 → 0.6.7: `log` **−16%**, `clone` **−32%**.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.7.md`](../benchmarks/2026-04-25-v0.6.7.md).

### v0.6.6 — P-10 + P-18: hashmap-backed lookups

- **P-10**: `src/tree.cyr:tree_find` lazily builds a name → entry hashmap per entries vec, cached by vec pointer for the process lifetime. Hot callers (`cmd_status`, `cmd_diff`, `materialize_target`, merge three-way loops) drop from O(N²) total to O(N).
- **P-18**: `three_way_path_set` dedups via `map_has` instead of a nested `streq` scan over the growing paths vec. ~4.5N² streqs → 3N hashmap ops.
- **Bench**: no measurable improvement on the 100-file fixture — too small to show — but the change is real and substantial at repo scale. Concrete projection: 1000-file `cmd_status` ~5ms → ~0.3ms on the tree_find piece; 10000-file repo ~50×.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.6.md`](../benchmarks/2026-04-25-v0.6.6.md).
- Cumulative 0.6.0 → 0.6.6: `log` **-12%**, `clone` **-13%**, everything else noise (dep-side bound).

### v0.6.5 — P-03: `copy_objects` batched transaction

- `src/wire.cyr:copy_objects` now wraps the insert loop in `patra_begin` / `patra_commit` (collapses N WAL fsyncs into 1) and drops the outer redundant `db_object_has` check (`db_object_insert_raw` already does the check internally — every object was paying for 2 SELECTs instead of 1).
- Side-effect counting fix: `db_object_insert_raw` returns `1` when the object was already present, `0` when actually inserted, negative on error. `copy_objects` increments `copied` only on `== 0`. Without this, `sit push` reported all reachable objects as "new" after a clone (caught by wire smoke).
- **Win**: `sit clone-100commits` **−15%** (245.19 → 208.44 ms min, 16.13x git → 13.82x git). Other ops within noise.
- Bigger clone wins still on patra's roadmap (`WAL group commit`, `UPSERT`) — when those land, a follow-on sit release can drop the manual transaction wrapping AND the inner has-check; expected combined improvement another ~30-50% on top of v0.6.5.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.5.md`](../benchmarks/2026-04-25-v0.6.5.md).

### v0.6.4 — First v0.6.x perf release: patra-handle caching + S-24 fold-in

- Process-wide cached handles for `.sit/objects.patra` (`get_object_db()`) and `.sit/index.patra` (`get_index_db()`). Collapses **P-01, P-02, P-05, P-08, P-12, P-25** — every `read_object` / `write_typed_object` / `resolve_hash` previously did patra_init + patra_open + CREATE TABLE + loose-migration check + patra_close on every call. Now: open + migrate once per process; reuse forever; fd dies with the process.
- **S-24 fold-in**: read_object's single-exit shape fell out for free once the open/close pattern was gone. SQL-string buffers in object_db.cyr swapped from `alloc_or_die` (bump-heap, lives forever) to `fl_alloc` + `fl_free` — trims per-query bump pressure on long-running ops.
- **Wins**: `sit log` on a 100-commit walk **−17%** (33.67 → 27.84 ms min). `sit fsck` should match or exceed (same pattern, more iterations).
- **Honestly unchanged**: `sit status`, `sit clone`, `sit add`, `sit commit`, `sit fetch` — their bottlenecks (sigil throughput, per-object zlib_decompress, file_write_all) are downstream of the patra open/close cost the cache fixed. Other queued perf items target those: see v0.6.5+ below.
- Bench snapshot: [`docs/benchmarks/2026-04-25-v0.6.4.md`](../benchmarks/2026-04-25-v0.6.4.md).

### v0.6.3 — LOW-severity batch + audit closeout

- **S-28** confirmed already addressed: cyrius stdlib's `exec_vec` passes an empty envp, which is more aggressive than the audit's "minimal envp" prescription. No sit-side change; documented in CHANGELOG + state.md so future readers don't re-investigate.
- **S-31** — added `strnlen(s, max)` to `src/util.cyr`. Swapped `parse_index`'s `strlen(patra_result_get_str(…))` to `strnlen(…, 256)` (patra's `COL_STR_SZ` width). Defense-in-depth — patra's writer still memsets every STR slot to zero, so `strlen` would terminate inside the slot today, but the bound makes the safety property explicit at the read site instead of implicit at the write site.
- **S-32** — Cyrius string-literal lifetime invariant documented in [`docs/architecture/004-cyrius-string-literal-lifetime.md`](../architecture/004-cyrius-string-literal-lifetime.md). The audit's alternative (switch tree.cyr's mode literals to integer codes with a format table) was rejected: trades a free invariant for runtime indirection on the hottest tree-build path.
- **Audit closeout**: 2026-04-24 P(-1) audit fully resolved at every severity (CRITICAL / HIGH / MEDIUM / LOW). Only **S-24** is deferred — it folds into the v0.6.x patra-handle-caching refactor's `read_object` rewrite (avoids touching the same function twice in two consecutive releases).

### v0.6.2 — Security hygiene (MEDIUM batch)

- **S-16** through **S-27** from the 2026-04-24 P(-1) audit landed. Highlights: `alloc_or_die` helper + 52-site swap (S-17); materialize / merge / commit / clone now fail loudly on FS-mutation errors instead of silently producing partial state (S-16, S-27); `cmd_clone` requires `--force-absolute` for absolute targets (S-23); author-line + sitsig parsers hardened against integer overflow + partial hex decode (S-18, S-19, S-20); index-migrate caps per-line path length at 4096 (S-22); latent `ensure_dirs_for` mkdir("") removed (S-25). Full list in [CHANGELOG § 0.6.2](../../CHANGELOG.md#062--2026-04-25). Audit findings stamped RESOLVED in [`docs/audit/2026-04-24-audit.md`](../audit/2026-04-24-audit.md).
- **S-24 deferred to v0.6.x.** The audit's `read_object` single-exit refactor + SQL-string `fl_alloc` swap is entangled with the planned patra-handle-caching refactor (which adds `read_object_with_db(db, hex, out)` and threads the cached handle through every caller). Doing both in v0.6.2 would mean rewriting `read_object` twice in two consecutive releases.
- All P(-1) CRITICAL/HIGH/MEDIUM findings closed except the deferred S-24.
- Behavioral change: `sit clone <url> <abs-path>` requires `--force-absolute`. CI smoke + `scripts/benchmark.sh` + `docs/guides/getting-started.md` updated. Migration note in CHANGELOG.

### v0.6.1 — S-33 dep-bump release

- **S-33** — `sit status` SIGSEGV on a 100-commit / 100-file repo: **resolved** by upstream dep bumps. Triage in [`issues/archived/2026-04-24-cyrius-stdlib-alloc-grow-undersize.md`](issues/archived/2026-04-24-cyrius-stdlib-alloc-grow-undersize.md) and [`issues/archived/2026-04-24-read-object-unreadable-at-scale.md`](issues/archived/2026-04-24-read-object-unreadable-at-scale.md). Two stacked upstream bugs: cyrius stdlib `alloc` grow-by-1MB undersize (caused the SIGSEGV via the 16 MiB retry alloc) + sankoch `zlib_compress` / `zlib_decompress` asymmetry (caused the retry path to fire in the first place; lost ~20% of objects on the fixture).
- **Pin moves**: cyrius `5.6.25` → `5.6.35` (alloc grow fix landed upstream in 5.6.34), sankoch `2.0.1` → `2.0.3` (zlib symmetry restored). No sit source changes.
- `scripts/benchmark.sh` — `bench_status` + `bench_clone` rows re-enabled, producing real numbers (`status-100files` 7.08 ms ≈ 1.8× git; `clone-100commits` 245 ms ≈ 16× git, dominated by per-call patra open per P-01).
- New `docs/development/issues/` directory for upstream-bug writeups (see README). Lifecycle: file → triage → fix lands → archive with `— RESOLVED`. Two RESOLVED entries on day-one.

### v0.6.0 — security hardening

- **P(-1) audit fixes**: validators for ref names (git `check-ref-format` grammar), tree entry names, hash prefixes, config values, remote URLs. Symlink guards on all local-clone paths (CVE-2023-22490 class). Decompression multipliers tightened 256× → 16×. Output escape filter on attacker-controlled identity bytes. Full change list in [CHANGELOG § 0.6.0](../../CHANGELOG.md#060--2026-04-24). Underlying audit at [`docs/audit/2026-04-24-audit.md`](../audit/2026-04-24-audit.md).
- **New module**: `src/validate.cyr` — pure validators, one source of truth.
- **ADRs 0003, 0004, 0005** — no upward repo discovery, SHA-256 only, local-clone threat model.
- **Tests**: 101 assertions across 13 test groups (31 → 101).

### v0.5.1 — file-split refactor

- `src/main.cyr` shrank from 5096 → 112 lines (purely `print_usage` + `main()` + dispatch + trailer).
- 11 topical modules under `src/`: `util`, `config`, `object_db`, `index`, `refs`, `tree`, `diff`, `commit`, `merge`, `sign`, `wire`. Chained via `src/lib.cyr`.
- No function renames, no feature changes, no bug fixes beyond what the split surfaced. Mechanical relocation only.
- Follows the yukti / patra include-chain pattern; `cyrius.cyml [build].entry` stays on `src/main.cyr`, stdlib continues auto-including via `[deps].stdlib`.

### v0.5.0 — wire protocol (local-path transport)

- **Remotes**: `sit remote add|list|remove` — named remotes in `.sit/config` as `remote.<name>.url = <path>`. `file://` and bare absolute paths.
- **`sit fetch <remote> [<branch>]`** — BFS-walks reachability from the remote ref in the remote's `.sit/objects.patra`, copies missing objects as raw compressed bytes, writes `.sit/refs/remotes/<remote>/<branch>`.
- **`sit push <remote> [<ref>]`** — symmetric local → remote, fast-forward-only.
- **`sit pull <remote> [<branch>]`** — fetch + fast-forward merge; divergence bails out with a pointer at `sit merge`.
- **`sit clone <url> [<dir>]`** — mkdir + chdir + init + remote-add + fetch + materialize.
- **`sit merge -S`** — signed merge commits via the existing `build_merge_commit_signed`.
- **Nested refs** — `sit branch feature/foo`, `sit checkout -b feature/foo`, `sit tag rel/v1` all work; `ensure_parent_dirs` called from every ref writer.
- **Remote-tracking ref resolution** — `sit merge origin/main`, `sit show origin/main`, etc. work via `resolve_ref_name` consulting `.sit/refs/remotes/<path>`.

Command count: **24** (previous 19 + `remote`, `fetch`, `pull`, `push`, `clone`).

### v0.4.0 — first official release

The local VCS loop is complete end-to-end, with ed25519 signing and a local-path fetch/push protocol.

**Core object model**
- `sit init` creates a git-parity `.sit/{HEAD,objects.patra,refs/heads}` layout.
- Objects are SHA-256-hashed (sigil) and zlib-compressed (sankoch), framed `"<type> <len>\0<content>"` — byte-compatible with git's SHA-256 object format for identical content.
- Storage is patra-backed: `.sit/objects.patra` (`objects(hash STR, ty INT, content BYTES)`) + `.sit/index.patra` (`entries(path STR, hash_hex STR)`). Legacy plaintext/loose layouts auto-migrate on first access.
- Trees are recursive with `40000` dir + `100644` file modes, byte-matching git's SHA-256 tree format. `flatten_tree` / `read_head_tree_entries` give flat views for status/diff.

**Commands (19)**
- Write: `init`, `add [-f]`, `rm [--cached]`, `commit [-S] [-m]`, `reset [--hard]`, `merge [--abort]`, `branch [-d]`, `checkout [-b]`, `tag [-d]`, `config [--global|--list|--unset]`, `key generate|show`, `remote add|list|remove`, `fetch`, `push`.
- Read: `log [--oneline] [-n] [<ref>]`, `status`, `diff [--staged|<commit>|<c1> <c2>]`, `show [--stat] [<hash>]`, `cat-file`, `owl-file`, `fsck`, `verify-commit`.

**Signed commits (sigil/ed25519, no GPG)**
- `sit key generate` → `~/.sit/signing_key` (32B seed hex, 0600) + `signing_key.pub`.
- `sit commit -S` injects `sitsig <sig-hex> <pub-hex>\n` between `committer` and the message separator. Signed payload is the body *without* the sitsig line (self-consistent like git's `gpgsig`).
- `sit show` / `sit log` auto-decorate with `Signature: good|BAD (key <hex12>)` via a shared `print_commit_header`.

**Merge**
- Fast-forward when possible; otherwise 3-way with line-level diff3. Non-overlapping hunks auto-merge; overlapping edits fall back to conflict markers + `.sit/MERGE_HEAD`. Follow-on `sit commit` emits a 2-parent commit. `sit merge --abort` cancels.

**Wire protocol (local paths only)**
- `sit remote add <name> <url>` writes to `.sit/config`; `file://` and bare paths are the only transports in this cut.
- `sit fetch` walks remote refs, diffs against local object set, copies missing objects naively (no pack bundles).
- `sit push` is the reverse direction; fast-forward only. Non-ff push rejected.
- HTTP / SSH transports and pack bundles are explicit v0.5.x work.

**Config + identity**
- `sit config [--global] <key> [<value>]`, `--list`, `--unset`. Local `.sit/config`, global `~/.sitconfig`.
- Author chain: `SIT_AUTHOR_NAME` env → local config → global config → `"sit user"` fallback.

**Tests**: 31 assertions — sigil SHA-256 known-answers, git-SHA-256 blob framing, hex encode/decode, sankoch zlib roundtrip, patra COL_BYTES small + 16KB overflow, ed25519 sign/verify roundtrip with bit-flip negatives.

**Deps**: cyrius 5.6.25, sakshi 2.1.0, sankoch 2.0.1, sigil 2.9.1, patra 1.6.0. Git-tag pinned. No FFI, no C, no libgit2 — see [ADR 0001](../adr/0001-no-ffi-first-party-only.md).

## Backlog

### v0.6.x perf items — closed (reference only)

Patra-handle caching shipped in v0.6.4. Remaining items targeted the bottlenecks v0.6.4 didn't move: clone, status, diff. **All sit-side items shipped or explicitly deferred by v0.6.12** — the arc closed there. The waiting-on-deps subsection below is left as reference for how the cumulative scoreboard accumulated; the only forward-looking entry is `P-11` (sit add index upsert without full rewrite, gated on a patra `or_ignore` flag for `patra_insert_row`).

**Waiting on dep updates** (filed on each dep's roadmap 2026-04-25; sit gets bigger wins once these land but is not blocked from shipping the items below):

- [`patra` roadmap](../../../patra/docs/development/roadmap.md):
  - ~~Sized string getter `patra_result_get_str_len`~~ — **shipped as patra 1.6.1, consumed by sit v0.6.10** (S-31 closed).
  - ~~WAL group commit / batched fsync~~ — **shipped as patra 1.8.x; sit investigated and did NOT consume** in v0.6.10 (durability regression with no perf gain on sit's bench shape; reasoning at `get_object_db` / `get_index_db` call sites). Revisit when sit grows explicit `patra_flush()` at command exit.
  - ~~`INSERT OR IGNORE`~~ — **shipped as patra 1.7.0 (SQL-level only); sit can't consume yet** because sit's BYTES-column inserts go through `patra_insert_row` (programmatic API), not SQL strings. Re-file: ask patra to grow an `or_ignore` flag on `patra_insert_row` so sit can drop the inner `db_object_has` in `db_object_insert_raw`. Effort on patra side: small (the SQL-level path already does the dedup probe).
- [`sigil` roadmap](../../../sigil/docs/development/roadmap.md):
  - ~~SHA-256 hot-path throughput investigation~~ — **shipped as sigil 2.9.3, consumed by sit v0.6.12.** SHA-NI hardware path live on x86_64; SHA-256 throughput ~12 MB/s → ~400 MB/s on 64 KB inputs (32× factor). Drove `sit add -64KB -41%` and `sit add -1MB -48%`.
- [`sankoch` roadmap](../../../sankoch/docs/development/roadmap.md):
  - **Partial: sankoch 2.1.0 shipped** in v0.6.12 with DEFLATE micro-tuning down-payments (pre-reversed dynamic Huffman codes, others). Standard zlib path moves modestly (~5-7%) at small/medium sizes. Larger 2.x match-finder / ring-buffer / SIMD work queued for follow-up sankoch releases — the remaining `add-1MB` budget is ~140ms `zlib_compress(1MB)`, which is exactly what those bigger items target.

When any of those ship, sit can drop the corresponding workaround / get a measurable improvement on the matching workload without further sit-side code changes. Watch their CHANGELOGs.

**Sit-side items (no dep dependency, ship-ready):**

- ~~**P-03** `copy_objects`~~ — **shipped in v0.6.5** (see Released above). Partial: the transaction wrap + outer has-check drop landed; the batched `WHERE hash IN (...)` pre-filter is deferred (would need 60-hash chunking per patra's 128-token / 4096-byte SQL parser limits). When patra grows `INSERT OR IGNORE` / `UPSERT`, the inner has-check goes away too.
- ~~**P-06** + **P-15**~~ — **shipped in v0.6.9** (see Released above). Decompression sizing tightened (4× initial, retry only on `-ERR_BUFFER_TOO_SMALL`); LCS DP table moved to `fl_alloc`/`fl_free` (mmap-backed, freed after computation).
- ~~**P-04** `walk_reachable_from_commit`~~ — **shipped in v0.6.7** (see Released above). Cached compressed bytes during the walk, shared with `copy_objects`. Final clone ratio 11.08x git (from 16.13x at v0.6.4 entry).
- ~~**P-10 + P-18**~~ — **shipped in v0.6.6** (see Released above). Hashmap-backed `tree_find` + `three_way_path_set`. No 100-file bench movement; substantial at scale (1000-file `cmd_status` ~5ms → ~0.3ms on the tree_find piece).
- **P-11** `sit add` index upsert without full rewrite (needs patra UPSERT; if patra doesn't have it, push on their roadmap).
- ~~**P-17** Buffered stdout~~ — **shipped in v0.6.8** (see Released above). 64KB heap buffer in `src/util.cyr`; 206 direct stdout writes routed through it. No 100-file bench movement (fixture too small); structural improvement + win at scale.
- Re-bench after each change; gate on no regression vs. the v0.6.4 snapshot.

### ADRs to write (concurrent with v0.5.2)

- **ADR 0003** — sit does not search upward for `.sit/` (CVE-2022-24765-shape; locks in correct behavior).
- **ADR 0004** — sit is SHA-256 only; no SHA-1 interop ever.
- **ADR 0005** — Local-clone threat model (symlink handling, allowed URL schemes, future HTTP notes).

### Cross-project backlog (from audit § Downstream)

- **patra** — `INSERT OR IGNORE` / `UPSERT` (unblocks P-11 / P-24), bound parameters for STR columns (unblocks the right fix for S-01), sized `patra_result_get_str_len` (S-31). Draft entries on patra's roadmap.
- **sigil** — `hex_decode` that strictly fails on invalid chars rather than partial decode (S-20). Flag SHA-256 software throughput; software vs hardware story.
- **sankoch** — `zlib_decompress_with_ratio_cap` primitive to give every consumer a one-call decompression bomb defense (S-08 root-cause fix).

### Cross-project asks pointing back at sit (downstream-driven)

- **owl** — wants sit consumable as a Cyrius dep. owl's roadmap describes the SIT VCS swap in `src/vcs.cyr` as a "single-file rewrite" that replaces the `execve("git", "diff", …)` shell-out with a sit library call. As of sit 0.7.6 sit is binary-only — no `[lib]` clause in `cyrius.cyml`, no `dist/sit.cyr`, no namespaced public API. owl can't `[deps.sit] modules = ["dist/sit.cyr"]` the way it consumes vyakarana. **Tracked as v0.7.7 below** — slotted ahead of SSH per the explicit "before SSH" downstream ask. owl's request also surfaced two diff-primitive correctness gaps that the same release should fix: (a) `cmd_diff` ignores `-U<N>` (context width hardcoded to 3 in `group_hunks`); (b) `print_file_diff` and `lcs_diff` are tightly bound to stdout-print + working-directory state, not reusable as a "give me ops for path P at HEAD vs working tree" primitive a library consumer can call.

### v0.7.x — Network transport release sequence

Per the v0.7.x plan settled 2026-04-25. Each release is a small bite (CLAUDE.md "Large effort: small bites only"); each ships independently with a test gate.

**Architectural settles** (already locked):

- **Wire protocol**: sit-native JSON/REST under `/sit/v1/...`. Git-smart-HTTP rejected (wrong hash family — sit is SHA-256 only per ADR 0004; can't carry raw compressed `objects.patra` bytes through pack rewriting; sit owns both ends so compatibility is no leverage).
- **Routes**: `GET /capabilities`, `GET /refs[/<name>]`, `GET /objects/<hash>` (raw compressed bytes, `X-Sit-Type` header carries patra `ty`), `POST /want` (batched length-prefixed object stream), `POST /objects/<hash>` (server rehashes — only place sit rehashes; trust boundary), `POST /refs/<name>` (fast-forward enforced).
- **Server**: `sit serve <path> [--listen 127.0.0.1:8484] [--require-auth] [--token <path>]`. One repo per process. Reuses v0.6.4 patra-handle cache.
- **Auth**: bearer token via `~/.sit/serve.token` (0600). Anonymous read in both modes; `--require-auth` flag gates writes only. Per [ADR 0007](../adr/0007-network-transport-security.md): bearer auth is local-process-snoop defence on loopback, not a TLS substitute. Non-loopback exposure of HTTP is structurally unsafe and never lands without first-party Cyrius TLS.
- **Transport-layer security**: per [ADR 0007](../adr/0007-network-transport-security.md), HTTPS via libssl is not on the v0.7.x roadmap and won't ship until first-party Cyrius TLS exists. SSH (v0.7.8 — bumped from v0.7.7 when the library-export slot landed in front of it; see release table below) is the canonical encrypted-over-internet transport (process boundary, not FFI). HTTP is loopback / private-network / behind-tunnel.

**Releases:**

| ver | scope | new modules | success gate |
|---|---|---|---|
| ~~0.7.0~~ | ✅ shipped — sandhi-fold toolchain unlock; orphan delete | — | (see Released) |
| ~~0.7.1~~ | ✅ shipped — URL scheme detection + dispatch stubs | — | (see Released) |
| ~~0.7.2~~ | ✅ shipped — `cmd_serve` + `GET /capabilities` + `GET /refs` (read-only); sandhi opt-in; cyrius 5.8.51 toolchain refresh | `src/serve.cyr` | (see Released — 4-ref smoke fixture verified) |
| ~~0.7.3~~ | ✅ shipped — `GET /objects/<hash>` (server) + `wire_http.cyr` end-to-end fetch/clone (client) + `obj_src` abstraction; cyrius 5.8.51 → 5.9.37 toolchain refresh | `src/wire_http.cyr` | (see Released — 100-commit smoke fixture verified at 1.26×) |
| ~~0.7.4~~ | ✅ shipped (scaffold) — `POST /want` server endpoint + ADR 0006 frame format + DCE-stripped client primitives. Per-object GET still the active client path; batching held for v0.7.5+ (gate not met on loopback) | ADR 0006 | (see Released — wire validated; perf gate explicitly deferred) |
| ~~0.7.5~~ | ✅ shipped — walk-side phasing (commit chain → tree-batch → blob-batch) + cache-aware tree walk + frame-decoder fuzz (10M iters clean). Push deferred to v0.7.6+. | — | (see Released — 13% loopback / 42% at 1 ms RTT projected; ≥30%-at-realistic-RTT gate met) |
| ~~0.7.6~~ | ✅ shipped — `POST /objects/<hex>` (server rehashes — trust boundary) + `POST /refs/<refname>` (FF gate) + bearer auth via `~/.sit/serve.token` (0600) + ADR 0007 (no libssl, ever). Client `cmd_push` lights up over `http://`. | ADR 0007 | (see Released — full push roundtrip CI smoke; 401 cases verified; anonymous read against auth-required server works) |
| ~~0.7.7~~ | ❎ moved to v0.8.x — was `dist/sit.cyr` library export + diff cleanup; v0.7.x line closed at v0.7.6 ahead of this work; see v0.8.x slot table below | — | (see v0.8.x) |
| ~~0.7.8~~ | ❎ moved to v0.8.x — was SSH (`sit serve --stdio`); same reason | — | (see v0.8.x) |

**Out of scope for v0.7.x** (deferred to v0.8.x or later):

- **Pack bundles** — batch object transfer with sankoch delta primitives. Ties to sankoch + patra storage shape work that isn't ready.
- **Push to checked-out branch defense** — known footgun (see "Longer horizon" below); a v0.7.x patch may file the check, but it's not gating the release line.
- **HTTP/2** — sandhi has it (`sandhi_h2_*`); whether sit's wire benefits from H/2 streaming over the v0.7.4 batched-stream endpoint is a v0.7.4-time decision.

**Benchmarks** — three bench targets were scoped but deferred from v0.6.0 because they need larger fixtures or a companion algorithm change:

- **LCS diff** at 100×100 / 1000×1000 / 4000×4000 line counts. Shows the cost curve and the 16M-cell cliff; motivates the Myers O((N+M)D) fallback (P-14).
- **`glob_match`** against 10 / 50 / 200-pattern `.sitignore` files. Baseline for the P-13 pattern pre-classification refactor.
- **`hash_file_as_blob` end-to-end** on 1 KB / 64 KB / 1 MB inputs. Measures the true `sit add` floor and maps sigil's software-SHA-256 bottleneck.

Add these alongside the algorithm / transport work that justifies them. v0.7.x bench fixtures will likely include a 100-object HTTP fetch round trip for the wire-protocol releases.

### v0.8.x — Hardening sweep toward v1.0.0

Same small-bite cadence as v0.7.x. Five releases shipped (toolchain → lib export → SSH read → SSH push → denyCurrentBranch). Remaining slots tighten the git-parity surface for v1.0.0.

**Architectural state (verified during v0.8.4 prep, 2026-05-13):**

- **HTTPS / mTLS blocked at the cyrius level.** Sandhi's `tls_policy/` is a composition layer over stdlib `lib/tls.cyr`, which is libssl-via-fdlopen. Sandhi v1.2.0 release notes explicitly: *"lib/tls.cyr stays libssl.so.3-bridged per the 2026-04-24 pure-Cyrius-TLS removal."* ADR 0007 forbids sit from consuming. Filed upstream as [`issues/archived/2026-05-13-sandhi-first-party-tls-surface-needed.md`](issues/archived/2026-05-13-sandhi-first-party-tls-surface-needed.md). When that lands, sit's HTTPS slot is a single patch. Earlier "freshly-unblocked TLS items" framing turned out to be wrong — corrected here.
- **SSH is the encrypted-over-internet path** (v0.8.2 read + v0.8.3 push), per ADR 0008. Process boundary, not FFI. Works today.
- **Surface minimization is a live option.** The cyrius v5.11.33 cap raise (2 MB → 8 MB) means consuming sandhi's full 11,729-line bundle is no longer blocking. Sit still uses ~6 of those lines (`sandhi_server_*`); dropping sandhi for a hand-rolled HTTP/1.0 server on `lib/net.cyr` is a defensible v0.8.x slot if the surface argument outweighs the share-with-other-AGNOS-consumers argument.

**Releases:**

| ver | scope | new modules | success gate |
|---|---|---|---|
| ~~0.8.0~~ | ✅ shipped 2026-05-12 — line opener: cyrius `5.9.37 → 5.11.34`; deps (sakshi `→2.2.4`, sankoch `→2.2.5`, sigil `→3.1.1` major, patra `→1.9.4`); `lib/`/`src/lib/`/`cyrius.lock` untracked; CI `Lint` + `Fuzz` steps; CI install gains `$HOME/.cyrius/versions/$VER/lib/` path. Filed + resolved cross-repo at cyrius v5.11.33 (PP cap 2 MB → 8 MB). | — | (see Released — build/test/lint/fuzz green; binary 1.30 MB flat) |
| ~~0.8.1~~ | ✅ shipped 2026-05-13 — `dist/sit.cyr` library export ([lib] block + generated bundle, tracked in-repo per sandhi shape); `src/api.cyr` public surface (`sit_repo_open` / `sit_repo_close` / `sit_diff_path`); ADR 0009 public-API contract (`sit_*` / `ann_*` stable, SemVer-governed); diff primitive cleanup (`-U<N>` threading through cmd_diff / cmd_show, `compute_file_diff` extracted as pure-compute layer); CI guards (dist sync + diff -U<N> smoke). | `src/api.cyr`, `dist/sit.cyr`, ADR 0009 | (see Released — owl-blocker resolved; 127/127 tests; binary flat at 1.30 MB) |
| ~~0.8.2~~ | ✅ shipped 2026-05-13 — SSH transport (`ssh://`, read-only). `sit serve --stdio` server mode + `src/wire_ssh.cyr` client + `OBJ_SRC_SSH` tagged dispatch + ADR 0008 + CVE-2017-1000117 three-layer defense + 100K fuzz-rounds clean + CI sshd-loopback smoke. Push over SSH still gated to v0.8.3. | `src/wire_ssh.cyr`, ADR 0008 | (see Released — clone works end-to-end; CVE injection rejected; binary 1.36 MB) |
| ~~0.8.3~~ | ✅ shipped 2026-05-13 — push over SSH. `_wire_ssh_post_xhdr` + `_wire_ssh_recv_response` (GET/POST recv-split) + `ssh_remote_push_object` + `ssh_remote_push_ref` + `_do_push_ssh`. `cmd_push` SSH dispatch + `wire_transport_check_writable` accepts ssh. Bearer-over-SSH deferred (stub returns 0; SSH already authenticates end-to-end). CI smoke: full push roundtrip + up-to-date + non-FF rejection. | extends `src/wire_ssh.cyr` + `src/wire.cyr` | (see Released — push works end-to-end; binary flat at 1.36 MB) |
| ~~0.8.4~~ | ✅ shipped 2026-05-13 — `denyCurrentBranch` default refuse. Server-side check in `serve_handle_put_ref` (423 Locked when target=HEAD and ref exists); file:// symmetric pre-check via `_remote_current_branch`; push-helper return convention extended with `2 = denyCurrentBranch`; client surfaces distinct message. Initial pushes to empty remotes still succeed (git parity). CI smoke: rejection + detached-HEAD bypass. | extends `src/serve.cyr` + `src/wire.cyr` | (see Released — first v0.7.6 footgun closed; binary flat at 1.36 MB) |
| ~~0.8.5~~ | ✅ shipped 2026-05-15 — `sit fsck` reachability walk + cyrius `5.11.34 → 5.11.55`. New helpers in `src/object_db.cyr`: `fsck_walk_reachable` (BFS, multi-parent), `fsck_collect_roots` (heads + tags + remotes via `dir_walk` + detached HEAD + staging-index blobs), `fsck_collect_commit_parents` (distinct from `parse_commit_body`), `fsck_extract_commit_tree`, `fsck_read_ref_tip`, `fsck_walk_refs_dir`, `fsck_ty_word`. Integrity SELECT widened to `(hash, ty)` for git-shaped `dangling <type> <hex>` output. Dangling doesn't fail the command. `--prune` deferred (needs grace-period + reflog support). Toolchain pin bumped (lib byte-identical to 5.11.54). CI smoke covers clean / rewind / merge cases. | extends `src/object_db.cyr`'s `cmd_fsck` (~300 lines new); separate walker — does NOT reuse `walk_reachable_phased` because that walker inherits `parse_commit_body`'s single-parent capture, which v0.8.6 will fix | (see Released — second v0.7.6 footgun closed; binary 1.39 MB) |
| ~~0.8.6~~ | ✅ shipped 2026-06-10 — cyrius 6.x toolchain refresh (NOT the originally-planned wire-walker fix). cyrius `5.11.55 → 6.1.27` major; deps sakshi `→2.2.10` / sankoch `→2.3.0` / sigil `→3.7.8` / patra `→1.11.0`; stdlib reorg (`bigint`/`base64`/`json` → `bayan`; `+slice`; `async` omitted as benign dead-code). `tls_native` unblock noted. Source-flat. | — | (see Released — 127/127 tests; binary 2.12 MB) |
| ~~0.8.7~~ | ✅ shipped 2026-06-10 — wire-walker multi-parent fix. `parse_commit_body` exposes every parent via a vec at `out+48`; `walk_reachable_phased` + `is_ancestor` + `is_ancestor_in_db` follow all edges. Verified: merge-fixture clone 9 → 11 objects. `out+8` untouched (cmd_log/merge_base byte-identical); `merge_base` LCA left as a tracked follow-up. | `parse_commit_body` parents-vec in `src/commit.cyr`; `walk_reachable_phased` + `is_ancestor_in_db` in `src/wire.cyr`; `is_ancestor` rewritten as full-DAG BFS | (see Released — third footgun closed; 138 tests; binary 2.12 MB) |
| **0.8.8** | **Full `.sitignore` semantics — git-parity.** Today `match_ignore` handles bare `*` globs and literal paths; gaps: negation (`!pattern` re-includes a previously-excluded match), `**` (multi-segment wildcard), char classes (`[abc]`), anchored patterns (`/foo` only matches at repo root), path patterns (`foo/bar` only matches that nesting). Substantial parser work in `src/index.cyr`; high test coverage given corner cases (negation order, `**/` vs `/**`, escaped brackets). | extends `src/index.cyr`'s ignore matcher | new tests/sit.tcyr group covering each new feature against a synthetic .sitignore + path matrix; fixture-based smoke with negation re-include + `**/build/*` exclude patterns |
| **0.8.9** | **`sit log --graph` + `--depth N` shallow clone (bundled).** Two visualization/transport items that share a DFS-over-the-commit-DAG primitive. `--graph` emits an ASCII DAG using `\|` / `/` / `\` characters for merge branches; needs commit-parent walking — now trivially available via `parse_commit_body`'s `out+48` parents vec (v0.8.7). `--depth N` caps `walk_reachable_phased` to N commits back from HEAD; touches `src/wire.cyr`'s walker and `cmd_clone` arg parsing. | extends `src/commit.cyr` (`cmd_log --graph`) and `src/wire.cyr` (`walk_reachable_depth`) | CI smoke: 5-commit fixture with a merge; `sit log --graph` byte-shape matches an expected snapshot. Plus a `--depth 1` clone of a 10-commit fixture pulls exactly 1 commit-tree-blob-set (3 objects) |
| **HTTPS** | **HTTPS via `tls_native` (now unblocked, v0.8.6).** Wire cyrius 6.x's pure-Cyrius TLS 1.3 (`lib/tls_native.cyr`) into `wire_http.cyr` (client: `tls_native_new_client` → `set_verify(NONE)` → `tls_native_connect(fd)` → TOFU pin check → `tls_native_read/write`) + `serve.cyr` (server: `tls_native_new_server(cert,key)` + handshake). Flip `wire_transport_check_readable`/`_writable` to accept `https://`; ADR 0007 updated (2026-06-10). **Trust model: TOFU / pinned** (decided 2026-06-10) — pin the peer SPKI SHA-256 (`tls_native_get_peer_spki_der`, survives cert renewal like an SSH host key) in `~/.sit/known_certs`; first-use records, later mismatch errors (MITM signal). Matches ADR 0008's SSH host-key model. CA-chain + hostname verification is a **post-v1 opt-in** (see Longer horizon). Multi-release arc, read-only client first (v0.8.2→0.8.3 SSH cadence). Sub-bites: (1) TOFU pin store, (2) client TLS I/O in `wire_http`, (3) server TLS in `serve.cyr` + e2e. Slot number TBD relative to `.sitignore` / `log --graph`. | new `src/wire_https.cyr` + extends `wire_http.cyr` + `serve.cyr` TLS termination | clone/fetch over `https://` against a `sit serve` TLS endpoint; fsck-clean roundtrip; TOFU pin recorded on first clone + mismatch rejected |
| **0.8.x last** | **Closeout pass before v1.0.0.** Per CLAUDE.md closeout procedure: full test suite, bench baseline vs. v0.6.x scoreboard, dead-code audit, refactor pass on any v0.8.x parallel-codepath accretion, code-review pass, cleanup sweep, security re-scan, downstream check (owl on `dist/sit.cyr`), doc sync, version-verify, full-clean build. | — | all closeout-pass checks green; v1.0.0 tag goes out |

**Previously blocked on upstream — now UNBLOCKED (cyrius 6.x, v0.8.6):**

- **HTTPS (`https://`)** — ✅ **gate cleared.** cyrius 6.x ships `lib/tls_native.cyr`, a sovereign pure-Cyrius TLS 1.3 stack on sigil primitives (no fdlopen, no libssl; interops with OpenSSL 3.x) — exactly what [ADR 0007](../adr/0007-network-transport-security.md) required. The old `lib/tls.cyr` libssl-via-fdlopen path is no longer the only option; the blocker [`issues/archived/2026-05-13-sandhi-first-party-tls-surface-needed.md`](issues/archived/2026-05-13-sandhi-first-party-tls-surface-needed.md) is archived **RESOLVED**. sit's `URL_SCHEME_HTTPS` validator + `wire_transport_check_*` dispatch (v0.7.1) are scaffolded; the **HTTPS** slot above tracks the wiring (a multi-release arc, not a single patch — TLS termination both ends + cert handling).
- **mTLS** — builds on HTTPS; `tls_native_new_server` + client-cert verify primitives exist. Slots after HTTPS read/write lands.
- **Bearer auth over SSH** (belt-and-suspenders) — not gated on anything external; `_ssh_handle_auth_token` flips from stub to real, `wire_ssh_open`'s capabilities probe detects `"auth":["bearer"]` and loads `~/.sit/serve.token` like the HTTP path. Slot whenever a consumer asks; until then, SSH's own key-exchange auth is the answer.

**Surface minimization candidate (open slot):**

- **Drop sandhi, hand-roll loopback HTTP/1.0 server on `lib/net.cyr`.** Sit uses ~6 of sandhi's 11,729 lines (`sandhi_server_*`). The cap raise made this not-required for the build, but the surface argument still holds — same pattern `wire_http.cyr` already uses for the client (built directly on `net` to dodge stdlib `http_get`'s 64 KiB recv cap). ~500 lines of new `src/serve.cyr` parser; trades the share-with-AGNOS-consumers argument for surface-area minimization. Slot if/when the trade-off lands.

### Longer horizon

Items that haven't yet landed in a numbered v0.8.x slot. The five items below the line ruler graduated to numbered slots above — kept here as anchors for the "see roadmap for the slot" pointer.

- **Integration tests in-tree** — promote the shell-level scenarios from `docs/guides/getting-started.md` into `tests/` with fixtures. Current `tests/sit.tcyr` is primitive-assert smoke only, and the bash-based CI smoke steps don't surface failures with the same precision a Cyrius `.tcyr` runner does. Not slotted yet — depends on whether the closeout pass (v0.8.x last) gets there first or this lands separately.
- **Bench fixture refresh** — three bench targets scoped during v0.6.0 but never landed (LCS diff at 100×100 / 1000×1000 / 4000×4000; `glob_match` against 10/50/200-pattern `.sitignore` files; `hash_file_as_blob` end-to-end on 1 KB / 64 KB / 1 MB inputs). The first two slot naturally alongside v0.8.8 (`.sitignore` semantics rewrite); the third should accompany any future sigil/SHA-256 throughput work.
- **`sit serve` non-loopback exposure** — gated by HTTPS landing. Today `--listen 127.0.0.1:<port>` is parse-locked at the validator; non-loopback exposure waits for transport security so an unsecured HTTP daemon can't accidentally ship.
- **HTTPS CA-chain + hostname verification (post-v1 opt-in)** — decided 2026-06-10: ship HTTPS with TOFU/pinned trust first (see the **HTTPS** slot), then add an opt-in CA path for public-CA-signed `sit serve` deployments. Git-shaped config knobs (`http.sslVerify` to toggle, `http.caBundle` to point at a PEM, default to system store via `tls_native_set_ca_system`) driving `tls_native_client_verify_chain` + `tls_native_client_verify_hostname`. Lets a `sit serve` behind a Let's-Encrypt cert be cloned without a first-use prompt. TOFU stays the default; CA is opt-in. Slotted for after v1.0.0.

---

**Graduated to numbered slots (linked above):**

- ~~Reject push to checked-out branch~~ → v0.8.4 ✅ (`denyCurrentBranch` default refuse, shipped 2026-05-13)
- ~~`sit fsck` reachability~~ → v0.8.5 ✅ (BFS walker + dangling output, shipped 2026-05-15)
- ~~Wire-walker multi-parent fix~~ → **v0.8.7 ✅** (parents-vec at `out+48`; shipped 2026-06-10 — slid from v0.8.6, which shipped as the cyrius 6.x toolchain refresh instead)
- Full `.sitignore` semantics → v0.8.8 (slid one slot; wire-walker took v0.8.7)
- `sit log --graph` → v0.8.9 (bundled with shallow clone)
- Shallow clone (`--depth N`) → v0.8.9 (bundled with `log --graph`)
- HTTPS via `tls_native` → unblocked at v0.8.6; slotted (number TBD relative to `.sitignore` / `log --graph`)
