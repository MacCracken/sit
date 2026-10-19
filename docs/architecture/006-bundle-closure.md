# 006 — Bundle closure: nothing reachable in `[lib]` may call outside it

**Status**: invariant of the dist bundles ([ADR 0013](../adr/0013-dist-bundle-profiles.md)); enforced by the compiler since cyrius 6.6.9.
**Affects**: every module in `cyrius.cyml [lib]` / `[lib.read]`, and anything that calls into `src/wire_ssh.cyr` or `src/wire_https.cyr`.

## The constraint

`dist/sit.cyr` is compiled **into the consumer's program**, not into sit's. sit's own build includes every module through `src/lib.cyr`, so an undefined call never shows up there. Only a consumer build of the bundle can reveal one.

Since cyrius **6.6.9**, a **reachable** call to an undefined function is a hard error: `refusing to emit binary with N reachable undefined function(s)`. Before 6.6.9, a reference from an unreachable function that appeared first in the fixup table hid every later reachable call to the same name, so the build emitted a binary that would trap at the call.

Two facts make "reachable" wider than it looks:

- **An address-taken function is a root.** `serve.cyr` passes `&serve_handle_request` to `sandhi_server_run`. That keeps `serve_handle_request` and everything it calls live in **any** program that includes the full bundle, including a read-only probe that never calls `cmd_serve`.
- **Reachability is the compiler's, not the consumer's.** The consumer does not have to call a path for that path to count.

So: **every function reachable from a `[lib]` module must be defined inside that profile's module set.** Calls into `wire_ssh.cyr` / `wire_https.cyr`, which are deliberately in neither profile, are allowed only from functions the compiler judges unreachable in a consumer.

## What 1.6.3 changed

`_wire_io_send` / `_wire_io_recv`, the plain-or-TLS socket I/O shared by the HTTP client and the server, were defined in `wire_https.cyr`. The `&serve_handle_request` root made `_serve_send_status` → `_wire_io_send` reachable, so at cyrius 6.6.20 **no consumer could compile `dist/sit.cyr`**. The helpers now live in `wire_http.cyr`, which is in `[lib]`. The TLS handshake (`_wire_https_connect`) and the TOFU pin store stay in `wire_https.cyr`.

The read profile was unaffected: it carries neither `wire_http` nor `serve`.

## Symbols currently left unresolved, and why that is safe

| bundle | unresolved | why it is unreachable |
|---|---|---|
| `dist/sit.cyr` | `wire_ssh_open` / `wire_ssh_close`, `ssh_remote_*`, `_ssh_set_auth_token` (1.7.0), `_wire_https_connect`, `_url_is_http_family` | reached only from the client side: `wire.cyr`'s clone / fetch / push dispatch and `wire_http.cyr`'s request functions, which no address-taken root reaches |
| `dist/sit-read.cyr` | `load_signing_seed`, `sign_commit_body`, `verify_commit_body` | reached only from commit's signing path, which the read API never calls |

These names print as `warning: undefined function` in a consumer build. That is expected. A `(reachable call site)` suffix is not: it means a new root or a moved call has pulled a transport or signing path into the bundle.

## How it is guarded

`tests/integration/run.sh` compiles `tests/integration/git_probe.cyr` against the **shipped** `dist/sit.cyr`, then asserts `sit_repo_branch` / `sit_repo_status` against a real `.git/` repo. If `cyrius` is on `PATH` and the probe does not compile, that is a **FAIL**, not a skip. (Through 1.6.2 a compile failure was reported as "toolchain not found", which is how this breakage could have passed CI.)

When adding a callback (`&fn`) or a new call from a `[lib]` module into `wire_ssh` / `wire_https`, move the callee into the bundle or keep the caller unreachable, then run the integration suite.
