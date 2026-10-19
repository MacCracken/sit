#!/usr/bin/env python3
"""Drive requests at a running `sit serve` and report how much its RSS grew.

Used by tests/integration/run.sh (section 27, 1.7.4) to show the server keeps
nothing per request or per TLS connection. Each request opens a fresh
connection (sit serve answers one request per plain connection; over TLS this
measures a full handshake each time). 50 warm-up requests come first, so lazy
one-time allocations (the object store handle, the arenas) are not counted.

usage: serve_load.py <pid> <http|https> <port> <path> <count>
Prints one line: "<growth-in-KB> <status-of-last-request> <body-bytes>".
Exits 1 if a request fails. Sends nothing but GETs for <path> to 127.0.0.1.
"""
import http.client
import ssl
import sys

PID, SCHEME, PORT, PATH, COUNT = (int(sys.argv[1]), sys.argv[2], int(sys.argv[3]),
                                  sys.argv[4], int(sys.argv[5]))


def rss_kb():
    with open("/proc/%d/status" % PID) as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    return -1


def get():
    if SCHEME == "https":
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        c = http.client.HTTPSConnection("127.0.0.1", PORT, timeout=10, context=ctx)
    else:
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    c.request("GET", PATH)
    r = c.getresponse()
    body = r.read()
    c.close()
    return r.status, len(body)


try:
    for _ in range(50):
        get()
    before = rss_kb()
    last = (0, 0)
    for _ in range(COUNT):
        last = get()
    after = rss_kb()
except Exception as e:  # a refused or hung request is a failure, not a number
    print("request failed: %s" % e)
    sys.exit(1)
print("%d %d %d" % (after - before, last[0], last[1]))
