# 0008 — SSH transport: process boundary, not FFI

**Status**: Accepted
**Date**: 2026-05-13

## Context

[ADR 0007](0007-network-transport-security.md) pinned: no libssl, no libcrypto, no exception. HTTPS via libssl will not ship in sit until first-party Cyrius TLS exists. That left sit's read-side encrypted-over-internet path empty in v0.7.x — HTTP is loopback / private-network / behind-tunnel only by design.

v0.8.2 ships SSH transport (`ssh://`) to close that gap without breaking ADR 0007: SSH already exists, is universally deployed, owns the encryption + auth handshake out of the box, and (critically) is a separate binary on the operating system — not a library sit links against.

The architectural question this ADR settles: **how does sit consume SSH?** Two shapes are technically possible:

1. **Process boundary**: sit fork+execs `ssh user@host -- sit serve --stdio`; the SSH binary owns crypto; sit's wire is the same HTTP/1.1 it already speaks over TCP, just riding the SSH-managed stdin/stdout pipes.
2. **Library link**: sit links against libssh / libssh2 (or fdlopen-bridges it like `lib/tls.cyr` did with libssl); SSH crypto runs in sit's address space; sit speaks the SSH binary protocol directly.

This ADR pins choice 1.

## Decision

**SSH integration uses fork+exec on the system's `ssh` binary, treating it as a separate process whose stdin/stdout we own.** Sit's wire protocol (HTTP/1.1 over the pipes) is identical to the TCP path; only the transport changes.

Concretely:

- `wire_ssh_open(url)` parses `ssh://[user@]host[:port]/<repo-path>`, creates two pipes via `sys_pipe`, forks once, and in the child `sys_execve`s an absolute-path `ssh` binary with argv `["ssh", "-T", optional "-p" port, "--", "user@host", "sit", "serve", "<repo-path>", "--stdio"]`.
- envp is curated explicitly to the minimum ssh needs: `HOME` (for `~/.ssh/{config,known_hosts,authorized_keys}`), `USER` / `LOGNAME` (default username), `SSH_AUTH_SOCK` (ssh-agent socket), `TERM`, `PATH` (for ProxyCommand). Full-env inheritance is rejected as a leak surface for `SIT_AUTHOR_*` / `GIT_*` etc.
- The remote side runs `sit serve --stdio` (v0.8.2 new mode), which reads HTTP/1.1 requests from stdin and writes responses to stdout with a pipelining-safe parser that preserves any carryover bytes between requests.
- Authentication is fully ssh's responsibility — keys, agent, known_hosts, password prompts. Sit never sees credentials.
- One ssh child per remote operation; many HTTP requests per ssh session (keep-alive, no per-request handshake cost).

## Consequences

- **Positive**: no crypto in sit's address space. ADR 0007's no-FFI thesis stays unviolated for the encrypted-over-internet path. Sit binary stays statically-linked, no dynamic dep on libssh/libssl, no version-skew between sit's bundled SSH and the host's.
- **Positive**: matches git's `ssh://` design — `git fetch ssh://user@host/path` shells out to `ssh user@host -- git-upload-pack <path>` exactly the same way. Sit users hitting `ssh://` URLs get familiar behavior; their `~/.ssh/config` aliases / agent setup / authorized_keys / known_hosts all apply unchanged.
- **Positive**: ssh's CVE history is owned by OpenSSH maintainers, not sit. Sit inherits security updates for free via `apt upgrade openssh-client` (or equivalent).
- **Positive**: testing isolation — `sit serve --stdio` can be exercised without an SSH layer (`printf 'GET /sit/v1/refs HTTP/1.1\r\n...' | sit serve --stdio`), so wire-level bugs aren't conflated with ssh-config issues.
- **Negative**: per-session ssh handshake cost — auth + key exchange = ~50 ms on a typical LAN, more over the WAN. Mitigated by pipelining many requests through one session (mirrors HTTP/1.1 keep-alive). Per-request overhead is the same as TCP HTTP (one round-trip).
- **Negative**: depends on `ssh` being on `$PATH` (or under one of the searched locations `/usr/bin:/usr/local/bin:/bin`). A minimal container without ssh fails with `sit: ssh binary not found on $PATH`. Acceptable — every reasonable host has `ssh`.
- **Negative**: `sys_execve` is the raw syscall — no PATH lookup. Sit walks PATH itself in `_ssh_find_binary`. Tiny duplicated effort; the alternative (libc `execvp`) would mean FFI for a one-line search loop, not worth the trade.
- **Negative**: env curation is a maintenance surface — if ssh grows a new required env var (e.g. for a future agent protocol), sit's curated list goes stale. Mitigated by the explicit list being documented here and in `wire_ssh.cyr`; the failure mode is loud (ssh exits with a clear error), not silent.

## CVE-2017-1000117 defense

The 2017 git/ssh URL injection class — `ssh://-oProxyCommand=touch+/tmp/PWNED/host/repo` — comes from passing a user-controlled URL component as an argv element to `ssh`. If the component starts with `-`, ssh interprets it as a CLI flag, not a hostname. `-oProxyCommand=<command>` then runs arbitrary code on the client.

Sit defends in three layers:

1. **`remote_url_valid` whitelist** (`src/validate.cyr`, v0.7.1): URL body characters are restricted to `[a-zA-Z0-9.-_/:@%~]`. A `-` is in the allowed set (needed for hostnames like `my-server.example.com`), so this layer is necessary but not sufficient.
2. **`_ssh_parse_url` explicit leading-dash rejection** (`src/wire_ssh.cyr`, v0.8.2): the parser checks the first byte of the user component, the host component, and the path component's first segment; any leading `-` fails the parse with a clear error.
3. **`--` argv sentinel in the exec'd argv**: even if a `-`-prefixed component somehow slipped through, the `--` sentinel between ssh's options and its positional args tells ssh "everything past here is a hostname / command, not a flag." Combined with sit constructing the argv via `sys_execve` (no shell interpolation), there's no path for shell-metacharacter injection either.

Smoke test (in CI for v0.8.5+ once sshd is wired): `sit clone ssh://-oProxyCommand=touch+/tmp/PWNED/host/repo` must exit non-zero with no `/tmp/PWNED` side-effect.

## Alternatives considered

1. **Link libssh2.** Same FFI hole [ADR 0001](0001-no-ffi-first-party-only.md) forbids. Plus libssh2 has its own CVE history (memcpy bounds, sftp UAF, kex MITM via downgrade) that would land squarely in sit's threat model rather than the OpenSSH project's. Rejected.

2. **Native Cyrius SSH client.** Plausible long-term — sandhi's first-party Cyrius TLS arc (v1.3.2+) proves it's doable for a comparable protocol. SSH is significantly more complex than TLS (multiplexing, dynamic forwarding, agent protocol, key formats, kex algorithms), so the lift is multi-quarter. Rejected for v0.8.x; revisit when sandhi grows an SSH layer (`sandhi/ssh_*`).

3. **libssh-via-fdlopen** (mirror of the `lib/tls.cyr` libssl-via-fdlopen path that ADR 0007 explicitly rejects for the TLS case). Same critique applies — punches the no-FFI hole through a side door. Rejected on the same reasoning that rejected the TLS-shim path.

4. **Skip SSH entirely; wait for HTTPS via first-party Cyrius TLS.** Plausible but means sit has no encrypted-over-internet read path until sandhi's TLS arc lands as a sit-consumable surface. Owl (and any other downstream consumer that wants to clone sit repos over a public network) is blocked indefinitely. Rejected — SSH-as-process is universally available now and matches what git users expect.

5. **HTTP-over-SSH tunnel as a manual user step** (`ssh -L 8484:localhost:8484 host` then `sit clone http://localhost:8484/...`). Works today without sit changes, but pushes the operational burden onto every user. Rejected as the primary path; remains valid as an escape hatch for users who want HTTP/1.1 explicitly.

## v0.8.2 scope notes

- **Read-only.** `sit clone` and `sit fetch` over `ssh://` work. Push over SSH lands in v0.8.3+ — same pipeline as the v0.7.6 HTTP push but layered onto the persistent stdio session. `wire_transport_check_writable` rejects `ssh://` with `"push over ssh requires sit 0.8.3+ (read-only ssh is available now)"`.
- **No batch /want yet over SSH.** `ssh_remote_check_batch` analog deferred to a follow-up. Per-object GET is fast enough on a single ssh session (no per-request handshake cost) that the batch win is smaller than over TCP.
- **Identity-file selection** is via the user's `~/.ssh/config`. Sit doesn't expose `-i <path>` itself; users who need a specific key set it up the standard ssh way:
  ```
  # ~/.ssh/config
  Host my-sit-host
      IdentityFile ~/.ssh/sit-deploy-key
      IdentitiesOnly yes
  ```
  Then `sit clone ssh://my-sit-host/repo` picks the right key.
- **`-T` flag**: passed unconditionally to disable pseudo-terminal allocation. Sit drives stdin programmatically; a TTY would just emit a stderr warning ("Pseudo-terminal will not be allocated because stdin is not a terminal") without changing behavior. Cleaner to suppress.

## References

- [ADR 0001](0001-no-ffi-first-party-only.md) — the no-FFI thesis this decision is consistent with.
- [ADR 0007](0007-network-transport-security.md) — the no-libssl decision SSH unblocks at this release.
- OpenSSH advisory archive: https://www.openssh.com/security.html
- git's `ssh://` integration (for reference shape): https://git-scm.com/docs/git-fetch#_ssh
- CVE-2017-1000117 — git ssh URL injection: https://bugs.chromium.org/p/project-zero/issues/detail?id=1374
