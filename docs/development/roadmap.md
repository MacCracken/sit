# sit Development Roadmap

> **v0.4.0** — First official release. Local multi-branch VCS with signed commits and local-path wire protocol. Single cut; all pre-release iteration rolls into this tag.

Forward-looking backlog lives below. Historical per-sub-version notes were collapsed into the 0.4.0 entry; see [`CHANGELOG.md`](../../CHANGELOG.md) for the tagged artifact.

## Released

### v0.4.0 — first official release

The local VCS loop is complete end-to-end, with ed25519 signing and a local-path fetch/push protocol.

**Core object model**
- `sit init` creates a git-parity `.sit/{HEAD,objects.patra,refs/heads}` layout.
- Objects are SHA-256-hashed (sigil) and zlib-compressed (sankoch), framed `"<type> <len>\0<content>"` — byte-compatible with git's SHA-256 object format for identical content.
- Storage is patra-backed: `.sit/objects.patra` (`objects(hash STR, ty INT, content BYTES)`) + `.sit/index.patra` (`entries(path STR, hash_hex STR)`). Legacy plaintext/loose layouts auto-migrate on first access.
- Trees are recursive with `40000` dir + `100644` file modes, byte-matching git's SHA-256 tree format. `flatten_tree` / `read_head_tree_entries` give flat views for status/diff.

**Commands (19)**
- Write: `init`, `add [-f]`, `rm [--cached]`, `commit [-S] [-m]`, `reset [--hard]`, `merge [--abort]`, `branch [-d]`, `checkout [-b]`, `tag [-d]`, `config [--global|--list|--unset]`, `key generate|show`, `remote add|list|remove`, `fetch`, `push`.
- Read: `log [--oneline] [-n] [<ref>]`, `status`, `diff [--staged|<commit>|<c1> <c2>]`, `show [--stat] [<hash>]`, `cat-file`, `owl-file`, `fsck`, `verify-commit`.

**Signed commits (sigil/ed25519, no GPG)**
- `sit key generate` → `~/.sit/signing_key` (32B seed hex, 0600) + `signing_key.pub`.
- `sit commit -S` injects `sitsig <sig-hex> <pub-hex>\n` between `committer` and the message separator. Signed payload is the body *without* the sitsig line (self-consistent like git's `gpgsig`).
- `sit show` / `sit log` auto-decorate with `Signature: good|BAD (key <hex12>)` via a shared `print_commit_header`.

**Merge**
- Fast-forward when possible; otherwise 3-way with line-level diff3. Non-overlapping hunks auto-merge; overlapping edits fall back to conflict markers + `.sit/MERGE_HEAD`. Follow-on `sit commit` emits a 2-parent commit. `sit merge --abort` cancels.

**Wire protocol (local paths only)**
- `sit remote add <name> <url>` writes to `.sit/config`; `file://` and bare paths are the only transports in this cut.
- `sit fetch` walks remote refs, diffs against local object set, copies missing objects naively (no pack bundles).
- `sit push` is the reverse direction; fast-forward only. Non-ff push rejected.
- HTTP / SSH transports and pack bundles are explicit v0.5.x work.

**Config + identity**
- `sit config [--global] <key> [<value>]`, `--list`, `--unset`. Local `.sit/config`, global `~/.sitconfig`.
- Author chain: `SIT_AUTHOR_NAME` env → local config → global config → `"sit user"` fallback.

**Tests**: 31 assertions — sigil SHA-256 known-answers, git-SHA-256 blob framing, hex encode/decode, sankoch zlib roundtrip, patra COL_BYTES small + 16KB overflow, ed25519 sign/verify roundtrip with bit-flip negatives.

**Deps**: cyrius 5.6.25, sakshi 2.1.0, sankoch 2.0.1, sigil 2.9.1, patra 1.6.0. Git-tag pinned. No FFI, no C, no libgit2 — see [ADR 0001](../adr/0001-no-ffi-first-party-only.md).

## Backlog

### v0.5.0 — Network wire protocol

- **HTTP transport** — sit-native JSON/REST (not git-wire-compatible). Likely shape: `GET /sit/v1/refs`, `GET /sit/v1/object/<hash>`, `POST /sit/v1/refs/<name>`, `POST /sit/v1/object`. Server is a thin patra-to-HTTP translator.
- **SSH transport** — run `sit-upload-pack` / `sit-receive-pack` over stdin/stdout (same pattern as git).
- **Pack bundles** — batch object transfer using sankoch delta primitives once patra grows the supporting storage. Reduces per-object network chatter.
- **Clone / pull** — trivial compositions of fetch + checkout + merge once the transport lands.

### Longer horizon

- **Nested branch names** — `sit branch feature/foo` and `sit checkout -b feature/foo` currently fail because `.sit/refs/heads/feature/` isn't auto-created. `write_head_ref` / `write_branch_ref` need to `ensure_dir` on the parent path of the target ref file. Affects tag refs symmetrically.
- **`sit merge -S`** — `cmd_merge` already routes through `build_merge_commit_signed`, but the command doesn't parse a `-S` flag and always passes `seed=0`. Add flag parsing + seed load; symmetric to `cmd_commit -S`.
- **`sit fsck` reachability** — walk commit chain and flag dangling objects (current implementation checks integrity but not reachability).
- **Full `.sitignore` semantics** — negation (`!pattern`), double-star (`**`), character classes (`[abc]`), anchored patterns (`/foo`), path patterns (`foo/bar`).
- **`sit log --graph`** — ASCII DAG for merge history.
- **Shallow clone** — `--depth N` limits to N commits back from HEAD.
- **Integration tests in-tree** — promote the shell-level scenarios from `docs/guides/getting-started.md` into `tests/` with fixtures. Current `tests/sit.tcyr` is primitive-assert smoke only.
- **sandhi migration** — cyrius 5.7.0 ships a first-party `sandhi` stdlib crate; migrate `cyrius.cyml`'s inline `stdlib = [...]` list when the release is out. Transitive dep resolution in the same release should also let us drop the expanded `thread`/`freelist`/`bigint`/`ct`/`keccak` entries.
