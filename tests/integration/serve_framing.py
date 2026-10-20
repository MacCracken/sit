#!/usr/bin/env python3
"""Large pushes and request framing against a running `sit serve` (1.7.6, N2 / N5).

Used by tests/integration/run.sh section 31. Every request is sent raw so the
framing is exactly what the case names. Prints one line per case,
"<name> <result>", and nothing else; run.sh asserts on the results.

usage:
  serve_framing.py push   <http|https> <port> <object-file> <hex>
      POST /sit/v1/objects/<hex> with the zlib object in <object-file>;
      prints "push <status>".
  serve_framing.py frame  <http|https> <port>
      prints "toolarge <status>", "clte <status>", "chunked <status>",
      "pipelined <responses> <closed>".
  serve_framing.py stdio  <sit> <repo> <object-file> <hex>
      the same push through `sit serve <repo> --stdio`; prints "push <status>".

Only ever talks to 127.0.0.1. Certificates are not verified (the test server's
is self-signed).
"""
import socket, ssl, subprocess, sys


def connect(scheme, port):
    s = socket.create_connection(("127.0.0.1", port), timeout=20)
    if scheme == "https":
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        s = ctx.wrap_socket(s, server_hostname="localhost")
    return s


def read_all(s):
    out = b""
    try:
        while True:
            b = s.recv(65536)
            if not b:
                break
            out += b
    except (socket.timeout, ssl.SSLError, ConnectionError):
        pass
    return out


def status_of(resp):
    if not resp.startswith(b"HTTP/"):
        return "none"
    return resp.split(b" ", 2)[1].decode()


def one(scheme, port, raw, timeout=20):
    s = connect(scheme, port)
    s.settimeout(timeout)
    s.sendall(raw)
    # Read one response: headers, then Content-Length bytes.
    buf = b""
    while b"\r\n\r\n" not in buf:
        try:
            b = s.recv(65536)
        except (socket.timeout, ssl.SSLError, ConnectionError):
            b = b""
        if not b:
            break
        buf += b
    s.close()
    return status_of(buf)


def push_req(objfile, hexid):
    body = open(objfile, "rb").read()
    head = ("POST /sit/v1/objects/%s HTTP/1.1\r\nHost: x\r\nX-Sit-Type: 0\r\n"
            "Content-Length: %d\r\n\r\n" % (hexid, len(body))).encode()
    return head + body


def main():
    mode = sys.argv[1]
    if mode == "push":
        scheme, port, objfile, hexid = sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
        print("push", one(scheme, port, push_req(objfile, hexid)))
    elif mode == "frame":
        scheme, port = sys.argv[2], int(sys.argv[3])
        big = 17 * 1024 * 1024
        print("toolarge", one(scheme, port, ("POST /sit/v1/want HTTP/1.1\r\nHost: x\r\n"
                                             "Content-Length: %d\r\n\r\n" % big).encode()))
        print("clte", one(scheme, port, b"POST /sit/v1/want HTTP/1.1\r\nHost: x\r\n"
                                        b"Content-Length: 8\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))
        print("chunked", one(scheme, port, b"POST /sit/v1/want HTTP/1.1\r\nHost: x\r\n"
                                           b"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))
        s = connect(scheme, port)
        s.settimeout(5)
        get = b"GET /sit/v1/capabilities HTTP/1.1\r\nHost: x\r\n\r\n"
        s.sendall(get + get)
        resp = read_all(s)
        s.close()
        print("pipelined", resp.count(b"HTTP/1."), "closed")
    elif mode == "stdio":
        sit, repo, objfile, hexid = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
        p = subprocess.run([sit, "serve", repo, "--stdio"], input=push_req(objfile, hexid),
                           capture_output=True, timeout=60)
        print("push", status_of(p.stdout))
    return 0


if __name__ == "__main__":
    sys.exit(main())
