"""Small HTTP fixture for Strata protocol/lifecycle tests, never real inference."""
import argparse
import json
from pathlib import Path
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument('--config', required=True)
parser.add_argument('--port', type=int, required=True)
parser.add_argument('--context', type=int, default=32768)
parser.add_argument('--mode', default='automatic')
parser.add_argument('--instance-dir')
parser.add_argument('--draft', default='automatic')
parser.add_argument('--speculation')
args = parser.parse_args()
config = json.loads(Path(args.config).read_text())
vision = args.mode != 'text' and bool(config.get('vision'))
started = time.monotonic()
model = config.get('model_name', 'fixture/flash-next')
parts = config['args']
def option(name):
    return parts[parts.index(name) + 1] if name in parts else None
components = {'weights': option('--native'), 'ngram': option('--ple-gguf'),
              'draft': str(Path(option('--mtp')).parent / 'mtp-q2_0.gguf') if option('--mtp') and args.draft != 'off' else None,
              'vision': config['vision']['mmproj'] if vision else None, 'tokenizer': config['tokenizer']}
print('[ModelDock Strata] loading: fixture startup', flush=True)
print('[ModelDock Strata components] ' + json.dumps(components), flush=True)

class Handler(BaseHTTPRequestHandler):
    def reply(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == '/health':
            self.reply({'service': 'strata', 'loaded': time.monotonic() - started >= 0.7,
                        'status': 'ok', 'images': vision, 'max_context': args.context})
        elif self.path == '/v1/models':
            self.reply({'object': 'list', 'data': [{'id': model, 'object': 'model',
                         'vision': vision, 'context_window': args.context}]})
        else:
            self.reply({'fixture': True})

    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        self.rfile.read(length)
        self.reply({'id':'fixture','object':'chat.completion','model':model,
                    'choices':[{'index':0,'message':{'role':'assistant','content':'fixture response'},'finish_reason':'stop'}]})

    def log_message(self, *args):
        pass

ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
