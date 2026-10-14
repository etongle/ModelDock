"""Bounded localhost transfer fixture. Contains no executable app payload."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, required=True)
args = parser.parse_args()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(404 if self.path == '/missing' else 200)
        self.send_header('Content-Length', str(65536 * 20))
        self.end_headers()
        try:
            for _ in range(20):
                self.wfile.write(b'A' * 65536)
                self.wfile.flush()
                time.sleep(.05)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
