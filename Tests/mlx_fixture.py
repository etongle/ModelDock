#!/usr/bin/python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

parser = argparse.ArgumentParser()
parser.add_argument('--port', required=True, type=int)
parser.add_argument('--model', required=True)
args, _ = parser.parse_known_args()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.path != '/v1/models':
            self.send_error(404)
            return
        # Real MLX-VLM does not declare modalities here. The manager must use
        # the pinned serving component, rather than today's engine defaults.
        data = json.dumps({'data': [{'id': args.model}]}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
