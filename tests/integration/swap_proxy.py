#!/usr/bin/env python3
"""A hostile sit/v1 server for tests/integration/run.sh (1.7.6, N1).

Proxies a real `sit serve` on 127.0.0.1:<upstream_port>, but answers
GET /sit/v1/objects/<victim_hex> with other content under that same id, and
advertises "batch":false so every object goes through that per-object GET.
A client that stores the substituted bytes has not verified what it fetched.

usage: swap_proxy.py <listen_port> <upstream_port> <victim_hex> <content_file> <ty>
  ty: 0 blob, 1 tree, 2 commit (the framing type written around the content)
Runs until killed. Listens on and forwards to 127.0.0.1 only.
"""
import http.server, sys, urllib.error, urllib.request, zlib

LPORT, UPORT, VICTIM, CFILE, TY = (int(sys.argv[1]), int(sys.argv[2]), sys.argv[3],
                                   sys.argv[4], int(sys.argv[5]))
content = open(CFILE, "rb").read()
tyname = {0: b"blob", 1: b"tree", 2: b"commit"}[TY]
swapped = zlib.compress(tyname + b" " + str(len(content)).encode() + b"\0" + content)


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def _send(self, code, body, extra=None):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/sit/v1/capabilities":
            return self._send(200, b'{"sit":"proxy","max_body":16777216,"auth":["none"],'
                                   b'"objects":true,"batch":false,"push":false}')
        if self.path == "/sit/v1/objects/" + VICTIM:
            return self._send(200, swapped, {"X-Sit-Type": str(TY)})
        try:
            r = urllib.request.urlopen("http://127.0.0.1:%d%s" % (UPORT, self.path))
            body = r.read()
            extra = {}
            if r.headers.get("X-Sit-Type") is not None:
                extra["X-Sit-Type"] = r.headers["X-Sit-Type"]
            return self._send(200, body, extra)
        except urllib.error.HTTPError as e:
            return self._send(e.code, b"")


http.server.ThreadingHTTPServer(("127.0.0.1", LPORT), Proxy).serve_forever()
