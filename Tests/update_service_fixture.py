import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument('command', nargs='?')
parser.add_argument('--model', '-m', default='fixture')
parser.add_argument('--port', type=int)
parser.add_argument('--max-context', '-c', type=int, default=8192)
args, _ = parser.parse_known_args()
port = args.port or int(os.environ.get('OLLAMA_HOST', '127.0.0.1:29500').rsplit(':', 1)[1])
root = Path(os.environ.get('OLLAMA_MODELS', '/unused'))
manifest = root / 'manifests/registry.ollama.ai/library/demo/latest'
pulls = []
loaded_models = []

class Handler(BaseHTTPRequestHandler):
    def reply(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == '/fixture/state':
            self.reply({'argv': sys.argv[1:], 'context': args.max_context, 'pulls': pulls,
                        'cache': os.environ.get('HF_HUB_CACHE'), 'model': args.model})
        elif self.path == '/api/tags' and manifest.exists():
            self.reply({'models': [{'name': 'demo:latest', 'digest': hashlib.sha256(manifest.read_bytes()).hexdigest()}]})
        elif self.path == '/api/ps':
            self.reply({'models': [{'name': name} for name in loaded_models]})
        else:
            self.reply({'data': [{'id': args.model, 'input_modalities': ['text'], 'context_length': args.max_context}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path == '/fixture/loaded-models':
            loaded_models[:] = body.get('models', [])
            self.reply({'status': 'success'})
        elif self.path == '/api/show':
            self.reply({'modelfile': 'FROM ' + str(root / ('blobs/sha256-' + 'a' * 64)), 'capabilities': ['completion']})
        elif self.path == '/api/pull' and body.get('model') == 'demo:latest':
            pulls.append(body['model'])
            value = json.loads(manifest.read_text())
            value['fixture_updated'] = True
            manifest.write_text(json.dumps(value))
            self.reply({'status': 'success'})
        else:
            self.send_error(400)

    def log_message(self, *args):
        pass

ThreadingHTTPServer(('127.0.0.1', port), Handler).serve_forever()
