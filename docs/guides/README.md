# Guides

How-to material for working on or with sit. Task-oriented. If a reader has a clear goal ("I want to build sit", "I want to add a subcommand"), a guide should get them there.

## Index

- [Getting started](getting-started.md) — build sit from source, run your first `sit init`, and walk every shipped command: the local loop (init/add/rm/commit/log/status/diff/show/merge/merge-base/branch/checkout/tag/reset/config/fsck/cat-file/owl-file), signing (key/verify-commit), network sync (remote/fetch/pull/push/clone/serve over file/http/https/ssh), and **reading an existing git repository** read-only (git-aware `cat-file`/`owl-file` over `.git/` loose objects + packfiles, SHA-1/SHA-256; 1.2.0).

For an end-to-end *runnable* script covering the same ground in one go, see [`../examples/local-vcs-loop/`](../examples/local-vcs-loop/).

## What doesn't belong here

- **Decisions** → [`../adr/`](../adr/)
- **Constraints and quirks** → [`../architecture/`](../architecture/)
- **Runnable code** → [`../examples/`](../examples/)
