"""Protocol tests with a fake generator; these do not claim real model inference."""
import base64
import concurrent.futures
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('image_server', ROOT / 'Resources/image_server.py')
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=')


class FakeBackend(image.ImageBackend):
    def __init__(self):
        self.loaded = True
        self.guard = threading.Lock()
        self.state_lock = threading.RLock()
        self.cancelled = threading.Event()
        self.started = time.monotonic()
        self.state = dict(stage='ready', completed=0, total=8, job_id=None, elapsed=0)
        self.worker = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        self.release = threading.Event()
        self.release.set()
        self.seen = []

    def generate(self, value):
        self.seen.append(value)
        for _ in range(500):
            if self.cancelled.is_set():
                self.stage('cancelled'); raise RuntimeError('Cancelled')
            if self.release.wait(0.01):
                break
        self.stage('complete', 8)
        return {'created': 1, 'data': [{'b64_json': base64.b64encode(PNG).decode()}]}


class ImageServerChecks(unittest.TestCase):
    def setUp(self):
        self.backend = FakeBackend()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), image.handler(self.backend))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = 'http://127.0.0.1:' + str(self.server.server_port)

    def tearDown(self):
        self.backend.release.set()
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.backend.worker.shutdown()

    def request(self, path, value=None):
        request = urllib.request.Request(self.base + path, data=json.dumps(value).encode() if value is not None else None,
                                         headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def test_loaded_models_and_actual_image_output(self):
        status, value = self.request('/v1/models')
        self.assertEqual(status, 200)
        self.assertEqual(value['data'][0]['modalities'], {'input': ['text'], 'output': ['image']})
        status, value = self.request('/v1/images/generations', {'prompt': 'test image', 'seed': 7})
        self.assertEqual(status, 200)
        self.assertEqual(base64.b64decode(value['data'][0]['b64_json']), PNG)
        self.assertEqual(self.backend.seen[0]['size'], '1024x1024')
        self.assertEqual(self.backend.seen[0]['seed'], 7)

    def test_loading_is_not_ready_and_chat_is_not_supported(self):
        self.backend.loaded = False
        self.assertEqual(self.request('/v1/models')[0], 503)
        self.assertEqual(self.request('/v1/images/generations', {'prompt': 'test'})[0], 503)
        self.assertEqual(self.request('/v1/chat/completions', {})[0], 404)

    def test_invalid_or_unsupported_requests_never_generate(self):
        for value in [{'prompt': ''}, {'prompt': 'x', 'model': 'other'}, {'prompt': 'x', 'size': '16384x16384'},
                      {'prompt': 'x', 'seed': -1}, {'prompt': 'x', 'seed': True}, {'prompt': 'x', 'n': 2},
                      {'prompt': 'x', 'response_format': 'url'}, {'prompt': 'x', 'job_id': '../../escape'}]:
            with self.subTest(value=value):
                self.assertEqual(self.request('/v1/images/generations', value)[0], 400)
        self.assertEqual(self.backend.seen, [])

    def test_busy_progress_and_cancel_are_bound_to_request(self):
        self.backend.release.clear()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(self.request, '/v1/images/generations', {'prompt': 'test', 'job_id': 'job-A'})
            for _ in range(100):
                status, progress = self.request('/modeldock/progress')
                if progress.get('job_id') == 'job-A': break
                time.sleep(0.01)
            self.assertTrue(progress['busy'])
            self.assertEqual(self.request('/v1/images/generations', {'prompt': 'other'})[0], 409)
            self.assertEqual(self.request('/modeldock/cancel', {'job_id': 'job-B'})[0], 409)
            self.assertFalse(self.backend.cancelled.is_set())
            self.assertEqual(self.request('/modeldock/cancel', {'job_id': 'job-A'})[0], 200)
            self.assertEqual(future.result()[0], 409)
        self.assertFalse(self.request('/health')[1]['busy'])
        self.assertEqual(self.request('/health')[1]['stage'], 'cancelled')

    def test_snapshot_cannot_escape_shards_or_omit_components(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'transformer').mkdir()
            (root / 'model_index.json').write_text(json.dumps({'_class_name': 'QwenImage21Pipeline', 'sample_sigmas': [1, .98, .96, .94, .9, .8, .7, .4]}))
            index = root / 'transformer/diffusion_pytorch_model.safetensors.index.json'
            index.write_text(json.dumps({'weight_map': {'x': '../../outside.safetensors'}}))
            with self.assertRaisesRegex(ValueError, 'Unsafe'): image.snapshot(root)
            index.write_text(json.dumps({'weight_map': {'x': 'part-1.safetensors'}}))
            with self.assertRaisesRegex(ValueError, 'Missing image components'): image.snapshot(root)


if __name__ == '__main__':
    unittest.main()
