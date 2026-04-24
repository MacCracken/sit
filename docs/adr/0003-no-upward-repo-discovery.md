# 0003 — sit does not search upward for `.sit/`

**Status**: Accepted
**Date**: 2026-04-24

## Context

Git walks upward from the current directory looking for a `.git` repo — a repository deep in `/tmp/victim/subdir/` will find `/tmp/victim/.git` and trust its config. This is the mechanism behind [CVE-2022-24765](https://nvd.nist.gov/vuln/detail/cve-2022-24765): a malicious user who can plant a `.git/config` anywhere above a victim's working directory gets arbitrary command execution (via `core.pager`, `core.sshCommand`, `core.fsmonitor`, etc.) the next time the victim runs any git command in that tree. Git's fix was `safe.directory` — a new config gate that opts directories into being trusted. The fix is necessary for a tool that searches upward; it's not necessary for a tool that doesn't.

sit's every entry point that touches a repository starts with a `file_exists(".sit/HEAD")` check in the current working directory. No upward walk. This decision predates the audit by design — sit came up in a post-CVE-2022-24765 world and intentionally skipped the upward-discovery step.

## Decision

**sit looks for `.sit/HEAD` in the current working directory only.** If the file isn't there, the command exits with `not a sit repository (run 'sit init')`. No parent-directory search. No config-file search above the repo. No equivalent to git's `GIT_DIR` env var that could escape the cwd.

This is a **permanent** design decision, not a provisional one. Future commands and future transports inherit it.

## Consequences

- **Positive**
  - CVE-2022-24765-class attacks are structurally impossible. A hostile `.sit/config` planted in `/tmp` or any parent dir is inert.
  - No `safe.directory` config to maintain. No per-user trust decisions. No "this repo is owned by uid 1001 but you're uid 1000" prompts.
  - Clear, predictable mental model: "sit acts on the repo at `$PWD`." Script authors don't have to reason about which `.sit/` got picked up.
  - Shell scripts that `cd $REPO && sit status` work identically to running in `$REPO` directly.
- **Negative**
  - Users who are used to `git status` working from a subdirectory are surprised when `sit status` doesn't. This is mitigated by the error message ("not a sit repository (run 'sit init')") pointing at `sit init`, which is usually enough to realize they're in the wrong directory.
  - Tools that build on sit's CLI can't rely on "am I somewhere inside a sit repo?" discovery. They must walk upward themselves if they want that.
- **Neutral**
  - A future `sit root` command could offer opt-in upward walk for display purposes only — never for decision-making about which repo to act on. That would be an explicitly safer subset of git's behavior.

## Alternatives considered

- **Implement upward search with a `safe.directory` gate.** This is git's answer. Rejected: the gate is a complexity and UX tax; "no upward search" achieves the same security outcome by never going looking. Sit doesn't need the `git -C $DIR` ergonomic because it has no multi-tenant-hosting use case yet.
- **Implement upward search unconditionally.** Rejected: directly recreates CVE-2022-24765.
- **Accept a `SIT_DIR` env var override.** Considered; not needed today. If a future use case demands it, it will be accepted only for `$SIT_DIR`-relative command dispatch (not directory walking), which preserves the "sit acts on one explicit repo" invariant.

## Regression protection

Add an integration test: create a sit repo, cd into a subdirectory, run `sit status` and assert exit != 0 and stderr contains `not a sit repository`. Same test for `sit log`, `sit commit`, `sit fetch`. (Not yet implemented in `tests/sit.tcyr`; queued alongside the v0.6.0 integration-test expansion.)

## References

- [CVE-2022-24765 — NVD](https://nvd.nist.gov/vuln/detail/cve-2022-24765)
- [git-scm blog: "Git security vulnerabilities announced" (2022)](https://github.blog/2022-04-12-git-security-vulnerability-announced/)
- [docs/audit/2026-04-24-audit.md § S-29](../audit/2026-04-24-audit.md)
