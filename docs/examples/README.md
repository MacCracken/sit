# Examples

Runnable, self-contained code that shows how to use sit from the outside — shell sessions, scripts, integration sketches.

Each example is its own subdirectory with a `README.md` explaining what it demonstrates and a runnable artifact (shell script, Cyrius program, etc.).

## Index

- [local-vcs-loop](local-vcs-loop/) — end-to-end shell walkthrough covering init, add, branch, signed commit, merge, status, diff, show `--stat`, verify-commit, and fsck. Useful as a smoke check after touching cross-command flows.

Network sync (clone / fetch / push over file / http / https / ssh, plus shallow clone and `merge-base`) is exercised end-to-end by the in-tree integration suite, [`tests/integration/run.sh`](../../tests/integration/run.sh) — runnable locally (`SIT=build/sit tests/integration/run.sh`) and the canonical worked example of the transport flows. The 1.2.0 **`.git/` read-mode** (git-aware `cat-file` / `owl-file` on an existing git repo, loose + packed, SHA-1/SHA-256) is likewise covered by that suite's `.git/ read-mode` block rather than a standalone example. The `sit serve` / clone-over-network recipes are in [getting-started § Serve and sync over the network](../guides/getting-started.md#serve-and-sync-over-the-network).
