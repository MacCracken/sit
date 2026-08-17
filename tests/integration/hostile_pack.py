#!/usr/bin/env python3
"""Hostile .git packfile corpus for src/git_pack.cyr (S-24, 2026-08-17 audit).

sit's `.git/` read-mode exists so consumers (owl, thoth) can report on arbitrary
git repositories on disk. A repo cloned from a hostile remote therefore carries
attacker-controlled `.idx` / `.pack` bytes straight into these parsers, which is
the threat model this corpus encodes.

Four of these cases were live defects at v1.3.6 and are the reason the file
exists — three SIGSEGVs in the `.idx` table math and one out-of-bounds read in
the delta literal opcode that leaked 127 bytes of adjacent heap (including a
live pointer) into `sit cat-file` output. See docs/audit/2026-08-17-audit.md.

Every case is built on packlib's pack construction, which `positive_control()`
validates first — otherwise a fixture that silently bounced off an earlier error
path would look like a pass and pin nothing.

PASS = refused cleanly (exit 1) or produced correct output.
FAIL = crash (negative exit = fatal signal), hang, or an information leak (a
       delta object that "succeeds" while reading past its own buffer).
"""
import os, shutil, struct, subprocess, sys, tempfile, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from packlib import *

if len(sys.argv) < 2:
    sys.exit("usage: hostile_pack.py <path-to-sit> [workdir]")
SIT = os.path.abspath(sys.argv[1])
ROOT = sys.argv[2] if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="sit-hostile-")
FAKE_OID = "aa" * 20

BASE_RAW = b"the quick brown fox jumps over the lazy dog\n" * 4
BASE_OID = oid_of(b"blob", BASE_RAW)
BASE_HDR = obj_hdr(3, len(BASE_RAW))
BASE_ENC = BASE_HDR + zlib.compress(BASE_RAW)


def delta_repo(name, delta, result_oid=None, otype=6):
    """A pack holding a real base blob plus a delta object carrying `delta`."""
    oid = result_oid or FAKE_OID
    if otype == 6:
        hdr = obj_hdr(6, len(delta)) + ofs_varint(len(BASE_ENC))
    else:
        hdr = obj_hdr(7, len(delta)) + bytes.fromhex(BASE_OID)
    objs = [
        {"oid": BASE_OID, "hdr": BASE_HDR, "payload": BASE_RAW},
        {"oid": oid, "hdr": hdr, "payload": delta},
    ]
    pack, offs = build_pack(objs)
    return write_repo(os.path.join(ROOT, name), pack, build_idx(objs, offs, pack)), oid


def raw_repo(name, idx, pack):
    d = os.path.join(ROOT, name)
    write_repo(d, pack, idx)
    return d, FAKE_OID


def fan(lo_at, hi_at):
    return [lo_at if i < 0xAA else hi_at for i in range(256)]


def idx_v2(fanout_vals, rest=b"", pad=0):
    b = bytearray(b"\xfftOc" + struct.pack(">I", 2))
    for v in fanout_vals:
        b += struct.pack(">I", v)
    b += rest + b"\x00" * pad
    return bytes(b)


def cases():
    c = []
    raw = bytes.fromhex(FAKE_OID)

    # --- .idx table-bounds class -------------------------------------------
    c.append(raw_repo("huge_fanout", idx_v2(fan(0, 0x40000000), raw, 64),
                      b"PACK" + struct.pack(">II", 2, 1) + b"\x00" * 64))
    f = fan(0, 1); f[255] = 0x30000000
    c.append(raw_repo("huge_N", idx_v2(f, raw + b"\x00" * 8, 64),
                      b"PACK" + struct.pack(">II", 2, 1) + b"\x00" * 64))
    c.append(raw_repo("large_offset_oob",
                      idx_v2(fan(0, 1), raw + b"\x00" * 4 +
                             struct.pack(">I", 0x80000000 | 0x0FFFFFF0), 64),
                      b"PACK" + struct.pack(">II", 2, 1) + b"\x00" * 64))
    c.append(raw_repo("offset_past_pack",
                      idx_v2(fan(0, 1), raw + b"\x00" * 4 +
                             struct.pack(">I", 0x7000000), 64),
                      b"PACK" + struct.pack(">II", 2, 1) + b"\x00" * 64))
    c.append(raw_repo("idx_truncated", idx_v2(fan(0, 1))[:1040],
                      b"PACK" + struct.pack(">II", 2, 1) + b"\x00" * 64))
    c.append(raw_repo("varint_runoff",
                      idx_v2(fan(0, 1), raw + b"\x00" * 4 + struct.pack(">I", 12), 64),
                      b"PACK" + struct.pack(">II", 2, 1) + b"\xff" * 6))

    # --- delta-stream class (reaches _git_apply_delta) ----------------------
    # Literal opcode declares 127 bytes; the delta ends immediately after the
    # opcode. result_size == 127 so the destination check passes and the object
    # "succeeds" while memcpy reads 127 bytes past the delta buffer.
    d = delta_varint(len(BASE_RAW)) + delta_varint(127) + bytes([0x7F])
    c.append(delta_repo("delta_literal_overrun", d))

    # COPY opcode promising 4 offset + 3 size operand bytes, none present.
    d = delta_varint(len(BASE_RAW)) + delta_varint(64) + bytes([0x80 | 0x7F])
    c.append(delta_repo("delta_copy_truncated", d))

    # Trailing size varint with the continuation bit set on the final byte.
    d = delta_varint(len(BASE_RAW)) + b"\xff\xff\xff"
    c.append(delta_repo("delta_varint_runoff", d))

    # COPY reaching past the base object.
    d = (delta_varint(len(BASE_RAW)) + delta_varint(64)
         + bytes([0x80 | 0x01 | 0x10, 0xF0, 0xFF]))
    c.append(delta_repo("delta_copy_past_base", d))

    # REF_DELTA whose base oid is truncated by the end of the pack.
    c.append(raw_repo("ref_delta_oid_oob",
                      idx_v2(fan(0, 1), raw + b"\x00" * 4 + struct.pack(">I", 12), 64),
                      b"PACK" + struct.pack(">II", 2, 1) + obj_hdr(7, 8) + b"\xaa" * 3))
    return c


def positive_control():
    """Prove the fixture builder produces packs sit actually parses.

    Without this, a malformed fixture that bounces off an earlier error path
    would report PASS while exercising none of the code it targets — which is
    exactly how the first draft of this corpus scored 7 false passes.
    """
    tail = b"TAIL\n"
    result = BASE_RAW + tail
    delta = delta_varint(len(BASE_RAW)) + delta_varint(len(result))
    delta += bytes([0x80 | 0x01 | 0x10, 0, len(BASE_RAW)])
    delta += bytes([len(tail)]) + tail
    res_oid = oid_of(b"blob", result)
    d, _ = delta_repo("_positive_control", delta, result_oid=res_oid)

    for label, oid, want in (("base blob", BASE_OID, BASE_RAW),
                             ("OFS_DELTA", res_oid, result)):
        r = subprocess.run([SIT, "cat-file", oid], cwd=d, capture_output=True)
        if r.returncode != 0 or r.stdout != want:
            print(f"  FAIL  positive control ({label}) — fixture builder is "
                  f"broken, hostile cases below prove nothing "
                  f"(exit={r.returncode}, {len(r.stdout)}B)")
            return False
    print("  PASS  positive control            valid pack + OFS_DELTA roundtrip")
    return True


def main():
    shutil.rmtree(ROOT, ignore_errors=True)
    if not positive_control():
        return 1
    fails = []
    cs = cases()
    for d, oid in cs:
        name = os.path.basename(d)
        try:
            r = subprocess.run([SIT, "cat-file", oid], cwd=d,
                               capture_output=True, timeout=15)
            rc, out = r.returncode, r.stdout
        except subprocess.TimeoutExpired:
            rc, out = "TIMEOUT", b""
        crashed = not isinstance(rc, int) or rc < 0
        # A delta case that exits 0 leaked out-of-bounds bytes as object content.
        leaked = (rc == 0 and name.startswith("delta_"))
        ok = not crashed and not leaked
        why = "CRASH" if crashed else ("LEAK %dB" % len(out) if leaked else "")
        print(f"  {'PASS' if ok else 'FAIL'}  {name:<24} exit={rc} {why}")
        if not ok:
            fails.append(name)
    print()
    if fails:
        print(f"FAILED {len(fails)}/{len(cs)}: {fails}")
        return 1
    print(f"all {len(cs)} hostile-pack cases refused cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
