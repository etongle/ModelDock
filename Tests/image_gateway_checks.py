"""A real gateway forwards image requests and preserves the non-chat boundary."""
import base64
import ctypes
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer
from image_server_checks import image, FakeBackend, PNG, multipart

ROOT = Path(__file__).resolve().parents[1]


class ImageGatewayChecks(unittest.TestCase):
    def test_images_use_pinned_backend_without_becoming_chat(self):
        backend = FakeBackend()
        server = ThreadingHTTPServer(('127.0.0.1', 0), image.handler(backend))
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        self.addCleanup(backend.worker.shutdown)
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        with tempfile.TemporaryDirectory() as folder:
            lib = ROOT / 'build/ModelDock.app/Contents/Resources/ProcessIdentity.dylib'
            identity = ctypes.CDLL(str(lib)); identity.mm_process_start_time.argtypes = [ctypes.c_int]; identity.mm_process_start_time.restype = ctypes.c_uint64
            route = {'id': 'fixture-image-route', 'alias': 'image-test', 'name': 'image-test', 'model': image.MODEL, 'endpoint': f'http://127.0.0.1:{server.server_port}/v1',
                     'inputs': ['text', 'image'], 'outputs': ['image'], 'pid': os.getpid(), 'birth': identity.mm_process_start_time(os.getpid()), 'available': True}
            solution_id = '12345678-1234-1234-1234-123456789abc'
            solution = {'id': solution_id, 'recipe': 'image-generation', 'configured': True, 'components': [{'role': 'image', 'routeID': route['id']}]}
            config = Path(folder) / 'gateway.json'; config.write_text(json.dumps({'schema': 1, 'instance': 'image-fixture', 'apiKey': 'fixture-only-key', 'routes': [route], 'solutions': [solution]}))
            with socket.socket() as probe: probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
            process = subprocess.Popen([sys.executable, '-B', str(ROOT / 'Resources/gateway.py'), '--config', str(config), '--identity-lib', str(lib), '--port', str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                def call(path, body=None):
                    request = urllib.request.Request(f'http://127.0.0.1:{port}'+path, data=json.dumps(body).encode() if body is not None else None,
                        headers={'Authorization': 'Bearer fixture-only-key', 'Content-Type': 'application/json'})
                    try:
                        with urllib.request.urlopen(request, timeout=10) as r: return r.status, json.load(r)
                    except urllib.error.HTTPError as e:
                        with e: return e.code, json.load(e)
                for _ in range(100):
                    try:
                        if call('/health')[0] == 200: break
                    except OSError: time.sleep(.02)
                status, models = call('/v1/models')
                self.assertEqual(status, 200, models)
                self.assertEqual(models['data'][0]['modalities']['output'], ['image'])
                status, result = call('/v1/images/generations', {'model': 'image-test', 'prompt': 'Synthetic test image'})
                self.assertEqual(status, 200)
                self.assertEqual(base64.b64decode(result['data'][0]['b64_json']), PNG)
                self.assertEqual(call('/v1/chat/completions', {'model': 'image-test', 'messages': [{'role': 'user', 'content': 'test'}]})[0], 400)
                prefix = '/solutions/' + solution_id + '/v1'
                status, result = call(prefix + '/images/generations', {'model': 'image', 'prompt': 'Solution image'})
                self.assertEqual(status, 200, result)
                self.assertEqual(base64.b64decode(result['data'][0]['b64_json']), PNG)
                self.assertEqual(call(prefix + '/chat/completions', {'model': 'image', 'messages': []})[0], 400)
                status, result = call(prefix + '/images/edits', {'model': 'image', 'prompt': 'Private redraw prompt', 'image': base64.b64encode(PNG).decode(), 'strength': .75})
                self.assertEqual(status, 200, result)
                self.assertEqual(backend.seen[-1]['start_step'], 2)
                body, content_type = multipart({'model': 'image', 'prompt': 'Multipart redraw', 'strength': .5})
                request = urllib.request.Request(f'http://127.0.0.1:{port}' + prefix + '/images/edits', data=body, headers={'Authorization': 'Bearer fixture-only-key', 'Content-Type': content_type})
                with urllib.request.urlopen(request, timeout=10) as response: self.assertEqual(response.status, 200)
                self.assertEqual(backend.seen[-1]['start_step'], 4)
                solution['components'][0]['routeID'] = 'missing'
                config.write_text(json.dumps({'schema': 1, 'instance': 'image-fixture', 'apiKey': 'fixture-only-key', 'routes': [route], 'solutions': [solution]}))
                self.assertEqual(call(prefix + '/images/generations', {'model': 'image', 'prompt': 'x'})[0], 503)
                route['outputs'] = ['text']; config.write_text(json.dumps({'schema': 1, 'instance': 'image-fixture', 'apiKey': 'fixture-only-key', 'routes': [route]}))
                self.assertEqual(call('/v1/images/generations', {'model': 'image-test', 'prompt': 'test'})[0], 400)
                logs = (Path(folder) / 'requests.jsonl').read_text()
                self.assertNotIn('Synthetic test image', logs)
                self.assertNotIn('Private redraw prompt', logs)
                self.assertNotIn(base64.b64encode(PNG).decode(), logs)
            finally:
                process.terminate(); process.wait(timeout=5)


if __name__ == '__main__': unittest.main()
