#!/usr/bin/env python3
"""A fake sit/v1 server that demands bearer auth and records what it is sent.

Used by tests/integration/run.sh (section 23, 1.7.0) to prove which remotes a
`sit push` presents a bearer token to. It advertises `"auth":["bearer"]` in
/sit/v1/capabilities, answers /sit/v1/refs with no refs, and refuses every
POST with 401 — but first appends each request's Authorization header (or
"-" when there is none) to the log file, one line per request.

usage: bearer_spy.py <bind-addr> <port> <log-file>
Runs until killed. Never forwards, stores or validates anything it receives.
"""
import http.server
import sys

BIND, PORT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3]
CAPS = b'{"sit":"spy","max_body":16777216,"auth":["bearer"],"objects":true,"batch":false,"push":true}'


class Spy(http.server.BaseHTTPRequestHandler):
    def _record(self):
        with open(LOG, "a") as f:
            f.write("%s %s %s\n" % (self.command, self.path, self.headers.get("Authorization", "-")))

    def _send(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._record()
        if self.path == "/sit/v1/capabilities":
            self._send(200, CAPS)
        elif self.path == "/sit/v1/refs":
            self._send(200, b'{"refs":[]}')
        else:
            self._send(404)

    def do_POST(self):
        self._record()
        n = int(self.headers.get("Content-Length", "0") or 0)
        if n > 0:
            self.rfile.read(min(n, 16 * 1024 * 1024))
        self._send(401)

    def log_message(self, *args):
        pass


http.server.HTTPServer((BIND, PORT), Spy).serve_forever()
