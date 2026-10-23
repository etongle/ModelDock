"""Exercise the bundled loopback adapter with isolated HTTP model fixtures."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('playground', ROOT / 'Resources/playground.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class ModelFixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, value):
        payload = json.dumps(value).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(payload))); self.end_headers(); self.wfile.write(payload)

    def do_GET(self):
        self.reply({'job_id': 'fixture-image', 'stage': 'denoising', 'completed': 3, 'total': 8, 'busy': True})

    def do_POST(self):
        value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.received.append((self.path, value, self.headers.get('Authorization')))
        self.reply({'data': [{'b64_json': base64.b64encode(b'fixture-png').decode()}]} if '/images/' in self.path else {'output': []})


class PlaygroundChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root = Path(self.temp.name)
        (self.root / 'gateway').mkdir(); (self.root / 'dist').mkdir()
        (self.root / 'dist/index.html').write_text('<title>Playground fixture</title>')
        self.model = ThreadingHTTPServer(('127.0.0.1', 0), ModelFixture); self.model.received = []
        threading.Thread(target=self.model.serve_forever, daemon=True).start()
        (self.root / 'gateway/settings.json').write_text(json.dumps({'port': self.model.server_port, 'apiKey': 'fixture-private-gateway-key'}))
        self.config = self.root / 'config.json'
        self.config.write_text(json.dumps({'profiles': [{'id': 'modeldock-local-image', 'model': 'image-client', 'apiKey': 'old-secret'}, {'id': 'modeldock-local-chat', 'model': 'chat-client', 'apiKey': 'old-secret'}], 'image_model': 'bound-image', 'chat_route': 'bound-chat', 'solution_id': 'fixture-solution'}))
        self.server = bridge.PreviewServer(('127.0.0.1', 0), bridge.Handler)
        self.server.config_path = self.config; self.server.dist = self.root / 'dist'; self.server.state_dir = self.root; self.server.image_port = self.model.server_port; self.server.commit = 'fixture'; self.server.models = {'image': 'image-client', 'chat': 'chat-client'}
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.model.shutdown(); self.model.server_close(); self.temp.cleanup()

    def request(self, path, value=None, headers=None):
        body = json.dumps(value).encode() if value is not None else None
        request = urllib.request.Request(self.url + path, data=body, headers={'Content-Type': 'application/json', **(headers or {})})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def test_config_is_same_origin_and_never_discloses_credentials(self):
        status, config = self.request('/modeldock/config.json')
        self.assertEqual(status, 200)
        for profile in config['profiles']:
            self.assertEqual(profile['baseUrl'], self.url + '/modeldock/v1/')
            self.assertEqual(profile['apiKey'], 'modeldock-loopback')
        self.assertNotIn('private-gateway-key', json.dumps(config)); self.assertNotIn('old-secret', json.dumps(config))
        self.assertEqual(self.request('/modeldock/config.json', headers={'Origin': 'https://example.invalid'})[0], 403)

    def test_bound_service_and_task_progress_are_preserved(self):
        self.assertEqual(self.request('/modeldock/v1/images/generations', {'model': 'image-client', 'prompt': 'fixture image', 'job_id': 'fixture-image'})[0], 200)
        _, body, authorization = self.model.received[-1]
        self.assertEqual(body['model'], 'bound-image'); self.assertEqual(body['job_id'], 'fixture-image'); self.assertEqual(authorization, 'Bearer fixture-private-gateway-key')
        _, progress = self.request('/modeldock/progress?job_id=fixture-image')
        self.assertEqual((progress['completed'], progress['total']), (3, 8))
        _, other = self.request('/modeldock/progress?job_id=other-task')
        self.assertEqual(other['stage'], 'waiting'); self.assertNotIn('busy', other)
        self.assertEqual(self.request('/modeldock/progress?job_id=../invalid')[0], 400)
        self.assertEqual(self.request('/modeldock/v1/responses', {'model': 'chat-client', 'input': []})[0], 200)
        self.assertEqual(self.model.received[-1][1]['model'], 'bound-chat')


if __name__ == '__main__':
    unittest.main()
