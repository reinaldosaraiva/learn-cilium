#!/usr/bin/env python3
"""Serve one exact GET response for a local Ansible DELETE-recovery test."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path


expected_path = os.environ["P010_FAKE_NEUTRON_EXPECTED_PATH"]
port_file = Path(os.environ["P010_FAKE_NEUTRON_PORT_FILE"])
calls_file = Path(os.environ["P010_FAKE_NEUTRON_CALLS_FILE"])
status_file = Path(os.environ["P010_FAKE_NEUTRON_STATUS_FILE"])
resource_id = "11111111-2222-4333-8444-555555555555"
deleted = False


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - stdlib protocol callback name
        with calls_file.open("a", encoding="utf-8") as stream:
            stream.write(f"GET {self.path}\n")
        if self.path != expected_path:
            status = 404
        else:
            status = int(status_file.read_text(encoding="ascii").strip())
            if deleted and status == 200:
                status = 404
        self.send_response(status)
        if status == 200:
            body = json.dumps(
                {"network": {"id": resource_id, "name": "p010-hyb-tenant-network"}}
            ).encode("utf-8")
        else:
            body = b"{}"
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):  # noqa: N802 - stdlib protocol callback name
        global deleted
        with calls_file.open("a", encoding="utf-8") as stream:
            stream.write(f"DELETE {self.path}\n")
        if self.path != expected_path or int(status_file.read_text(encoding="ascii").strip()) != 200:
            self.send_response(503)
            self.end_headers()
            return
        deleted = True
        self.send_response(204)
        self.end_headers()

    def log_message(self, _format, *_args):
        return


server = HTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(f"{server.server_port}\n", encoding="ascii")
os.chmod(port_file, 0o600)
server.serve_forever()
