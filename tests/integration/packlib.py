"""Build real git v2 packs + .idx files, so hostile fixtures are known to
actually reach the parser (validated by a positive control)."""
import hashlib, os, struct, zlib

def obj_hdr(otype, size):
    b = bytearray()
    c = (otype << 4) | (size & 0x0F)
    size >>= 4
    while size:
        b.append(c | 0x80)
        c = size & 0x7F
        size >>= 7
    b.append(c)
    return bytes(b)

def ofs_varint(n):
    """git's biased big-endian back-offset encoding."""
    b = [n & 0x7F]
    n >>= 7
    while n:
        n -= 1
        b.append(0x80 | (n & 0x7F))
        n >>= 7
    return bytes(bytearray(reversed(b)))

def oid_of(otype_name, content):
    return hashlib.sha1(b"%s %d\0" % (otype_name, len(content)) + content).hexdigest()

def delta_varint(n):
    b = bytearray()
    while True:
        c = n & 0x7F
        n >>= 7
        if n:
            b.append(c | 0x80)
        else:
            b.append(c)
            break
    return bytes(b)

def build_pack(objs):
    """objs: list of dicts {type, raw(bytes), oid(hex)}. Returns (packbytes, offsets)."""
    body = bytearray()
    offsets = {}
    for o in objs:
        offsets[o["oid"]] = 12 + len(body)
        o["_off"] = 12 + len(body)
        body += o["hdr"]
        body += zlib.compress(o["payload"])
    pack = b"PACK" + struct.pack(">II", 2, len(objs)) + bytes(body)
    pack += hashlib.sha1(pack).digest()
    return pack, offsets

def build_idx(objs, offsets, packbytes):
    """Correct v2 .idx over the given objects (sorted by oid)."""
    entries = sorted(objs, key=lambda o: o["oid"])
    n = len(entries)
    fan = [0] * 256
    for e in entries:
        fan[int(e["oid"][:2], 16)] += 1
    run = 0
    for i in range(256):
        run += fan[i]
        fan[i] = run
    b = bytearray(b"\xfftOc" + struct.pack(">I", 2))
    for v in fan:
        b += struct.pack(">I", v)
    for e in entries:
        b += bytes.fromhex(e["oid"])
    for e in entries:
        b += struct.pack(">I", 0)              # CRC32 (sit never checks it)
    for e in entries:
        b += struct.pack(">I", offsets[e["oid"]])
    b += hashlib.sha1(packbytes).digest()      # pack checksum
    b += hashlib.sha1(bytes(b)).digest()       # idx checksum
    return bytes(b)

def write_repo(path, packbytes, idxbytes):
    p = os.path.join(path, ".git", "objects", "pack")
    os.makedirs(p, exist_ok=True)
    open(os.path.join(path, ".git", "HEAD"), "w").write("ref: refs/heads/main\n")
    open(os.path.join(p, "pack-x.pack"), "wb").write(packbytes)
    open(os.path.join(p, "pack-x.idx"), "wb").write(idxbytes)
    return path
