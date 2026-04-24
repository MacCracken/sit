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

## Post-0.1 Backlog

### Priority — the v0.2.0 loop

- **`sit commit`** — tree object (from staging index: `<mode> <name>\0<hash>` entries) + commit object (tree + parent + author + timestamp + message). Reuses `write_blob_object`'s frame-hash-compress-store pattern with `tree` / `commit` framing strings. Writes `.sit/refs/heads/main` atomically.
- **`sit cat-file <hash>`** — plumbing command; decompress object, strip framing, print content. Useful as a verification primitive for every subsequent command and as the round-trip test for loose-object reads.

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
