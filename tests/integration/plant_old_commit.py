#!/usr/bin/env python3
"""Plant an old commit for tests/integration/run.sh section 37 (1.8.0).

usage: plant_old_commit.py <parent_hex> <shared_blob_hex>
Run inside a .sit repo. Writes, as loose objects sit migrates on first read, a
commit dated two years ago whose tree holds a blob only it has (old.txt) and
<shared_blob_hex> (shared.txt). No ref points at it. Prints
"<commit> <tree> <unique blob>".
"""
import hashlib, os, sys, time, zlib
parent, shared = sys.argv[1], sys.argv[2]
def put(t, body):
    full = t + b" %d\0" % len(body) + body; h = hashlib.sha256(full).hexdigest()
    d = os.path.join(".sit", "objects", h[:2]); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, h[2:]), "wb").write(zlib.compress(full)); return h
ub = put(b"blob", b"only in the old commit\n")
ents = sorted([(b"old.txt", ub), (b"shared.txt", shared)])
tree = put(b"tree", b"".join(b"100644 " + n + b"\0" + bytes.fromhex(h) for n, h in ents))
ts = int(time.time()) - 2 * 365 * 86400
body = b"tree %s\nparent %s\nauthor t <t@t> %d +0000\ncommitter t <t@t> %d +0000\n\nold\n" % (tree.encode(), parent.encode(), ts, ts)
print(put(b"commit", body), tree, ub)
