"""Loopback-only GPT Image Playground adapter. Gateway credentials stay server-side."""
import argparse
import base64
from email import policy
from email.parser import BytesParser
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent
STATE = Path.home() / 'Library/Application Support/ModelManager'
ROUTES = {
    '/modeldock/v1/responses': 'splash-',
    '/modeldock/v1/images/generations': 'mflux-',
    '/modeldock/v1/images/edits': 'mflux-',
}
SIZES = ('512x512', '1024x1024', '1536x1536', '2048x2048', '1536x864', '864x1536', '1024x768', '768x1024')
REF = re.compile(r'<ref\b[^>]*\bid=[\"\x27](round-\d+-(?:image|reference)-\d+)[\"\x27][^>]*\/?>')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def reference_contract(value):
    refs = []
    for item in value.get('input', []) if isinstance(value.get('input'), list) else []:
        if not isinstance(item, dict):
            continue
        for part in item.get('content', []) if isinstance(item.get('content'), list) else []:
            if isinstance(part, dict) and isinstance(part.get('text'), str):
                refs.extend(REF.findall(part['text']))
    refs = list(dict.fromkeys(refs))
    reference = {'type': 'array', 'maxItems': 1, 'items': {'type': 'string'},
                 'description': 'For an edit, choose exactly ONE source image id from the conversation. Use [] only to create a new unrelated image. Prefer the image explicitly cited in the latest user message; otherwise edit the latest generated result.'}
    if refs:
        reference['items']['enum'] = refs
    else:
        reference['maxItems'] = 0
    for tool in value.get('tools', []):
        schema = tool.get('parameters', {})
        if tool.get('name') == 'generate_image_batch':
            schema = schema.get('properties', {}).get('images', {}).get('items', {})
        elif tool.get('name') != 'generate_image':
            continue
        schema.setdefault('properties', {})['reference_ids'] = reference
        schema['required'] = list(dict.fromkeys([*schema.get('required', []), 'reference_ids']))
    if value.get('tools'):
        value['instructions'] = value.get('instructions', '') + '\n\nLocal image-editing contract: always fill reference_ids in image tools. For editing or a short follow-up such as "make it green", select the current source image id, and describe only the requested changes plus what to preserve. Do not create a new picture for a follow-up edit. This local image backend accepts ONE reference image. Keep references in tool arguments, not in visible reply text.'
    return refs


def stop_failed_continuation(value):
    inputs = value.get('input', [])
    if not isinstance(inputs, list) or not inputs:
        return
    last = inputs[-1]
    parts = last.get('content', []) if isinstance(last, dict) else []
    texts = [part.get('text', '') for part in parts if isinstance(part, dict)] if isinstance(parts, list) else []
    if not any(text.startswith('[System] The app has saved your generated outputs and is continuing the same Agent turn.') for text in texts):
        return
    for item in reversed(inputs):
        if not isinstance(item, dict) or item.get('type') != 'function_call_output':
            continue
        try:
            result = json.loads(item.get('output', ''))
        except (ValueError, TypeError):
            return
        if isinstance(result, dict) and (result.get('status') == 'error' or result.get('error')):
            raise ValueError('图片任务失败，已停止自动重试。请查看失败任务中的报错，修正后重试该轮。')
        return


def bind_references(output, available):
    bindings = []
    for item in output.get('output', []):
        if item.get('type') != 'function_call' or item.get('name') not in ('generate_image', 'generate_image_batch'):
            continue
        arguments = json.loads(item.get('arguments', '{}'))
        images = arguments.get('images', []) if item['name'] == 'generate_image_batch' else [arguments]
        for image in images:
            refs = image.get('reference_ids')
            if refs is None and available:
                raise ValueError('对话模型没有指定参考图片，已阻止误用文生图；请重试该轮。')
            if not isinstance(refs or [], list) or len(refs or []) > 1 or any(ref not in available for ref in refs or []):
                raise ValueError('对话模型指定了无效参考图，已阻止提交；请重试该轮。')
            prompt = image.get('prompt', '')
            existing = REF.findall(prompt)
            if existing and refs and set(existing) != set(refs):
                raise ValueError('对话模型指定的参考图存在冲突，已阻止提交。')
            refs = list(dict.fromkeys([*(refs or []), *existing]))
            if len(refs) > 1 or any(ref not in available for ref in refs):
                raise ValueError('请只选择当前分支内的一张参考图。')
            if refs and not existing:
                image['prompt'] = f'<ref id="{refs[0]}" />\n' + prompt
            bindings.append(refs)
        item['arguments'] = json.dumps(arguments, ensure_ascii=False)
    return bindings


def image_value(body, content_type, edit):
    if not content_type.startswith('multipart/form-data'):
        value = json.loads(body)
    else:
        message = BytesParser(policy=policy.default).parsebytes(
            b'Content-Type: ' + content_type.encode('ascii') + b'\r\nMIME-Version: 1.0\r\n\r\n' + body)
        if not message.is_multipart() or message.defects:
            raise ValueError('图片上传格式无效。')
        value, images = {}, []
        for part in message.iter_parts():
            name = part.get_param('name', header='content-disposition')
            if not name or part.is_multipart() or part.defects:
                raise ValueError('图片上传字段无效。')
            data = part.get_payload(decode=True)
            if name in ('image', 'image[]'):
                images.append(data)
            elif name == 'mask':
                if name in value:
                    raise ValueError('上传包含重复遮罩。')
                value[name] = base64.b64encode(data).decode('ascii')
            elif name in value:
                raise ValueError('上传包含重复字段。')
            else:
                value[name] = data.decode('utf-8')
        if len(images) != 1:
            raise ValueError('当前本地 Qwen 服务每次接受一张参考图，请只选择要继续修改的那张。')
        value['image'] = base64.b64encode(images[0]).decode('ascii')
    if not isinstance(value, dict):
        raise ValueError('请求必须为 JSON 对象。')
    if 'mask' in value and not edit:
        raise ValueError('局部遮罩必须与参考图一起使用。')
    if int(value.get('n', 1)) != 1:
        raise ValueError('当前本地服务每次生成一张图片，请将张数设为 1。')
    size = value.get('size', 'auto')
    if size != 'auto':
        if not isinstance(size, str) or not re.fullmatch(r'[0-9]{3,4}x[0-9]{3,4}', size):
            raise ValueError('尺寸支持 256–2048 像素，宽高须为 32 的倍数。')
        width, height = map(int, size.split('x'))
        if not all(256 <= side <= 2048 and side % 32 == 0 for side in (width, height)) or max(width, height) > 4 * min(width, height):
            raise ValueError('尺寸支持 256–2048 像素，宽高须为 32 的倍数，长宽比不超过 4:1。')
    quality = value.get('quality', 'auto')
    if quality not in ('auto', 'medium'):
        raise ValueError('Qwen Turbo 使用标准 8 步质量，请选“标准（8 步）”。需要更多细节时提高图片尺寸；高质量标签不会增加模型能力。')
    if value.get('output_format', 'png') != 'png':
        raise ValueError('本地验证版本输出 PNG，请将输出格式设为 PNG。')
    if value.get('background') == 'transparent':
        raise ValueError('当前本地服务没有原生透明背景输出。')
    if value.get('stream') not in (None, False, 'false'):
        raise ValueError('本地图片接口使用非流式结果，请关闭图片流式生成。')
    result = {key: value[key] for key in ('model', 'prompt', 'seed', 'job_id') if key in value}
    result.update(size=size, quality=quality, n=1, response_format='b64_json')
    if edit:
        if not isinstance(value.get('image'), str):
            raise ValueError('请提供一张 PNG、JPEG 或 WebP 参考图。')
        result['image'] = value['image']
        if 'mask' in value:
            if not isinstance(value['mask'], str):
                raise ValueError('请提供 PNG 透明遮罩。')
            result['mask'] = value['mask']
        # Turbo 的 8 步参考编辑保留视觉条件，不能使用旧版纯噪声图生图路径。
        result['strength'] = float(value.get('strength', 1))
    return result


def summarize(value):
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True).encode()
    images = []
    def walk(item):
        if isinstance(item, dict):
            for key, child in item.items():
                if key in ('image', 'image_url') and isinstance(child, str):
                    raw = child.partition(',')[2] if child.startswith('data:') else child
                    try:
                        images.append(digest(base64.b64decode(raw, validate=True)))
                    except ValueError:
                        images.append('not-inline-image')
                else:
                    walk(child)
        elif isinstance(item, list):
            for child in item:
                walk(child)
    walk(value)
    return {'payloadSHA256': digest(encoded), 'imageSHA256': images,
            'inputItems': len(value['input']) if isinstance(value.get('input'), list) else None,
            'size': value.get('size')}


class PreviewServer(ThreadingHTTPServer):
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def trusted(self):
        hosts = (f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}')
        origin = self.headers.get('Origin')
        return (self.headers.get('Host') in hosts
                and (not origin or origin in tuple('http://' + host for host in hosts))
                and self.headers.get('Sec-Fetch-Site') != 'cross-site')

    def reply(self, status, body, content_type='application/json'):
        if not isinstance(body, bytes):
            body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' data: blob:; frame-ancestors 'none'; object-src 'none'")
        self.end_headers()
        self.wfile.write(body)

    def error(self, status, message):
        self.reply(status, {'error': {'message': message, 'type': 'local_preview_error'}})

    def do_GET(self):
        if not self.trusted():
            self.error(403, '仅允许本地验证页面访问。'); return
        path = urllib.parse.urlsplit(self.path).path
        if path == '/modeldock/progress':
            job = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get('job_id', [''])[0]
            if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', job):
                self.error(400, '图片任务编号无效。'); return
            config = json.loads((self.server.state_dir / 'gateway/settings.json').read_text())
            port = self.server.image_port
            if not port:
                self.error(503, '图片进度暂不可用。'); return
            request = urllib.request.Request(f'http://127.0.0.1:{port}/modeldock/progress', headers={'Authorization': 'Bearer ' + config['apiKey']})
            try:
                with urllib.request.urlopen(request, timeout=5) as response:
                    value = json.loads(response.read(65536))
                self.reply(200, value if value.get('job_id') == job else {'job_id': job, 'stage': 'waiting', 'completed': 0, 'total': 8})
            except (OSError, ValueError):
                self.error(503, '暂时无法读取图片生成进度。')
            return
        if path == '/modeldock/health':
            preset = json.loads(self.server.config_path.read_text())
            self.reply(200, {'status': 'ok', 'service': 'modeldock-playground', 'solutionID': preset.get('solution_id'), 'localOnly': True, 'upstreamCommit': self.server.commit,
                             'sizes': SIZES, 'dimensionMultiple': 32, 'minSide': 256, 'maxSide': 2048,
                             'quality': ['auto', 'medium'], 'steps': 8, 'imageReferences': 1,
                             'mask': bool(self.server.image_port), 'imageValidationPort': self.server.image_port}); return
        if path == '/modeldock/config.json':
            config = json.loads(self.server.config_path.read_text())
            for profile in config['profiles']:
                profile['baseUrl'] = f'http://127.0.0.1:{self.server.server_port}/modeldock/v1/'
                profile['apiKey'] = 'modeldock-loopback'
            self.reply(200, {key: config[key] for key in ('profiles', 'agent', 'customProviders') if key in config}); return
        if path == '/modeldock/v1/models':
            self.reply(200, {'data': [{'id': model} for model in self.server.models.values()]}); return
        if path == '/sw.js':
            # 隔离预览不缓存离线资源，重建后始终加载当前配置。
            self.reply(200, b"self.addEventListener('install', () => self.skipWaiting());", 'application/javascript'); return
        file = (self.server.dist / urllib.parse.unquote(path).lstrip('/')).resolve()
        if not file.is_relative_to(self.server.dist) or any(part.startswith('.') for part in file.relative_to(self.server.dist).parts):
            self.error(404, '文件不存在。'); return
        if path == '/' or not file.exists() and '.' not in file.name:
            file = self.server.dist / 'index.html'
        if not file.is_file():
            self.error(404, '文件不存在。'); return
        self.reply(200, file.read_bytes(), mimetypes.guess_type(file.name)[0] or 'application/octet-stream')

    def do_POST(self):
        started = time.monotonic()
        if not self.trusted():
            self.error(403, '仅允许本地验证页面访问。'); return
        path = urllib.parse.urlsplit(self.path).path
        if path not in ROUTES or urllib.parse.urlsplit(self.path).query:
            self.error(404, '此验证服务未提供该接口。'); return
        try:
            size = int(self.headers.get('Content-Length', '0'))
            if self.headers.get('Transfer-Encoding') or not 0 < size <= 64 * 1024 * 1024:
                raise ValueError('请求大小无效或超过 64 MiB。')
            body = self.rfile.read(size)
            if len(body) != size:
                raise ValueError('请求未完整接收。')
            if path.endswith('/responses'):
                value = json.loads(body)
                if not isinstance(value, dict):
                    raise ValueError('请求必须为 JSON 对象。')
                if value.get('stream'):
                    raise ValueError('本地验证的聊天配置请关闭流式模式。')
                if any(tool.get('type') != 'function' for tool in value.get('tools', [])):
                    raise ValueError('请使用混合模式，并关闭 Web 搜索；图片由本机 MFLUX 生成。')
                stop_failed_continuation(value)
                value.setdefault('max_output_tokens', 2048)
                value['store'] = False
                available_refs = reference_contract(value)
            else:
                value = image_value(body, self.headers.get('Content-Type', ''), path.endswith('/edits'))
            kind = 'chat' if path.endswith('/responses') else 'image'
            if value.get('model') != self.server.models[kind]:
                raise ValueError('请选择预置的 ModelDock 本地模型配置。')
            config = json.loads((self.server.state_dir / 'gateway/settings.json').read_text())
            binding = json.loads(self.server.config_path.read_text())
            backend = f'http://127.0.0.1:{config["port"]}'
            if kind == 'image' and self.server.image_port:
                backend = f'http://127.0.0.1:{self.server.image_port}'
                value['model'] = binding.get('image_model', 'Qwen/Qwen-Image-2.1-Turbo')
            elif kind == 'chat':
                value['model'] = binding.get('chat_route', value['model'])
            data = json.dumps(value, ensure_ascii=False).encode()
            request = urllib.request.Request(backend + path.removeprefix('/modeldock'), data=data,
                headers={'Authorization': 'Bearer ' + config['apiKey'], 'Content-Type': 'application/json'})
            try:
                response = urllib.request.urlopen(request, timeout=1800 if kind == 'image' else 300)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                payload = response.read()
                status = response.status
            record = {'at': time.time(), 'path': path, 'status': status, 'elapsed': round(time.monotonic() - started, 2), **summarize(value)}
            try:
                output = json.loads(payload)
            except ValueError:
                output = None
            if isinstance(output, dict) and status == 200:
                if kind == 'image':
                    record['outputSHA256'] = [digest(base64.b64decode(image['b64_json'])) for image in output.get('data', [])]
                else:
                    record['boundReferences'] = bind_references(output, available_refs)
                    payload = json.dumps(output, ensure_ascii=False).encode()
                    record['toolCalls'] = [{'name': item.get('name'), 'argumentsSHA256': digest(item.get('arguments', '').encode())}
                                           for item in output.get('output', []) if item.get('type') == 'function_call']
            with (self.server.config_path.parent / 'requests.jsonl').open('a') as log:
                log.write(json.dumps(record) + '\n')
            self.reply(status, payload)
        except (ValueError, TypeError, KeyError) as error:
            self.error(400, str(error))
        except (OSError, urllib.error.URLError) as error:
            self.error(502, '本地服务连接失败，请确认 ModelDock 网关和对应服务仍在运行。')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=18791)
    parser.add_argument('--image-port', type=int)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--dist', type=Path, required=True)
    parser.add_argument('--state-dir', type=Path, default=STATE)
    args = parser.parse_args()
    server = PreviewServer(('127.0.0.1', args.port), Handler)
    if args.image_port is not None and not 1024 <= args.image_port <= 65535:
        parser.error('image port must be a local service port')
    server.image_port = args.image_port
    server.dist = args.dist.resolve()
    server.state_dir = args.state_dir
    server.config_path = args.config.resolve()
    preset = json.loads(server.config_path.read_text())
    server.models = {'image': preset['profiles'][0]['model'], 'chat': preset['profiles'][1]['model'] if len(preset['profiles']) > 1 else ''}
    server.commit = preset.get('upstreamCommit', 'CookSleep/gpt_image_playground')
    print(f'Playground local preview: http://127.0.0.1:{args.port}', flush=True)
    server.serve_forever()

if __name__ == '__main__':
    main()
