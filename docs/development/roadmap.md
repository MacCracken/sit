# sit Development Roadmap

> **v0.1.0** — Sovereign version control for Cyrius. Scaffold + `init` + `add` loop working; `sit commit` is the next move.

## Completed

### v0.1.0

- Initial project scaffold via `cyrius init sit` — stdlib baseline, test/bench/fuzz harnesses, CI workflows.
- `cyrius.cyml` dep layout following yukti conventions — sakshi 2.1.0, sankoch 2.0.1, sigil 2.9.1, patra 1.5.5 git-tag pinned. Expanded stdlib list to cover transitive reach of the git deps (cyrius 5.6.x has no transitive resolution; 5.7.x targeted).
- `sit init` — creates git-parity `.sit/{HEAD,objects,refs/heads}` layout; HEAD is `ref: refs/heads/main\n`; idempotent re-init.
- `sit add <path>` — sigil SHA-256 object IDs, sankoch zlib compression, loose-object storage at `.sit/objects/<hex[0:2]>/<hex[2:64]>`. Framing is `"blob <len>\0<content>"` — hashes are byte-identical to git's SHA-256 object format for the same content. Plaintext staging index at `.sit/index`.
- Documentation scaffold: `docs/{adr,architecture,guides,examples,development}/`.
- ADR 0001 — no FFI, first-party only.
- Arch 001 — `args.cyr` post-return stack memory quirk (Cyrius stdlib).
- Arch 002 — loose-file objects until patra grows `COL_BLOB`.

### v0.1.1

- **`sit cat-file <hash>`** — plumbing read command. Decompresses an object, strips framing, writes content to stdout. Supports 4-char-minimum hash prefixes via `dir_list` scan of `.sit/objects/<xx>/`. Reports ambiguous / no-match / too-short errors with distinct exit messages.
- **`sit owl-file <hash>`** — decorated viewer. Resolves the object, writes content to `/tmp/sit-owl-<hash[0:12]>`, execs [owl](https://github.com/MacCracken/owl) via `exec_vec` at `/usr/local/bin/owl` → `/usr/bin/owl` → `/opt/owl/bin/owl`. Transparent fallback to raw content when owl is not installed (owl is currently pre-1.0 per its own roadmap).
- Internal helpers: `object_path()`, `resolve_hash()`, `read_object()`, `find_owl()`, `resolve_and_read()` shared by both read commands.

### v0.1.2 — `sit commit`

- **`sit commit [-m] <message>`** — writes a tree object from the staging index plus a commit object, and atomically updates `.sit/refs/heads/main`. Supports both positional (`sit commit "msg"`) and `-m` forms.
- **Refactor**: `write_blob_object` now delegates to a type-agnostic `write_typed_object(type, type_len, content, content_len)` — same primitive drives blob, tree, and commit writes. Blob hashes unchanged (verified via regression).
- **Tree format** is git-SHA-256 compatible: `<mode> <name>\0<32 raw hash bytes>` entries, sorted by name. Mode fixed at `100644` for v0.2 (no exec-bit detection). Verified byte-by-byte against `xxd` output.
- **Commit format** is git-compatible: `tree <hex>\n[parent <hex>\n]author ... committer ... \n<message>\n`. Author/email from `SIT_AUTHOR_NAME` / `SIT_AUTHOR_EMAIL` env, fallback `"sit user" <user@localhost>`. Timestamp via `clock_epoch_secs()`, timezone fixed at `+0000`.
- **Dedup on stage**: `sit add foo.txt; sit add foo.txt; sit commit` produces a tree with one `foo.txt` entry (last hash wins), not two.
- **Root-commit marker**: output reads `[main (root-commit) <hash>] <msg>` when no parent exists, `[main <hash>] <msg>` otherwise.
- Arch 003 — subdirectory paths deferred to v0.3.0 (recursive trees); commit rejects nested paths with a clear error.

## Post-0.1 Backlog

### Priority — the v0.2.0 loop

- **Recursive trees** (arch 003) — lift the flat-path restriction on `sit commit`. Path segmentation + per-directory subtree construction + git's directory-sort rule (`<name>/` vs `<name>`). Will likely coincide with v0.2.0's `sit status` / `sit log`, which need tree readers anyway.

### Working-tree visibility

- **`sit status`** — diff working tree vs staging index vs HEAD.
- **`sit log`** — walk commit parent chain from HEAD, print summary.
- **`sit diff`** — sankoch-backed text diff between two blobs / working tree / index.

### Storage migrations

- **Staging index into patra** — `index(path STR, hash STR, mode INT)` table. Fits current `COL_STR`/`COL_INT`, unblocks mutation semantics (`sit rm`, re-add updates existing row instead of appending). Likely the first real patra consumer in sit.
- **Objects into patra** — contingent on patra's roadmap `COL_BLOB` landing. Migrates sit off the loose-file object store; see [arch 002](../architecture/002-loose-objects-until-patra-blobs.md).
- **Pack format** — delta-compressed multi-object storage for density; depends on `COL_BLOB` and on sankoch delta primitives. Deferred until the simple store proves out.

### Network / interop

- **Wire protocol** — first-party smart-HTTP / ssh replacement. Not on the AGNOS critical path; revisit once the local VCS loop is solid.
- **Signed commits** — sigil-backed signatures on commit objects.

### Quality

- **Integration tests in-tree** — promote the shell-level smoke tests from `docs/guides/getting-started.md` into `tests/` with fixtures. Current `tests/sit.tcyr` is stdlib-assert smoke only.
- **`sit fsck`** — verify object hashes, walk commit chain, report corruption.
