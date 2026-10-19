# 0014 — Bearer tokens are bound to remotes

**Status**: Accepted
**Date**: 2026-10-19 (1.7.0; closes audit finding C3, [2026-10-19 audit](../audit/2026-10-19-audit.md))

## Context

`sit serve --require-auth` gates writes with a bearer token read from `~/.sit/serve.token` by default. The client used that same file as its credential.

Through 1.6.4 the client sent it:
- to any http(s) remote whose `/sit/v1/capabilities` advertised `"auth":["bearer"]`
- on every POST to any ssh remote, whatever the server advertised

So pushing to a third-party or compromised server handed it the token that guards the user's own server. The plain `http://` client also accepts any IPv4 literal, so the token could travel in cleartext to a host off this machine.

The file was doing two jobs: "the token my server accepts" and "the token I present to servers". Both readings are right for the case it was built for, pushing to your own `sit serve` on loopback, and wrong for every other case.

## Decision

**A bearer token is presented only to a remote it is bound to.**

1. **`remote.<name>.tokenFile`** names a token file for that remote, and only that remote. `~/` expands to `$HOME`. It is loaded by the same `token_file_load` the server uses:
   - a regular file, never followed through a symlink
   - mode exactly 0600
   - 16+ printable bytes

   A configured file that fails to load is an **error**, never a silent "no token".
2. **Unbound, loopback:** an http(s) remote on 127.0.0.0/8 with no `tokenFile` gets `~/.sit/serve.token` if it exists. That remote is this machine, and the file is this machine's own server token. This keeps the original single-machine workflow working unchanged, including CI's push smoke.
3. **Unbound, anywhere else:** no token is sent. A server that requires one gets a refusal that names the config key to set.
4. **No cleartext tokens off the machine:** plain `http://` to a non-loopback host never carries a token, even when bound. The answer is https or ssh.
5. **ssh** carries a token only when the remote is bound; there is no implicit fallback. An ssh remote is another host by definition.

## Consequences

- **Positive:** the server's credential no longer leaves the machine by default. Every remote that receives a token was named by the user, and nothing travels in cleartext off-host.
- **Positive:** client and server share one token loader, so the format, mode and symlink rules are defined once. The client used to skip the mode and symlink checks.
- **Negative (migration):** pushing with bearer auth to a **non-loopback https remote or an ssh remote** now needs one line of config:

  ```sh
  sit config remote.<name>.tokenFile ~/.sit/serve.token
  ```

  Pushes to a loopback `sit serve` are unaffected.
- **Neutral:** a token file per remote means different servers can use different tokens, which was not expressible before.

## Alternatives considered

- **Keep the implicit token, but only send it after a TOFU-style "first push to this host" prompt.** Rejected: sit has no interactive prompts, and a prompt fatigues into "yes".
- **Bind by URL host instead of remote name.** Rejected: remotes are already the user's named, configured destinations. Host binding would also need canonicalisation (`localhost` vs `127.0.0.1`, ports) that remote names avoid.
- **Refuse unbound remotes outright, loopback included.** Rejected for now: it breaks every existing single-machine setup, including CI's smoke, to close a gap that does not exist on loopback (the token is presented to the server that owns it).
- **Allow tokens over plain http when bound.** Rejected: binding says whom to trust, not that the network path is private. sit serve already refuses to serve plain http off loopback (1.6.0), so a legitimate plain-http non-loopback target is a reverse-proxy misconfiguration, and https is the fix.
