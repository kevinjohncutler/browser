#!/usr/bin/env python
"""Run the actual Ora WebKit tests against a controlled local HTTP fixture."""

import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/slow":
            time.sleep(0.3)
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/plain")
            self.end_headers()
            return
        html = b"<!doctype html><html><head><title>Ora fixture</title></head><body><h1>Fixture</h1><p>Persistent styles</p></body></html>"
        if self.path == "/styled":
            html = html.replace(
                b"</head>",
                b"<style>html,body {background:white;color:black} p {color:rgb(180,20,20)}</style></head>",
            )
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(html)

    def log_message(self, *_):
        pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = dict(
        os.environ,
        TEST_RUNNER_ORA_WEB_FIXTURE_URL=f"http://127.0.0.1:{server.server_port}",
        TEST_RUNNER_ORA_PYTHON_PATH=sys.executable,
        TEST_RUNNER_ORA_CSS_SERVER_PATH=str(
            Path(__file__).resolve().parents[1] / "integration/ora-css-mcp/server.py"
        ),
    )
    try:
        result = subprocess.run(
            [str(Path(__file__).resolve().parent / "test-headless.sh")],
            env=env,
            check=False,
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
