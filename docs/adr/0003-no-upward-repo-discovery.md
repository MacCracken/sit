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

Candidate for the in-tree integration suite ([`tests/integration/run.sh`](../../tests/integration/run.sh)): create a sit repo, `cd` into a subdirectory, run `sit status` and assert a non-zero exit with `not a sit repository` on stderr — same for `sit log`, `sit commit`, `sit fetch`. The "not a sit repository" guard itself ships in every `cmd_*` (each checks `file_exists(".sit/HEAD")` against the current directory only, never walking upward).

## References

- [CVE-2022-24765 — NVD](https://nvd.nist.gov/vuln/detail/cve-2022-24765)
- [git-scm blog: "Git security vulnerabilities announced" (2022)](https://github.blog/2022-04-12-git-security-vulnerability-announced/)
- [docs/audit/2026-04-24-audit.md § S-29](../audit/2026-04-24-audit.md)

## Amendment (1.13.1) — a symlink is not a way out of `$PWD`

"sit acts on the repo at `$PWD`" held for the search and not for what it found. Nothing looked at what `.sit`, `.git` or HEAD were, so `.git -> ../victim/.git`, or a `.sit/HEAD` linked to `../../victim/.git/HEAD`, made `sit status` print `On branch <the other repository's branch>`. A symlink is a `GIT_DIR` that the directory sets for itself, which this ADR rejected. It matters because status runs unasked: commandress's `vcs` segment runs it in whatever directory a prompt is in, and sees only its stdout, so the rule has to be sit's. Found by a review of commandress on 1.13.0.

**Every command that opens a repository now asks one test, `_store_leaves`.** The read commands and `sit_repo_open` reach it through `_detect_repo_backend` (`cli_read_repo`), and the rest through `cli_sit_repo`. `init`, `remote`, `gc` and `serve`, which each have something of their own to do when there is no repository, ask `cli_store_refused`. Writes refused a link already at the ref (`_sf_parent_symlink`), but that was the last step, and not every step went there: through `.sit -> ../victim/.sit`, `sit add` staged into the other repository, `sit remote list` printed its URLs, credentials included, and `sit init` reinitialized it. `sf_exists` follows a link, so it cannot be a command's gate.

- **`.sit` or `.git` as a symlink** is accepted only if it stays in the directory: relative, no `..` component, and no further link on the way. The link is judged, not where it lands, so this needs no `realpath` and no cwd, which AGNOS does not have.
- **A symlinked HEAD is never followed.** Its text is the ref name, under the checks a `ref: ` line passes (`refname_valid`, under `refs/`). Anything else is refused. This is git's own rule (`validate_headref`, `core.preferSymlinkRefs`). Not following matters: `HEAD -> refs/heads/x`, with `x` linked to another HEAD, passes on spelling alone.

A refused command exits 1 and says why, and `sit_repo_open` returns 0. `sit clone`, `sit key` and `sit completions` open no repository here, and `sit serve --repos` already required `.sit` to be a directory and HEAD a file (`_serve_repo_check`).

| Layout | Through 1.13.0 | Since 1.13.1 |
|---|---|---|
| A symlinked working directory (`cd link`, or `sit_repo_open` by a linked path) | reads | reads: only the last component is looked at |
| Linked worktree, submodule, `--separate-git-dir` (a `.git` file, `gitdir: ...`) | not a sit repository | the same: sit has no `gitdir:` reader |
| `.git/HEAD -> refs/heads/main` | reads, as `(detached)` | reads, as `main`, as git does |
| `.git -> meta/git`, a link that stays inside | reads | reads |
| `.git -> ../anything`, or an absolute link | reads | refused |

sit is stricter than git here. git follows a `.git` symlink, and a `gitdir:` file, wherever it leads. A `gitdir:` file is as hostile as a link: `gitdir: ../victim/.git` shows the victim's branch under git, and reads as no repository under sit only because sit has no reader. A reader added later goes through this gate, and needs git's back-link check as well.

**What this costs.** A store linked from outside the directory stops reading, and its shape cannot be told from the attack. That includes Android `repo` checkouts (`.git -> ../../.repo/projects/...`) and a store moved by hand. There is no allow-list, since this ADR rejected `safe.directory`. Move the store into the directory, or link it from there.

**What this does not close**, on the [roadmap](../development/roadmap.md): links below a real store. A `.git/` directory whose `refs` and `objects` link out reads the other repository, and `sit status` lists its tracked paths as `deleted:`, as git does. `git-new-workdir` makes this shape, so a refusal needs its own decision, and `objects/info/alternates` reaches as far on purpose ([ADR 0011](0011-git-read-mode.md)).
