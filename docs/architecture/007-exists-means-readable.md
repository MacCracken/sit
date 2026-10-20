# 007 — `file_exists` / `sf_exists` mean "can be opened for reading"

**Status:** current (cyrius 6.7.15 stdlib; sit 1.7.6).

## The quirk

The stdlib's `file_exists(path)` (`lib/io.cyr`) is implemented as `file_open(path, O_RDONLY)` followed by a close. `sf_exists` (`src/util.cyr`) wraps it. So both answer **"can this process open the path for reading right now"**, not "is there anything at this path":

| at the path | `file_exists` / `sf_exists` | `lstat` (`path_lstat_kind`) |
|---|---|---|
| nothing | 0 | -1 |
| a readable file or directory | 1 | `0x8000` / `0x4000` |
| a file this user cannot read (mode 000, another owner) | **0** | `0x8000` |
| a FIFO | `file_exists` **blocks** in `open(2)` until a writer appears; `sf_exists` too through 1.7.5, **0** since 1.7.6 | `0x1000` |
| a dangling symlink | 0 | `0xA000` |

## Why it matters

Code of the shape "if it exists, read it and merge into it; otherwise start fresh" turns an *unreadable* file into a *fresh* one and then overwrites it. 1.7.6's audit found that shape three times:
- `config_file_set` (L15): a `.sit/config` the user could not read was replaced by a file holding only the key being set — every remote gone.
- the TOFU pin store (N3): an unreadable `~/.sit/known_certs` read as "no pins", so the next connection pinned whatever certificate it was shown and the rewrite dropped the rest. The first cut of that fix still asked `file_exists`, and its integration test caught it.
- `sit serve`'s ref push (K2): an unreadable ref read as absent, so the push created it over the old tip with no fast-forward check.

And a FIFO at any probed path hung the reader (R11): `.sit/HEAD`, `.git/HEAD`, an `.idx`.

## What to do

- **To ask "is there something here", use `path_lstat_kind(sit_abs(p)) >= 0`** (or `_sf_special` / `path_is_regular` for the kind). Use `sf_exists` only where "absent" and "unreadable" may safely be treated the same — usually because the next step is a read that would fail anyway.
- **Before opening a file only to read it, check it is a regular file.** `read_file_heap`, `read_file_fl`, read-only `sf_open` and the git readers do this since 1.7.6; `sf_exists` itself refuses to open anything but a regular file or a directory.
- An absent file and an unreadable one are different errors. Say which.
