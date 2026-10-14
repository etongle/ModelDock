#!/usr/bin/python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--mmproj')
parser.add_argument('--no-mmproj', action='store_true')
parser.add_argument('--studio', action='store_true')
args, unused = parser.parse_known_args()
inputs = ['text', 'image'] if args.mmproj and not args.no_mmproj else ['text']

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *unused):
        pass
    def do_GET(self):
        if args.studio:
            if self.path == '/v1/models':
                body = {'data': [{'id': 'text-model'}, {'id': 'vision-alias'}]}
            elif self.path == '/api/v1/models':
                body = {'models': [
                    {'key': 'text-model', 'capabilities': {'vision': False}, 'loaded_instances': []},
                    {'key': 'vision-model', 'capabilities': {'vision': True}, 'loaded_instances': [
                        {'id': 'vision-alias', 'config': {'context_length': 16384}}]}]}
            elif self.path == '/props':
                body = {'modalities': {'vision': True}}
            else:
                self.send_error(404)
                return
        else:
            body = {'data': [{'id': 'fixture-model', 'input_modalities': inputs}]}
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
