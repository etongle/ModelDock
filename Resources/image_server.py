"""Offline Qwen-Image-2.1-Turbo service. One MLX worker owns loading and generation."""
import argparse
import base64
import concurrent.futures
import io
import json
import math
import os
from pathlib import Path
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = 'Qwen/Qwen-Image-2.1-Turbo'
MAX_BODY = 64 * 1024


def snapshot(path):
    root = Path(path).resolve(strict=True)
    index = json.loads((root / 'model_index.json').read_text())
    sigmas = index.get('sample_sigmas', [])
    if index.get('_class_name') != 'QwenImage21Pipeline' or len(sigmas) != 8 or not all(
        type(x) in (int, float) and math.isfinite(x) and 0 < x <= 1 for x in sigmas
    ) or not all(a > b for a, b in zip(sigmas, sigmas[1:])):
        raise ValueError('Expected the complete Qwen-Image-2.1-Turbo pipeline and its 8-step schedule')
    required = ['processor/tokenizer.json', 'processor/tokenizer_config.json', 'processor/chat_template.jinja',
                'processor/processor_config.json', 'scheduler/scheduler_config.json', 'text_encoder/config.json',
                'transformer/config.json', 'vae/config.json', 'text_encoder/model.safetensors',
                'vae/diffusion_pytorch_model.safetensors']
    weights = json.loads((root / 'transformer/diffusion_pytorch_model.safetensors.index.json').read_text()).get('weight_map')
    if not isinstance(weights, dict) or not weights:
        raise ValueError('Missing transformer shard index')
    for shard in set(weights.values()):
        if not isinstance(shard, str) or Path(shard).name != shard or '\\' in shard or not shard.endswith('.safetensors'):
            raise ValueError('Unsafe transformer shard reference')
        required.append('transformer/' + shard)
    missing = [name for name in required if not (root / name).is_file() or (root / name).stat().st_size == 0]
    if missing:
        raise ValueError('Missing image components: ' + ', '.join(missing))
    return root


def parameters(value):
    if not isinstance(value, dict):
        raise ValueError('Expected a JSON object')
    prompt = value.get('prompt')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4096:
        raise ValueError('Supply 1–4096 characters in prompt')
    if value.get('model', MODEL) != MODEL:
        raise ValueError('The requested model is not loaded')
    if type(value.get('n', 1)) is not int or value.get('n', 1) != 1:
        raise ValueError('This local service generates one image per request')
    if value.get('response_format', 'b64_json') != 'b64_json':
        raise ValueError('Use response_format=b64_json')
    size = value.get('size', '1024x1024')
    if size not in ('1024x1024', '1344x768', '768x1344'):
        raise ValueError('Supported sizes: 1024x1024, 1344x768, 768x1344')
    seed = value.get('seed', 42)
    if type(seed) is not int or not 0 <= seed <= 4294967295:
        raise ValueError('Seed must be an integer from 0 to 4294967295')
    job = value.get('job_id') or str(uuid.uuid4())
    if not isinstance(job, str) or len(job) > 80 or not all(c.isascii() and (c.isalnum() or c in '-_') for c in job):
        raise ValueError('Invalid job_id')
    return dict(prompt=prompt, seed=seed, job_id=job, size=size)


class ImageBackend:
    def __init__(self, path, quantize=8):
        self.path, self.quantize = str(snapshot(path)), quantize
        self.loaded = False
        self.guard = threading.Lock()
        self.state_lock = threading.RLock()
        self.cancelled = threading.Event()
        self.started = time.monotonic()
        self.state = dict(stage='loading', completed=0, total=8, job_id=None, elapsed=0)
        self.worker = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix='modeldock-image')

    def progress(self):
        with self.state_lock:
            result = dict(self.state)
            if self.guard.locked():
                result['elapsed'] = round(time.monotonic() - self.started, 1)
            result['loaded'] = self.loaded
            result['busy'] = self.guard.locked()
            return result

    def stage(self, name, completed=0):
        with self.state_lock:
            self.state.update(stage=name, completed=completed)
        print('MODELDOCK_IMAGE_PROGRESS ' + json.dumps(self.progress()), flush=True)

    def load(self):
        print('Loading image model: ' + self.path, flush=True)
        import mlx.core as mx
        from mflux.models.common.config import ModelConfig
        from mflux.models.qwen21.variants.txt2img.qwen_image_21 import QwenImage21
        self.model = QwenImage21(quantize=self.quantize, model_path=self.path, model_config=ModelConfig.qwen_image_21_turbo())
        mx.eval(self.model.parameters())
        self.model.callbacks.register(self)
        self.loaded = True
        self.stage('ready')
        print('Image model loaded; HTTP server is listening', flush=True)

    def check_cancelled(self):
        if self.cancelled.is_set():
            from mflux.utils.exceptions import StopImageGenerationException
            raise StopImageGenerationException('Image generation cancelled')

    def call_before_loop(self, **kwargs):
        self.check_cancelled()
        self.stage('denoising')

    def call_in_loop(self, t, latents, **kwargs):
        import mlx.core as mx
        mx.eval(latents)
        self.check_cancelled()
        self.stage('denoising', int(t) + 1)

    def call_after_loop(self, **kwargs):
        self.check_cancelled()
        self.stage('decoding', 8)

    def generate(self, value):
        self.check_cancelled()
        self.stage('encoding')
        width, height = map(int, value['size'].split('x'))
        try:
            image = self.model.generate_image(prompt=value['prompt'], seed=value['seed'], width=width, height=height,
                                              num_inference_steps=8, guidance=1.0)
            self.check_cancelled()
            output = io.BytesIO()
            image.image.save(output, format='PNG')
            self.stage('complete', 8)
            return {'created': int(time.time()), 'data': [{'b64_json': base64.b64encode(output.getvalue()).decode('ascii')}],
                    'seed': value['seed'], 'job_id': value['job_id']}
        except Exception:
            self.stage('cancelled' if self.cancelled.is_set() else 'failed')
            raise


def handler(backend):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def send(self, status, value):
            body = json.dumps(value, ensure_ascii=False).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            self.close_connection = True

        def error(self, status, message):
            self.send(status, {'error': {'message': message, 'type': 'image_generation_error'}})

        def do_GET(self):
            if self.path in ('/health', '/modeldock/progress'):
                self.send(200, dict(service='modeldock-mflux', **backend.progress()))
            elif self.path == '/v1/models':
                if not backend.loaded:
                    self.error(503, 'Image model is still loading'); return
                self.send(200, {'object': 'list', 'data': [{'id': MODEL, 'object': 'model', 'owned_by': 'modeldock-mflux',
                    'capabilities': ['image_generation'], 'input_modalities': ['text'],
                    'modalities': {'input': ['text'], 'output': ['image']}}]})
            else:
                self.error(404, 'Use /v1/images/generations, /v1/models or /health')

        def do_POST(self):
            if self.path not in ('/v1/images/generations', '/modeldock/cancel'):
                self.error(404, 'This model supports image generation, not chat completions'); return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if self.headers.get('Transfer-Encoding') or not 0 < length <= MAX_BODY:
                    self.error(413, 'Request body is missing or too large'); return
                value = json.loads(self.rfile.read(length))
                if self.path == '/modeldock/cancel':
                    state = backend.progress()
                    if not isinstance(value, dict) or value.get('job_id') != state['job_id'] or not state['busy']:
                        self.error(409, 'This request is no longer running'); return
                    backend.cancelled.set(); self.send(200, {'cancel_requested': True}); return
                value = parameters(value)
                if not backend.loaded:
                    self.error(503, 'Image model is still loading'); return
                if not backend.guard.acquire(blocking=False):
                    self.error(409, 'An image is already being generated'); return
                try:
                    backend.cancelled.clear()
                    with backend.state_lock:
                        backend.started = time.monotonic()
                        backend.state = dict(stage='encoding', completed=0, total=8, job_id=value['job_id'], elapsed=0)
                    result = backend.worker.submit(backend.generate, value).result()
                    self.send(200, result)
                finally:
                    with backend.state_lock:
                        backend.state['elapsed'] = round(time.monotonic() - backend.started, 1)
                    backend.guard.release()
            except (ValueError, TypeError, KeyError) as error:
                self.error(400, str(error))
            except Exception as error:
                self.error(409 if backend.cancelled.is_set() else 500, str(error))

        def log_message(self, *args):
            pass
    return Handler


def main():
    parser = argparse.ArgumentParser(description='ModelDock offline Qwen-Image-2.1-Turbo service')
    parser.add_argument('--model', required=True)
    parser.add_argument('--port', type=int, default=8100)
    parser.add_argument('--quantize', type=int, choices=[4, 8, 16], default=8)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('Port must be between 1024 and 65535')
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1')
    backend = ImageBackend(args.model, None if args.quantize == 16 else args.quantize)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(backend))
    server.daemon_threads = True
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    try:
        backend.worker.submit(backend.load).result()
        server_thread.join()
    finally:
        server.shutdown(); server.server_close(); backend.worker.shutdown(wait=False, cancel_futures=True)


if __name__ == '__main__':
    main()
