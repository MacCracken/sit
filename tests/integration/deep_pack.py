#!/usr/bin/env python3
"""Deep delta chains and packs past 64 MiB for src/git_pack.cyr (D6, 1.7.4).

Through 1.7.3 `.git/` read-mode resolved delta chains by recursion, stopping at
depth 64, and read each .idx / .pack whole onto the heap through a 64 MiB cap.
Either limit made objects read as missing, so sit_repo_status (owl, thoth)
called a clean file modified or untracked. git allows chains up to 4095, and
`git repack --depth=250` is common advice.

Each case builds a real pack with packlib (or a real git repo) and compares
`sit cat-file` with the content the object must have. The refusal cases must
exit 1 cleanly, not crash or hang.

usage: deep_pack.py <path-to-sit> [workdir]
Prints one PASS / FAIL / SKIP line per case; exits 1 on any FAIL.
"""
import hashlib, os, shutil, struct, subprocess, sys, tempfile, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from packlib import *

if len(sys.argv) < 2:
    sys.exit("usage: deep_pack.py <path-to-sit> [workdir]")
SIT = os.path.abspath(sys.argv[1])
ROOT = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="sit-deep-")
FAILS = []


def report(ok, name, detail=""):
    print("  %s  %-26s %s" % ("PASS" if ok else "FAIL", name, detail))
    if not ok:
        FAILS.append(name)


def cat(repo, oid, timeout=120):
    try:
        r = subprocess.run([SIT, "cat-file", oid], cwd=repo, capture_output=True, timeout=timeout)
        return r.returncode, r.stdout
    except subprocess.TimeoutExpired:
        return "TIMEOUT", b""


def copy_op(off, n):
    """A delta COPY of n (1..0xFFFF) bytes from base offset `off`."""
    op, operands = 0x80, b""
    for k in range(4):
        b = (off >> (8 * k)) & 0xFF
        if b:
            op |= 1 << k
            operands += bytes([b])
    for k in range(3):
        b = (n >> (8 * k)) & 0xFF
        if b:
            op |= 0x10 << k
            operands += bytes([b])
    return bytes([op]) + operands


def delta_append(prev, new):
    """A git delta turning `prev` into `new`, where `new` extends `prev`."""
    d = delta_varint(len(prev)) + delta_varint(len(new))
    off = 0
    while off < len(prev):
        n = min(len(prev) - off, 0xFFFF)
        d += copy_op(off, n)
        off += n
    tail = new[len(prev):]
    i = 0
    while i < len(tail):
        piece = tail[i:i + 127]
        d += bytes([len(piece)]) + piece
        i += 127
    return d


def chain_contents(n):
    c = [b"base\n"]
    for i in range(n):
        c.append(c[-1] + b"line %d\n" % i)
    return c


def write_packs(repo, packs, level=6):
    """packs: {name: [(oid, kind, payload, base)]} with kind a pack type code,
    or "ofs" / "ref" with `base` the base object's oid."""
    pdir = os.path.join(repo, ".git", "objects", "pack")
    os.makedirs(pdir, exist_ok=True)
    open(os.path.join(repo, ".git", "HEAD"), "w").write("ref: refs/heads/main\n")
    for name, entries in packs.items():
        body, offs = bytearray(), {}
        for oid, kind, payload, base in entries:
            off = 12 + len(body)
            offs[oid] = off
            if kind == "ofs":
                hdr = obj_hdr(6, len(payload)) + ofs_varint(off - offs[base])
            elif kind == "ref":
                hdr = obj_hdr(7, len(payload)) + bytes.fromhex(base)
            else:
                hdr = obj_hdr(kind, len(payload))
            body += hdr + zlib.compress(payload, level)
        pack = b"PACK" + struct.pack(">II", 2, len(entries)) + bytes(body)
        pack += hashlib.sha1(pack).digest()
        idx = build_idx([{"oid": e[0]} for e in entries], offs, pack)
        open(os.path.join(pdir, "pack-%s.pack" % name), "wb").write(pack)
        open(os.path.join(pdir, "pack-%s.idx" % name), "wb").write(idx)
    return repo


def ofs_chain_repo(name, depth):
    c = chain_contents(depth)
    oids = [oid_of(b"blob", x) for x in c]
    entries = [(oids[0], 3, c[0], None)]
    for i in range(1, depth + 1):
        entries.append((oids[i], "ofs", delta_append(c[i - 1], c[i]), oids[i - 1]))
    return write_packs(os.path.join(ROOT, name), {"x": entries}), oids, c


def case_ofs(depth, expect_ok):
    name = "ofs_chain_%d" % depth
    repo, oids, c = ofs_chain_repo(name, depth)
    rc, out = cat(repo, oids[depth])
    if expect_ok:
        report(rc == 0 and out == c[depth], name,
               "exit=%s %dB (want %dB)" % (rc, len(out), len(c[depth])))
    else:
        report(rc == 1, name, "exit=%s (refused past git's 4095)" % rc)


def case_ofs_middle():
    repo, oids, c = ofs_chain_repo("ofs_chain_middle", 100)
    rc, out = cat(repo, oids[65])
    report(rc == 0 and out == c[65], "ofs_chain_100_at_65", "exit=%s" % rc)


def case_ref_two_packs():
    """REF_DELTA links alternating between two packs: each base is found by id
    in the OTHER pack, so every step crosses packs."""
    depth = 100
    c = chain_contents(depth)
    oids = [oid_of(b"blob", x) for x in c]
    packs = {"a": [(oids[0], 3, c[0], None)], "b": []}
    for i in range(1, depth + 1):
        packs["b" if i % 2 else "a"].append(
            (oids[i], "ref", delta_append(c[i - 1], c[i]), oids[i - 1]))
    repo = write_packs(os.path.join(ROOT, "ref_chain_two_packs"), packs)
    rc, out = cat(repo, oids[depth])
    report(rc == 0 and out == c[depth], "ref_chain_100_two_packs", "exit=%s %dB" % (rc, len(out)))


def case_mixed():
    """OFS and REF links in one chain, with a loose-free REF base in-pack."""
    depth = 90
    c = chain_contents(depth)
    oids = [oid_of(b"blob", x) for x in c]
    entries = [(oids[0], 3, c[0], None)]
    for i in range(1, depth + 1):
        kind = "ref" if i % 3 == 0 else "ofs"
        entries.append((oids[i], kind, delta_append(c[i - 1], c[i]), oids[i - 1]))
    repo = write_packs(os.path.join(ROOT, "mixed_chain"), {"x": entries})
    rc, out = cat(repo, oids[depth])
    report(rc == 0 and out == c[depth], "mixed_ofs_ref_chain_90", "exit=%s" % rc)


def case_ref_cycle():
    """Two REF_DELTAs naming each other: the walk must stop, not spin."""
    x, y = "11" * 20, "22" * 20
    d = delta_varint(5) + delta_varint(5) + bytes([5]) + b"abcde"
    repo = write_packs(os.path.join(ROOT, "ref_cycle"),
                       {"x": [(x, "ref", d, y), (y, "ref", d, x)]})
    rc, _ = cat(repo, x, timeout=60)
    report(rc == 1, "ref_delta_cycle", "exit=%s" % rc)


def case_big_pack():
    """A 75 MiB pack: five 15 MiB incompressible blobs, stored, then a delta at
    the end whose base lies past 64 MiB. 1.7.3 could not read the pack at all."""
    size = 15 * 1024 * 1024
    blobs = [os.urandom(size) for _ in range(5)]
    oids = [oid_of(b"blob", b) for b in blobs]
    tail = blobs[4] + b"tail\n"
    toid = oid_of(b"blob", tail)
    entries = [(oids[i], 3, blobs[i], None) for i in range(5)]
    entries.append((toid, "ofs", delta_append(blobs[4], tail), oids[4]))
    repo = write_packs(os.path.join(ROOT, "big_pack"), {"x": entries}, level=0)
    psize = os.path.getsize(os.path.join(repo, ".git", "objects", "pack", "pack-x.pack"))
    for label, oid, want in (("first", oids[0], blobs[0]), ("last", oids[4], blobs[4]),
                             ("delta", toid, tail)):
        rc, out = cat(repo, oid)
        report(rc == 0 and out == want, "big_pack_%s" % label,
               "exit=%s pack=%d MiB" % (rc, psize >> 20))


def case_real_git():
    """A real repo repacked at --depth=300: every object git puts deeper than 64
    must read back exactly as `git cat-file` gives it."""
    if shutil.which("git") is None:
        print("  SKIP  real_git_depth_300         git not installed")
        return
    repo = os.path.join(ROOT, "real_git")
    os.makedirs(repo)
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    def git(*a):
        return subprocess.run(["git", "-c", "init.defaultBranch=main"] + list(a), cwd=repo,
                              env=env, capture_output=True, check=True).stdout
    git("init", "-q")
    # Each commit edits one line in place, so every version is closest to its
    # neighbour and git chains them (appending lines lets git delta every
    # version against the newest instead, three deep at most).
    lines = [b"line %04d of a file git will delta deeply, padded to keep it long\n" % i
             for i in range(320)]
    for i in range(320):
        lines[i] = b"LINE %04d of a file git will delta deeply, edited in commit %04d\n" % (i, i)
        open(os.path.join(repo, "f.txt"), "wb").write(b"".join(lines))
        git("add", "f.txt")
        git("commit", "-q", "-m", "c%d" % i)
    git("repack", "-adfq", "--depth=300", "--window=300")
    deep = []
    for pack in os.listdir(os.path.join(repo, ".git", "objects", "pack")):
        if pack.endswith(".idx"):
            out = git("verify-pack", "-v", os.path.join(".git", "objects", "pack", pack))
            for line in out.decode().splitlines():
                parts = line.split()
                if len(parts) >= 7 and parts[1] == "blob" and parts[5].isdigit():
                    deep.append((int(parts[5]), parts[0]))
    deep.sort(reverse=True)
    if not deep or deep[0][0] <= 64:
        report(False, "real_git_depth_300", "git produced no chain deeper than 64 (max %s)"
               % (deep[0][0] if deep else 0))
        return
    past = [oid for d, oid in deep if d > 64]
    bad = 0
    for oid in past:
        rc, out = cat(repo, oid)
        if rc != 0 or out != git("cat-file", "-p", oid):
            bad += 1
    report(bad == 0, "real_git_depth_300",
           "deepest chain %d; %d of the %d blobs deeper than 64 match git"
           % (deep[0][0], len(past) - bad, len(past)))


def main():
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(ROOT)
    case_ofs(100, True)
    case_ofs_middle()
    case_ofs(4095, True)
    case_ofs(4096, False)
    case_ref_two_packs()
    case_mixed()
    case_ref_cycle()
    case_big_pack()
    case_real_git()
    if FAILS:
        print("\n%d deep-pack case(s) failed: %s" % (len(FAILS), ", ".join(FAILS)))
        return 1
    print("\nall deep-pack cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
