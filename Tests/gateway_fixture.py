#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, required=True)
parser.add_argument('-c', type=int, default=32768)
parser.add_argument('--mmproj')
args, _ = parser.parse_known_args()
key = os.environ.get('GATEWAY_FIXTURE_KEY', '')
root = pathlib.Path(__file__).parent

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, value):
        body = json.dumps(value).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        if key and self.headers.get('Authorization') != 'Bearer ' + key:
            self.send(401, {'error': {'message': 'fixture-auth'}})
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        if self.path == '/props':
            self.send(200, {'modalities': {'vision': bool(args.mmproj), 'audio': bool(args.mmproj)}})
        elif self.path == '/v1/models':
            self.send(200, {'data': [{'id': 'fixture-model', 'object': 'model', 'input_modalities':
                ['text', 'image', 'audio', 'file'] if args.mmproj else ['text'], 'context_length': args.c}]})
        else:
            self.send(404, {'error': {'message': 'not-found'}})

    def do_POST(self):
        if not self.authorized():
            return
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.headers.get('Content-Type', '').startswith('multipart/form-data'):
            value = {'multipart': raw.decode('utf-8', 'replace')}
        else:
            value = json.loads(raw)
        with (root / ('requests-' + str(args.port) + '.jsonl')).open('a') as output:
            output.write(json.dumps({'path': self.path, 'body': value,
                'authorization': self.headers.get('Authorization', '')}) + '\n')
        if value.get('test_error'):
            self.send(418, {'error': {'message': 'fixture-error', 'type': 'fixture_error'}})
            return
        if value.get('stream'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Connection', 'close')
            self.end_headers()
            for event in [
                {'id': 'fixture', 'object': 'chat.completion.chunk', 'model': 'fixture-model', 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'A'}}]},
                {'id': 'fixture', 'object': 'chat.completion.chunk', 'model': 'fixture-model', 'choices': [{'index': 0, 'delta': {'tool_calls': [{'index': 0, 'id': 'call_fixture', 'type': 'function', 'function': {'name': 'read', 'arguments': '{"ok":'}}]}}]},
                {'id': 'fixture', 'object': 'chat.completion.chunk', 'model': 'fixture-model', 'choices': [{'index': 0, 'delta': {'tool_calls': [{'index': 0, 'function': {'arguments': 'true}'}}]}, 'finish_reason': 'tool_calls'}]},
            ]:
                self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode()); self.wfile.flush()
                time.sleep(0.4)
            self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush(); self.close_connection = True
        else:
            self.send(200, {'id': 'fixture', 'object': 'chat.completion', 'model': 'fixture-model',
                'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'OK'}, 'finish_reason': 'stop'}],
                'usage': {'prompt_tokens': 1, 'completion_tokens': 1, 'total_tokens': 2}})

ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
