"""Offline Qwen-Image-2.1-Turbo service. One MLX worker owns loading and generation."""
import argparse
import base64
import concurrent.futures
from email import policy
from email.parser import BytesParser
import io
import json
import math
import os
from pathlib import Path
import re
import threading
import tempfile
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = 'Qwen/Qwen-Image-2.1-Turbo'
SIGMAS = (1.0, 0.978453, 0.95418, 0.926626, 0.89508, 0.845148, 0.704534, 0.414568)
MAX_BODY = 64 * 1024
MAX_IMAGE = 16 * 1024 * 1024
MAX_EDIT_BODY = 48 * 1024 * 1024
MAX_PIXELS = 16_000_000


def reference_image(data):
    if not isinstance(data, bytes) or not 0 < len(data) <= MAX_IMAGE:
        raise ValueError('Reference image must be at most 16 MiB')
    from PIL import Image
    try:
        with Image.open(io.BytesIO(data)) as source:
            if source.format not in ('PNG', 'JPEG', 'WEBP') or getattr(source, 'n_frames', 1) != 1:
                raise ValueError('Use a single PNG, JPEG or WebP reference image')
            if not 0 < source.width <= 8192 or not 0 < source.height <= 8192 or source.width * source.height > MAX_PIXELS:
                raise ValueError('Reference image must be at most 16 megapixels and 8192 pixels per side')
            source.verify()
    except (OSError, SyntaxError, Image.DecompressionBombError) as error:
        raise ValueError('Invalid reference image') from error
    return data


def uploaded_image(data):
    if isinstance(data, str):
        if data.startswith('data:'):
            prefix, separator, data = data.partition(',')
            if not separator or prefix not in ('data:image/png;base64', 'data:image/jpeg;base64', 'data:image/webp;base64'):
                raise ValueError('Use PNG, JPEG or WebP base64 image data')
        try:
            data = base64.b64decode(data, validate=True)
        except ValueError as error:
            raise ValueError('Invalid base64 reference image') from error
    return reference_image(data)


def output_size(size):
    if not isinstance(size, str) or not re.fullmatch(r'[0-9]{3,4}x[0-9]{3,4}', size):
        raise ValueError('Use WIDTHxHEIGHT, in multiples of 32, between 256 and 2048 pixels')
    width, height = map(int, size.split('x'))
    if not all(256 <= side <= 2048 and side % 32 == 0 for side in (width, height)) or width * height > 4_194_304 or max(width, height) > 4 * min(width, height):
        raise ValueError('Dimensions must be multiples of 32, 256–2048 pixels per side, at most 4 megapixels and 4:1 aspect ratio')
    return width, height


def request_value(body, content_type, edit=False):
    if not edit or not content_type.lower().startswith('multipart/form-data'):
        return json.loads(body)
    message = BytesParser(policy=policy.default).parsebytes(b'Content-Type: ' + content_type.encode('ascii') + b'\r\nMIME-Version: 1.0\r\n\r\n' + body)
    parts = list(message.iter_parts())
    if not message.is_multipart() or message.defects or not 1 <= len(parts) <= 16:
        raise ValueError('Invalid multipart upload')
    value = {}
    for part in parts:
        name = part.get_param('name', header='content-disposition')
        name = 'image' if name == 'image[]' else name
        if not name or name in value or part.is_multipart() or part.defects or part.get_content_disposition() != 'form-data':
            raise ValueError('Invalid or duplicate upload field')
        data = part.get_payload(decode=True)
        if name in ('image', 'mask'):
            value[name] = data
        else:
            if len(data) > MAX_BODY:
                raise ValueError('Upload field is too large')
            value[name] = data.decode('utf-8')
    for name in ('n', 'seed'):
        if name in value:
            value[name] = int(value[name])
    if 'strength' in value:
        value['strength'] = float(value['strength'])
    return value


def snapshot(path):
    root = Path(path).resolve(strict=True)
    index = json.loads((root / 'model_index.json').read_text())
    sigmas = index.get('sample_sigmas', [])
    if index.get('_class_name') != 'QwenImage21Pipeline' or len(sigmas) != 8 or not all(
        type(x) in (int, float) and math.isfinite(x) and 0 < x <= 1 for x in sigmas
    ) or not all(abs(a - b) < 0.000001 for a, b in zip(sigmas, SIGMAS)):
        raise ValueError('Expected the complete Qwen-Image-2.1-Turbo pipeline and its 8-step schedule')
    required = ['processor/tokenizer.json', 'processor/tokenizer_config.json', 'processor/chat_template.jinja',
                'scheduler/scheduler_config.json', 'text_encoder/config.json', 'transformer/config.json', 'vae/config.json']
    required.append('processor/preprocessor_config.json' if (root / 'processor/preprocessor_config.json').is_file() else 'processor/processor_config.json')
    for component, single in [('transformer', 'diffusion_pytorch_model.safetensors'), ('text_encoder', 'model.safetensors'), ('vae', 'diffusion_pytorch_model.safetensors')]:
        native = root / component / 'model.safetensors.index.json'
        hf = root / component / 'diffusion_pytorch_model.safetensors.index.json'
        index_path = native if native.exists() else hf
        if index_path.exists() or component == 'transformer':
            weights = json.loads(index_path.read_text()).get('weight_map')
            if not isinstance(weights, dict) or not weights:
                raise ValueError('Missing component shard index: ' + component)
            for shard in set(weights.values()):
                if not isinstance(shard, str) or Path(shard).name != shard or '\\' in shard or not shard.endswith('.safetensors'):
                    raise ValueError('Unsafe component shard reference')
                required.append(component + '/' + shard)
        else:
            required.append(component + '/' + single)
    missing = [name for name in required if not (root / name).is_file() or (root / name).stat().st_size == 0]
    if missing:
        raise ValueError('Missing image components: ' + ', '.join(missing))
    return root


def parameters(value, api_model=MODEL, edit=False):
    if not isinstance(value, dict):
        raise ValueError('Expected a JSON object')
    prompt = value.get('prompt')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4096:
        raise ValueError('Supply 1–4096 characters in prompt')
    if value.get('model', api_model) != api_model:
        raise ValueError('The requested model is not loaded')
    if type(value.get('n', 1)) is not int or value.get('n', 1) != 1:
        raise ValueError('This local service generates one image per request')
    if value.get('response_format', 'b64_json') != 'b64_json':
        raise ValueError('Use response_format=b64_json')
    size = value.get('size', '1024x1024')
    if size == 'auto':
        size = '1024x1024'
        if edit:
            from PIL import Image, ImageOps
            with Image.open(io.BytesIO(uploaded_image(value.get('image')))) as source:
                width, height = ImageOps.exif_transpose(source).size
            size = f'{width}x{height}'
    output_size(size)
    if value.get('quality', 'auto') not in ('auto', 'medium'):
        raise ValueError('This Turbo checkpoint supports standard 8-step quality (auto or medium); increase the output dimensions for more pixels')
    seed = value.get('seed', 42)
    if type(seed) is not int or not 0 <= seed <= 4294967295:
        raise ValueError('Seed must be an integer from 0 to 4294967295')
    job = value.get('job_id') or str(uuid.uuid4())
    if not isinstance(job, str) or len(job) > 80 or not all(c.isascii() and (c.isalnum() or c in '-_') for c in job):
        raise ValueError('Invalid job_id')
    result = dict(prompt=prompt, seed=seed, job_id=job, size=size, start_step=0)
    if any(k in value for k in ('image_url', 'image_path')):
        raise ValueError('Use an uploaded image; URLs and filesystem paths are not supported')
    if edit:
        result['image'] = uploaded_image(value.get('image'))
        if 'mask' in value:
            from PIL import Image, ImageOps
            mask = uploaded_image(value['mask'])
            with Image.open(io.BytesIO(result['image'])) as source, Image.open(io.BytesIO(mask)) as selection:
                if selection.format != 'PNG' or 'A' not in selection.getbands():
                    raise ValueError('Use a PNG mask with a transparent alpha channel over the area to edit')
                if selection.size != ImageOps.exif_transpose(source).size:
                    raise ValueError('Mask and reference image dimensions must match')
                if selection.getchannel('A').getextrema() == (255, 255):
                    raise ValueError('The mask is empty; mark a transparent area to edit')
                if selection.size != output_size(size):
                    raise ValueError('For masked editing, keep the original image dimensions (size=auto)')
            result['mask'] = mask
        strength = value.get('strength', 0.75)
        if type(strength) not in (int, float) or not math.isfinite(strength) or not 0.125 <= strength <= 1:
            raise ValueError('Strength must be a number from 0.125 to 1 (higher redraws more)')
        # Reference editing keeps visual conditioning at every strength, including 1.0.
        result['start_step'] = 0 if strength == 1 else max(1, int(8 * (1 - strength)))
        result['strength'] = strength
    elif any(key in value for key in ('image', 'strength', 'mask')):
        raise ValueError('Use /v1/images/edits for image-to-image')
    return result


class ImageBackend:
    def __init__(self, path, quantize=8, api_model=MODEL):
        self.api_model = api_model
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
        from mflux.models.qwen21.variants.edit.qwen_image_21_edit import QwenImage21Edit
        self.model = QwenImage21Edit(quantize=self.quantize, model_path=self.path, model_config=ModelConfig.qwen_image_21_turbo())
        from mflux.models.common.vae.tiling_config import TilingConfig
        self.model.tiling_config = TilingConfig(vae_decode_tiles_per_dim=None, vae_decode_tile_size=512)
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
        self.stage('denoising', int(t) + 1 - self.start_step)

    def call_after_loop(self, **kwargs):
        self.check_cancelled()
        self.stage('decoding', self.state['total'])

    def generate(self, value):
        self.check_cancelled()
        self.stage('encoding_image' if 'image' in value else 'encoding')
        self.start_step = value['start_step']
        width, height = map(int, value['size'].split('x'))
        try:
            with tempfile.TemporaryDirectory(prefix='modeldock-image-') as folder:
                options = {}
                if 'image' in value:
                    from PIL import Image, ImageOps
                    path = Path(folder) / 'reference.png'
                    with Image.open(io.BytesIO(value['image'])) as source:
                        original = ImageOps.exif_transpose(source).convert('RGBA')
                        original.save(path, format='PNG')
                        reference_resolution = max(1024, min(2048, round(math.sqrt(original.width * original.height) / 32) * 32))
                        processor = getattr(getattr(self.model, 'processor', None), 'image_processor', None)
                        max_area = getattr(processor, 'size', {}).get('longest_edge', 4_194_304)
                        # 保留大图参考细节；只在视觉编码器实际像素上限要求时降低参考分辨率。
                        ratio = original.width / original.height
                        while reference_resolution > 32:
                            rw = max(32, round(reference_resolution * math.sqrt(ratio) / 32) * 32)
                            rh = max(32, round(reference_resolution / math.sqrt(ratio) / 32) * 32)
                            if rw * rh <= max_area:
                                break
                            reference_resolution -= 32
                    path.chmod(0o600)
                    options = dict(image_paths=[str(path)], strength=value['strength'], output_resolution=reference_resolution)
                    if 'mask' in value:
                        # Images API: transparent edits. MFLUX: white edits, black preserves.
                        with Image.open(io.BytesIO(value['mask'])) as selection:
                            repaint = ImageOps.invert(selection.getchannel('A'))
                        mask_path = Path(folder) / 'mask.png'
                        repaint.save(mask_path, format='PNG')
                        mask_path.chmod(0o600)
                        options['mask_image'] = str(mask_path)
                self.check_cancelled()
                image = self.model.generate_image(prompt=value['prompt'], seed=value['seed'], width=width, height=height,
                                                  num_inference_steps=8, guidance=1.0, **options)
                if 'mask' in value:
                    with Image.open(path) as original:
                        image.image = Image.composite(image.image.convert('RGBA'), original.convert('RGBA'), repaint)
            self.check_cancelled()
            output = io.BytesIO()
            image.image.save(output, format='PNG')
            self.stage('complete', self.state['total'])
            return {'created': int(time.time()), 'data': [{'b64_json': base64.b64encode(output.getvalue()).decode('ascii')}],
                    'seed': value['seed'], 'job_id': value['job_id'], 'steps': self.state['total'],
                    'size': value['size'], 'quality': 'medium', 'reference_resolution': reference_resolution if 'image' in value else None,
                    'mode': 'reference_editing' if 'image' in value else 'text_to_image', 'reference_images': int('image' in value),
                    'masked_editing': 'mask' in value}
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
                self.send(200, dict(service='modeldock-mflux', features=['image_to_image', 'reference_editing', 'masked_editing'],
                    image_options={'min_side':256, 'max_side':2048, 'dimension_multiple':32, 'max_pixels':4_194_304, 'quality':['auto','medium'], 'steps':8}, **backend.progress()))
            elif self.path == '/v1/models':
                if not backend.loaded:
                    self.error(503, 'Image model is still loading'); return
                self.send(200, {'object': 'list', 'data': [{'id': getattr(backend, 'api_model', MODEL), 'object': 'model', 'owned_by': 'modeldock-mflux',
                    'capabilities': ['image_generation', 'image_to_image'], 'input_modalities': ['text', 'image'],
                    'modalities': {'input': ['text', 'image'], 'output': ['image']}}]})
            else:
                self.error(404, 'Use /v1/images/generations, /v1/models or /health')

        def do_POST(self):
            if self.path not in ('/v1/images/generations', '/v1/images/edits', '/modeldock/cancel'):
                self.error(404, 'This model supports image generation, not chat completions'); return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                edit = self.path == '/v1/images/edits'
                if self.headers.get('Transfer-Encoding') or not 0 < length <= (MAX_EDIT_BODY if edit else MAX_BODY):
                    self.error(413, 'Request body is missing or too large'); return
                self.connection.settimeout(30)
                body = self.rfile.read(length)
                if len(body) != length:
                    self.error(400, 'Incomplete request body'); return
                value = request_value(body, self.headers.get('Content-Type', 'application/json'), edit)
                if self.path == '/modeldock/cancel':
                    state = backend.progress()
                    if not isinstance(value, dict) or value.get('job_id') != state['job_id'] or not state['busy']:
                        self.error(409, 'This request is no longer running'); return
                    backend.cancelled.set(); self.send(200, {'cancel_requested': True}); return
                value = parameters(value, getattr(backend, 'api_model', MODEL), edit)
                if not backend.loaded:
                    self.error(503, 'Image model is still loading'); return
                if not backend.guard.acquire(blocking=False):
                    self.error(409, 'An image is already being generated'); return
                try:
                    backend.cancelled.clear()
                    with backend.state_lock:
                        backend.started = time.monotonic()
                        backend.state = dict(stage='encoding_image' if edit else 'encoding', completed=0, total=8 - value['start_step'], job_id=value['job_id'], elapsed=0)
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
    parser.add_argument('--api-model', default=MODEL)
    parser.add_argument('--port', type=int, default=8100)
    parser.add_argument('--quantize', type=int, choices=[4, 8, 16], default=8)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('Port must be between 1024 and 65535')
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1')
    backend = ImageBackend(args.model, None if args.quantize == 16 else args.quantize, args.api_model)
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
