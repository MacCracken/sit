#!/usr/bin/env python3
"""Ref updates onto a hole, against a running `sit serve` (1.13.4, audit X2c).

Used by tests/integration/run.sh section 54. Builds a two-commit history in
memory (the same bytes, so the same ids, every run) and pushes the objects a
case names, one POST each, as a client does. Prints one line per request,
"<what> <status>" (a ref update adds "hole" when the body says
"missing objects"), and nothing else.

usage:
  serve_holes.py ids
      prints "<name> <hex>" for every object.
  serve_holes.py push <port> <name>...
      POST /sit/v1/objects/<hex> for each named object.
  serve_holes.py ref <port> <refname> <name>
      POST /sit/v1/refs/<refname> with the named commit (or tag).

Objects: blob1 tree1 commit1 (commit1: tree1, no parent); blob2 tree2 commit2
(commit2: tree2 = {f: blob2, sub/: subtree1}, parent commit1); subtree1 (the
`sub/` tree = {g: blob1}); blob3 tree3 commit3 (commit3: tree3, parent commit1);
commit4 (tree1, no parent; never sent by run.sh). The server takes no tag
objects over the wire, so none is built.

Only ever talks to 127.0.0.1.
"""
import hashlib, socket, sys, zlib

TYPES = {"blob": 0, "tree": 1, "commit": 2, "tag": 3}


def frame(ty, body):
    return b"%s %d\0" % (ty.encode(), len(body)) + body


def oid(ty, body):
    return hashlib.sha256(frame(ty, body)).hexdigest()


def tree_body(entries):
    out = b""
    for mode, name, hexid in entries:
        out += b"%s %s\0" % (mode, name) + bytes.fromhex(hexid)
    return out


def build():
    objs = {}

    def put(name, ty, body):
        objs[name] = (ty, body, oid(ty, body))
        return objs[name][2]

    b1 = put("blob1", "blob", b"one\n")
    b2 = put("blob2", "blob", b"two\n")
    t1 = put("tree1", "tree", tree_body([(b"100644", b"f", b1)]))
    s1 = put("subtree1", "tree", tree_body([(b"100644", b"g", b1)]))
    t2 = put("tree2", "tree", tree_body([(b"100644", b"f", b2), (b"40000", b"sub", s1)]))
    who = b"Hole Test <hole@sit.local> 1700000000 +0000"
    c1 = put("commit1", "commit", b"tree %s\nauthor %s\ncommitter %s\n\none\n" % (t1.encode(), who, who))
    c2 = put("commit2", "commit", b"tree %s\nparent %s\nauthor %s\ncommitter %s\n\ntwo\n"
             % (t2.encode(), c1.encode(), who, who))
    b3 = put("blob3", "blob", b"three\n")
    t3 = put("tree3", "tree", tree_body([(b"100644", b"f", b3)]))
    put("commit3", "commit", b"tree %s\nparent %s\nauthor %s\ncommitter %s\n\nthree\n"
        % (t3.encode(), c1.encode(), who, who))
    put("commit4", "commit", b"tree %s\nauthor %s\ncommitter %s\n\nnever sent\n"
        % (t1.encode(), who, who))
    return objs


def request(port, raw):
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    s.settimeout(30)
    s.sendall(raw)
    buf = b""
    while True:
        try:
            b = s.recv(65536)
        except (socket.timeout, ConnectionError):
            b = b""
        if not b:
            break
        buf += b
    s.close()
    if not buf.startswith(b"HTTP/"):
        return "none", b""
    head, _, body = buf.partition(b"\r\n\r\n")
    return head.split(b" ", 2)[1].decode(), body


def main():
    objs = build()
    mode = sys.argv[1]
    if mode == "ids":
        for name in sorted(objs):
            print(name, objs[name][2])
        return 0
    port = int(sys.argv[2])
    if mode == "push":
        for name in sys.argv[3:]:
            ty, body, hexid = objs[name]
            z = zlib.compress(frame(ty, body))
            raw = ("POST /sit/v1/objects/%s HTTP/1.1\r\nHost: x\r\nX-Sit-Type: %d\r\n"
                   "Content-Length: %d\r\n\r\n" % (hexid, TYPES[ty], len(z))).encode() + z
            st, _ = request(port, raw)
            print(name, st)
        return 0
    if mode == "ref":
        refname, name = sys.argv[3], sys.argv[4]
        body = (objs[name][2] + "\n").encode()
        raw = ("POST /sit/v1/refs/%s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
               % (refname, len(body))).encode() + body
        st, rb = request(port, raw)
        mark = " hole" if rb.startswith(b"missing objects") else ""
        print("ref %s%s" % (st, mark))
        return 0
    print("usage: serve_holes.py ids | push <port> <name>... | ref <port> <ref> <name>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
