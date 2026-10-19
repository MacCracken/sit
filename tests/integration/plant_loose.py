"""Copy chosen objects from one sit repo into another as legacy loose files.

usage: python3 -I plant_loose.py <sit> <src-repo> <dst-repo> <kind>:<hex>...

Each object is read with `sit cat-file`, re-framed as `<kind> <len>\\0<body>`,
checked against its id, and written zlib-compressed under
<dst>/.sit/objects/<xx>/<rest>. The destination's next open migrates them into
its object table. Copying a commit and its tree without the blobs builds a
source whose closure has a hole, which nothing else in the CLI can produce.
"""
import hashlib
import os
import subprocess
import sys
import zlib

sit, src, dst = sys.argv[1:4]
for spec in sys.argv[4:]:
    kind, oid = spec.split(":")
    body = subprocess.run([sit, "cat-file", oid], cwd=src,
                          stdout=subprocess.PIPE, check=True).stdout
    framed = kind.encode() + b" %d\0" % len(body) + body
    if hashlib.sha256(framed).hexdigest() != oid:
        sys.exit("plant_loose: %s %s does not re-frame to its id" % (kind, oid))
    d = os.path.join(dst, ".sit", "objects", oid[:2])
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, oid[2:]), "wb") as f:
        f.write(zlib.compress(framed))
