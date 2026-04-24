# 0005 — Local-clone threat model

**Status**: Accepted
**Date**: 2026-04-24

## Context

sit v0.5.0 shipped a local-path wire protocol: `sit clone /path/to/repo`, `sit fetch <remote>`, `sit push <remote>` against bare-path and `file://` URLs. The implementation opens the remote's `.sit/objects.patra` directly, walks reachability, copies objects. No network, no subprocess, no libgit2.

This is a real attack surface even without network transport. A user might `sit clone /tmp/repo-shared-by-a-coworker` where the repo has been crafted by someone else. The threats are:

1. **Path traversal via tree entry names** — malicious tree objects containing entries named `../../../etc/cron.d/pwn` or `/tmp/victim-data`. This is [CVE-2018-11235](https://nvd.nist.gov/vuln/detail/CVE-2018-11235) and [CVE-2024-32002](https://www.cvedetails.com/cve/CVE-2024-32002/) in git; sit had it too (audit finding S-03).
2. **Symlink follow on remote `.sit/` directory** — if the "remote path" has `.sit/` as a symlink pointing at `/etc/shadow`, patra opens that. [CVE-2023-22490](https://nvd.nist.gov/vuln/detail/CVE-2023-22490) in git.
3. **Config newline injection via URL** — `sit remote add origin $'file:///ok\nother.key = payload'` writes a second config line. [CVE-2023-29007](https://nvd.nist.gov/vuln/detail/CVE-2023-29007) / [CVE-2025-48384](https://github.blog/open-source/git/git-security-vulnerabilities-announced-6/) in git.
4. **Refname path traversal via fetch-receive** — a remote advertising a branch named `../../../etc/cron.d/x` writes to `.sit/refs/remotes/origin/../../../etc/cron.d/x`. Same attack class as the tree-name case.
5. **SQL injection via hash prefix** — `sit cat-file "abc' OR 1=1"` interpolated into patra's `LIKE` query. Local-only today, but will expose remotely once network transport lands.

## Decision

sit's local-clone trust boundary is explicit. Everything below is **not trusted**:

- The bytes inside the remote's `.sit/objects.patra` (object content, tree entry names, commit bodies, ref file contents).
- Filesystem layout of the remote's `.sit/` directory (symlinks, file perms).
- The URL string itself (attacker-controlled in a `sit clone` invocation).
- Ref names advertised on the fetch-receive side.

Trust boundaries and their enforcement:

1. **Tree entry names** gate through `tree_entry_name_valid` in `parse_tree` (rejects the entry inline). `materialize_target` additionally gates through `tree_flat_path_valid` on the post-`flatten_tree` full path. Tree entry modes gate through `tree_entry_mode_valid` — only `100644` (file) and `40000` (dir) accepted. See src/validate.cyr.
2. **Remote `.sit/` and `.sit/objects.patra`** are `lstat`-checked before open (`path_is_symlink`). Symlinks at either path refuse the operation. Same for `read_remote_ref`.
3. **URLs** gate through `remote_url_valid`. v0.6.0 accepts **only** `file://` schemes, absolute paths, and `./`-relative paths. Leading `-` is rejected (CVE-2017-1000117 prophylactic for the day a transport forks a subprocess).
4. **Config values** gate through `config_value_valid` at the `config_file_set` boundary. Newlines, CRs, and NULs are rejected in both keys and values.
5. **Ref names on both sides** gate through `refname_valid` (git `check-ref-format` grammar): no `..`, no leading `.`, no `.lock` suffix, no control chars, no `~ ^ : ? * [ \ @{`. Applied in every ref-writer (branch/tag/checkout -b, remote_add, write_remote_tracking).
6. **Hash prefixes** gate through `hex_prefix_valid` before SQL interpolation in `resolve_hash`.

## Consequences

- **Positive**
  - A malicious `sit clone` source cannot write outside the clone target directory, cannot follow symlinks out of the repo, cannot inject config lines, cannot poison refs, cannot SQL-inject.
  - The validators live in one file (`src/validate.cyr`) — easy to review, easy to extend, easy to test (101 assertions as of v0.6.0).
  - Same validators protect the eventual HTTP / SSH transports (v0.7.x). The network-layer CVE classes reduce to the validator correctness question.
- **Negative**
  - Valid-but-unusual tree entry names (e.g. files literally named `CON.txt` on a Linux-hosted repo) are refused. This is intentional — preventing Windows-targeting attacks means blocking a few edge-case Linux-valid names. The fsck tool will flag such entries so authors know to rename.
  - Strict refname grammar means some names git accepts (e.g. weird Unicode) are rejected by sit. Documented in the getting-started guide.
  - Every refname / config / URL check adds a few microseconds of CPU. Negligible on realistic workloads.
- **Neutral**
  - HFS-ignorable Unicode codepoints ([CVE-2014-9390](https://developer.atlassian.com/blog/2014/12/securing-your-git-server/)) aren't handled byte-level in v0.6.0. That check belongs in a Unicode-aware layer and is flagged for v0.7 when sit gains a macOS / Windows port. Not an issue on Linux-only deployments.
  - sit allows push to a checked-out branch (git's `receive.denyCurrentBranch` default is `refuse`). Tracked as a backlog item — adds complexity for an edge case (remote is an active workstation) that isn't directly a security risk, just a surprise.

## Alternatives considered

- **Reject all untrusted clones** — require a manifest file signed by a trusted key before sit accepts any content from a remote. Rejected: that's a separate feature (signed-commit chain-of-trust exists in sigil; extending to clone is v0.7+ work) and would make casual use of `sit clone` painful.
- **Single-file "gatekeeper" that validates every attacker-controlled byte at one chokepoint** rather than scattered validators. Attempted during the v0.6.0 audit fix phase; rejected because the chokepoint would need to know about every consumer's format (tree entries vs ref names vs config values are different grammars). Separate validators in one file is the middle ground.
- **Trust the remote's `.sit/` as-is, on the theory that a user `sit clone`-ing a hostile repo is already compromised.** This is approximately git's pre-2018 position. Rejected: it conflates "user picked a bad repo" with "user's filesystem is now arbitrary-write-owned."

## Future work

When network transports land (v0.6.0+):

- The `remote_url_valid` allowlist expands to `http://`, `https://`, `ssh://`, with the leading-dash check still in place.
- A new validator for HTTP response headers (Content-Length caps, unexpected Transfer-Encoding, etc.) will join `src/validate.cyr`.
- The symlink-check approach extends to server-advertised resource URIs (pack-bundle URIs, object bundle URIs) — the CVE-2025-48385 class. Already factored so this slots in without redesign.

## References

- [CVE-2018-11235](https://nvd.nist.gov/vuln/detail/CVE-2018-11235)
- [CVE-2023-22490](https://nvd.nist.gov/vuln/detail/CVE-2023-22490)
- [CVE-2023-29007](https://nvd.nist.gov/vuln/detail/CVE-2023-29007)
- [CVE-2024-32002](https://www.cvedetails.com/cve/CVE-2024-32002/)
- [CVE-2025-48384 — git refname handling, actively exploited](https://github.blog/open-source/git/git-security-vulnerabilities-announced-6/)
- [git-check-ref-format(1)](https://git-scm.com/docs/git-check-ref-format)
- [docs/audit/2026-04-24-audit.md](../audit/2026-04-24-audit.md) — findings S-01 through S-05
