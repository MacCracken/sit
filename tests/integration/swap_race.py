#!/usr/bin/env python3
"""A served repository swapped for a symlink during requests (1.13.4, audit S3).

Used by tests/integration/run.sh section 56. While a child process exchanges
<dir>/<name> (a real repository) with a symlink to <outside> as fast as it can
(renameat2 RENAME_EXCHANGE, so the name is always one or the other), this asks
`sit serve <dir> --repos` for /<name>/sit/v1/refs and pushes a ref
refs/heads/race<i> naming <tip> (an object <name> has) <rounds> times, then
puts <dir>/<name> back. Prints one line:

  leaked <refs answers that showed <secret>> wrote <race refs in outside> of <rounds>

usage: swap_race.py <port> <dir> <name> <outside> <secret-hex> <tip-hex> <rounds>

Through 1.13.3 each request checked the path, then opened the store, the lock
and the refs by path, so a swap in between reached <outside>. Linux only (the
exchange is a Linux syscall). Only ever talks to 127.0.0.1.
"""
import ctypes, os, platform, signal, socket, sys, time

AT_FDCWD = -100
RENAME_EXCHANGE = 2


def exchanger():
    libc = ctypes.CDLL(None, use_errno=True)
    fn = getattr(libc, "renameat2", None)
    if fn is not None:
        return lambda a, b: fn(AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE)
    nr = {"x86_64": 316, "aarch64": 276}[platform.machine()]
    return lambda a, b: libc.syscall(nr, AT_FDCWD, a, AT_FDCWD, b, RENAME_EXCHANGE)


def request(port, raw):
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
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
    return buf


def main():
    port, d, name, outside, secret, tip, rounds = sys.argv[1:8]
    port, rounds = int(port), int(rounds)
    real = os.path.join(d, name).encode()
    link = os.path.join(d, "." + name + ".lnk").encode()   # never a served name
    if os.path.lexists(link):
        os.unlink(link)
    os.symlink(outside, link)
    swap = exchanger()
    pid = os.fork()
    if pid == 0:
        while True:
            swap(real, link)
    leaked = 0
    try:
        for i in range(rounds):
            r = request(port, ("GET /%s/sit/v1/refs HTTP/1.1\r\nHost: x\r\n\r\n" % name).encode())
            if secret.encode() in r:
                leaked += 1
            body = (tip + "\n").encode()
            request(port, ("POST /%s/sit/v1/refs/refs/heads/race%d HTTP/1.1\r\nHost: x\r\n"
                           "Content-Length: %d\r\n\r\n" % (name, i, len(body))).encode() + body)
    finally:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        if os.path.islink(real):
            swap(real, link)
        os.unlink(link)
    heads = os.path.join(outside, ".sit", "refs", "heads")
    wrote = len([f for f in os.listdir(heads) if f.startswith("race")])
    print("leaked %d wrote %d of %d" % (leaked, wrote, rounds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
