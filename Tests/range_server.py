from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import json
import sys
import time

PAYLOAD = b"GGUF" + bytes(i % 251 for i in range(256 * 1024))
ROOT = Path(sys.argv[1])
ROOT.mkdir(parents=True, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        requested = self.headers.get("Range")
        with (ROOT / "requests.jsonl").open("a") as log:
            log.write(json.dumps({"path": self.path, "range": requested}) + "\n")
        if self.path == "/html":
            body = b"<html>not a model</html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        start = int(requested.split("=")[1].split("-")[0]) if requested else 0
        if self.path == "/ignore":
            start = 0
        if start >= len(PAYLOAD):
            self.send_response(416)
            self.end_headers()
            return
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("ETag", '"fixture-v1"')
        self.send_header("Content-Length", str(len(PAYLOAD) - start))
        if start:
            declared = start + 1 if self.path == "/bad-range" else start
            self.send_header("Content-Range", f"bytes {declared}-{len(PAYLOAD) - 1}/{len(PAYLOAD)}")
        self.end_headers()
        try:
            for offset in range(start, len(PAYLOAD), 2048):
                self.wfile.write(PAYLOAD[offset:offset + 2048])
                self.wfile.flush()
                if self.path == "/slow":
                    time.sleep(0.005)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(ROOT / "port.txt").write_text(str(server.server_port))
server.serve_forever()
