"""Protocol tests with a fake generator; these do not claim real model inference."""
import base64
import concurrent.futures
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('image_server', ROOT / 'Resources/image_server.py')
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)
output = io.BytesIO(); Image.new('RGB', (16, 16), 'blue').save(output, format='PNG'); PNG = output.getvalue()


def multipart(fields, image_data=PNG):
    boundary = 'ModelDockFixtureBoundary'
    parts = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="../../reference.png"\r\nContent-Type: image/png\r\n\r\n'.encode() + image_data + b'\r\n')
    return b''.join(parts) + f'--{boundary}--\r\n'.encode(), 'multipart/form-data; boundary=' + boundary


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
        self.stage('complete', self.state['total'])
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
            with error: return error.code, json.load(error)

    def test_loaded_models_and_actual_image_output(self):
        status, value = self.request('/v1/models')
        self.assertEqual(status, 200)
        self.assertEqual(value['data'][0]['modalities'], {'input': ['text', 'image'], 'output': ['image']})
        self.assertIn('image_to_image', self.request('/health')[1]['features'])
        self.assertIn('reference_editing', self.request('/health')[1]['features'])
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

    def test_selected_model_identity_is_preserved(self):
        self.backend.api_model = 'vanch007/Qwen-Image-2.1-Turbo-Heretic-mlx-bf16'
        self.assertEqual(self.request('/v1/models')[1]['data'][0]['id'], self.backend.api_model)
        self.assertEqual(self.request('/v1/images/generations', {'model': image.MODEL, 'prompt': 'x'})[0], 400)
        self.assertEqual(self.request('/v1/images/generations', {'model': self.backend.api_model, 'prompt': 'x'})[0], 200)

    def test_image_upload_and_strength_map_to_real_steps(self):
        for strength, start in [(0.125, 7), (0.5, 4), (0.75, 2), (0.99, 1), (1.0, 0)]:
            status, value = self.request('/v1/images/edits', {'prompt': 'Repaint in winter', 'image': base64.b64encode(PNG).decode(), 'strength': strength})
            self.assertEqual(status, 200, value)
            self.assertEqual(self.backend.seen[-1]['image'], PNG)
            self.assertEqual(self.backend.seen[-1]['start_step'], start)
            self.assertEqual(self.request('/health')[1]['total'], 8 - start)
        body, content_type = multipart({'model': image.MODEL, 'prompt': 'A winter cabin', 'strength': 0.5, 'seed': 7, 'n': 1})
        request = urllib.request.Request(self.base + '/v1/images/edits', data=body, headers={'Content-Type': content_type})
        with urllib.request.urlopen(request, timeout=10) as response: self.assertEqual(response.status, 200)
        self.assertEqual(self.backend.seen[-1]['seed'], 7)
        self.assertNotIn('filename', self.backend.seen[-1])

    def test_reference_validation_does_not_generate_or_fetch_paths(self):
        valid = {'prompt': 'x', 'image': base64.b64encode(PNG).decode()}
        for changes in [{'image': None}, {'image': 'https://example.com/image.png'}, {'image': base64.b64encode(b'not an image').decode()},
                        {'image': True}, {'image_path': '/private/reference.png'}, {'image_url': 'http://127.0.0.1/private'},
                        {'mask': 'unused'}, {'strength': 0}, {'strength': 1.01}, {'strength': True}, {'strength': float('nan')}]:
            self.assertEqual(self.request('/v1/images/edits', {**valid, **changes})[0], 400, changes)
        big = io.BytesIO(); Image.new('RGB', (8193, 1)).save(big, format='PNG')
        self.assertEqual(self.request('/v1/images/edits', {**valid, 'image': base64.b64encode(big.getvalue()).decode()})[0], 400)
        self.assertEqual(self.request('/v1/images/generations', valid)[0], 400)
        self.assertEqual(self.backend.seen, [])

    def test_worker_normalizes_temporary_image_and_removes_it_on_success_and_failure(self):
        paths = []
        backend = self.backend
        class StubModel:
            fail = False
            def generate_image(self, **options):
                path = Path(options['image_paths'][0]); paths.append(path)
                with Image.open(path) as reference: self_test.assertEqual(reference.mode, 'RGBA')
                self_test.assertEqual(options['strength'], self_test.expected_strength)
                self_test.assertEqual(options['output_resolution'], 1024)
                self_test.assertNotIn('image_strength', options)
                self_test.assertTrue(path.is_file())
                if self.fail: raise RuntimeError('fixture failure')
                return type('Result', (), {'image': Image.new('RGB', (16, 16))})()
        self_test = self
        self.expected_strength = .75
        backend.model = StubModel()
        value = image.parameters({'prompt': 'x', 'image': PNG, 'strength': .75}, edit=True)
        backend.state['total'] = 6
        image.ImageBackend.generate(backend, value)
        self.assertFalse(paths[-1].exists())
        self.assertFalse(paths[-1].parent.exists())
        self.expected_strength = 1.0
        full = image.parameters({'prompt': 'Change only the roof to blue', 'image': PNG, 'strength': 1.0}, edit=True)
        backend.state['total'] = 8
        result = image.ImageBackend.generate(backend, full)
        self.assertEqual(result['mode'], 'reference_editing')
        self.assertEqual(result['reference_images'], 1)
        self.assertFalse(paths[-1].parent.exists())
        self.expected_strength = .75
        backend.model.fail = True
        with self.assertRaisesRegex(RuntimeError, 'fixture failure'): image.ImageBackend.generate(backend, value)
        self.assertFalse(paths[-1].parent.exists())

    def test_custom_dimensions_and_quality_are_validated_before_generation(self):
        for size in ['512x512', '1536x864', '864x1536', '1024x768', '2048x2048']:
            self.assertEqual(image.parameters({'prompt': 'x', 'size': size})['size'], size)
        for size in ['1280x720', '2049x1024', '4096x4096', '256x2048', '1024', True]:
            with self.assertRaises(ValueError): image.parameters({'prompt': 'x', 'size': size})
        for quality in ['low', 'high', 'max']:
            with self.assertRaisesRegex(ValueError, '8-step'): image.parameters({'prompt': 'x', 'quality': quality})
        self.assertEqual(self.backend.seen, [])

    def test_edit_auto_keeps_source_dimensions_and_mask_validation(self):
        source = io.BytesIO(); Image.new('RGB', (512, 256), 'blue').save(source, format='PNG')
        selection = Image.new('RGBA', (512, 256), (0, 0, 0, 255))
        selection.putpixel((100, 100), (0, 0, 0, 0))
        mask = io.BytesIO(); selection.save(mask, format='PNG')
        valid = {'prompt': 'x', 'size': 'auto', 'image': source.getvalue(), 'mask': mask.getvalue()}
        self.assertEqual(image.parameters(valid, edit=True)['size'], '512x256')
        self.assertEqual(image.parameters(valid, edit=True)['mask'], mask.getvalue())
        for changes in [{'size': '1024x1024'}, {'mask': PNG}]:
            with self.assertRaises(ValueError): image.parameters({**valid, **changes}, edit=True)
        empty = io.BytesIO(); Image.new('RGBA', (512, 256), (0, 0, 0, 255)).save(empty, format='PNG')
        with self.assertRaisesRegex(ValueError, 'empty'): image.parameters({**valid, 'mask': empty.getvalue()}, edit=True)

    def test_mask_worker_preserves_every_unselected_pixel_and_removes_uploads(self):
        source = Image.new('RGB', (256, 256), (17, 83, 129))
        original = io.BytesIO(); source.save(original, format='PNG')
        selection = Image.new('RGBA', source.size, (0, 0, 0, 255))
        selection.paste((0, 0, 0, 0), (64, 64, 128, 128))
        mask = io.BytesIO(); selection.save(mask, format='PNG')
        paths = []
        self_test = self
        class StubModel:
            def generate_image(self, **options):
                paths.extend([Path(options['image_paths'][0]), Path(options['mask_image'])])
                with Image.open(paths[1]) as native_mask:
                    self_test.assertEqual(native_mask.getpixel((0, 0)), 0)
                    self_test.assertEqual(native_mask.getpixel((80, 80)), 255)
                return type('Result', (), {'image': Image.new('RGB', source.size, 'green')})()
        self.backend.model = StubModel()
        value = image.parameters({'prompt': 'green', 'image': original.getvalue(), 'mask': mask.getvalue(), 'size': 'auto', 'strength': 1}, edit=True)
        result = image.ImageBackend.generate(self.backend, value)
        with Image.open(io.BytesIO(base64.b64decode(result['data'][0]['b64_json']))) as output:
            self.assertEqual(output.getpixel((0, 0)), (17, 83, 129, 255))
            self.assertEqual(output.getpixel((80, 80)), (0, 128, 0, 255))
            for x, y in [(63, 100), (128, 100), (100, 63), (100, 128), (255, 255)]:
                self.assertEqual(output.getpixel((x, y)), (*source.getpixel((x, y)), 255))
        self.assertTrue(result['masked_editing'])
        self.assertTrue(all(not path.exists() for path in paths))

    def test_multipart_image_array_alias_cannot_override_another_reference(self):
        body, content_type = multipart({'prompt': 'x'})
        self.assertEqual(image.request_value(body.replace(b'name="image"', b'name="image[]"'), content_type, edit=True)['image'], PNG)
        body, content_type = multipart({'prompt': 'x', 'image[]': 'duplicate'})
        with self.assertRaisesRegex(ValueError, 'duplicate'): image.request_value(body, content_type, edit=True)

    def test_large_reference_uses_its_native_detail_within_vision_limit(self):
        recorded = []
        class StubModel:
            processor = type('Processor', (), {'image_processor': type('Size', (), {'size': {'longest_edge': 1_572_864}})()})()
            def generate_image(self, **options):
                recorded.append(options['output_resolution'])
                with Image.open(options['image_paths'][0]) as original:
                    return type('Result', (), {'image': original.copy()})()
        self.backend.model = StubModel()
        for size in [(1536, 1024), (2048, 2048)]:
            source = io.BytesIO(); Image.new('RGB', size, (17, 83, 129)).save(source, format='PNG')
            value = image.parameters({'prompt': 'edit', 'image': source.getvalue(), 'size': 'auto'}, edit=True)
            result = image.ImageBackend.generate(self.backend, value)
            self.assertGreater(recorded[-1], 1024)
            self.assertLessEqual(recorded[-1] ** 2, 1_572_864)
            self.assertEqual(result['reference_resolution'], recorded[-1])

    def test_native_mlx_snapshot_requires_all_component_shards_and_turbo_schedule(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'model_index.json').write_text(json.dumps({'_class_name': 'QwenImage21Pipeline', 'sample_sigmas': list(image.SIGMAS)}))
            for component in ['transformer', 'text_encoder', 'vae']:
                (root / component).mkdir()
                (root / component / 'config.json').write_text('{}')
                (root / component / 'model.safetensors.index.json').write_text(json.dumps({'weight_map': {'weight': '0.safetensors'}}))
                (root / component / '0.safetensors').write_bytes(b'fixture')
            for name in ['processor/tokenizer.json', 'processor/tokenizer_config.json', 'processor/chat_template.jinja', 'processor/preprocessor_config.json', 'scheduler/scheduler_config.json']:
                p = root / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('{}')
            self.assertEqual(image.snapshot(root), root.resolve())
            (root / 'vae/0.safetensors').unlink()
            with self.assertRaisesRegex(ValueError, 'vae/0.safetensors'): image.snapshot(root)
            (root / 'model_index.json').write_text(json.dumps({'_class_name': 'QwenImage21Pipeline', 'sample_sigmas': [1,.98,.96,.94,.9,.8,.7,.4]}))
            with self.assertRaisesRegex(ValueError, '8-step schedule'): image.snapshot(root)

    def test_snapshot_cannot_escape_shards_or_omit_components(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'transformer').mkdir()
            (root / 'model_index.json').write_text(json.dumps({'_class_name': 'QwenImage21Pipeline', 'sample_sigmas': list(image.SIGMAS)}))
            index = root / 'transformer/diffusion_pytorch_model.safetensors.index.json'
            index.write_text(json.dumps({'weight_map': {'x': '../../outside.safetensors'}}))
            with self.assertRaisesRegex(ValueError, 'Unsafe'): image.snapshot(root)
            index.write_text(json.dumps({'weight_map': {'x': 'part-1.safetensors'}}))
            with self.assertRaisesRegex(ValueError, 'Missing image components'): image.snapshot(root)


if __name__ == '__main__':
    unittest.main()
