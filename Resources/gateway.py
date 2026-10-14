#!/usr/bin/env python3
"""Loopback OpenAI gateway. Model payloads are forwarded, never logged."""
import argparse
import ctypes
import hmac
import json
import os
import re
import signal
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument('--config', required=True)
parser.add_argument('--identity-lib', required=True)
parser.add_argument('--port', required=True, type=int)
args = parser.parse_args()
identity = ctypes.CDLL(args.identity_lib)
identity.mm_process_start_time.argtypes = [ctypes.c_int]
identity.mm_process_start_time.restype = ctypes.c_uint64
identity.mm_process_belongs_to.argtypes = [ctypes.c_int, ctypes.c_uint64, ctypes.c_int, ctypes.c_uint64]
identity.mm_process_belongs_to.restype = ctypes.c_int

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *unused):
        return None

opener = urllib.request.build_opener(NoRedirect())
slots = threading.BoundedSemaphore(16)
stats_lock = threading.Lock()
stats = {'requests': 0, 'active': 0, 'failed': 0, 'total_ms': 0.0}
started = time.time()
allowed = {'/v1/chat/completions', '/v1/completions', '/v1/embeddings', '/v1/responses',
           '/v1/audio/transcriptions', '/v1/audio/translations', '/v1/audio/speech',
           '/v1/images/generations', '/v1/images/edits'}

def configuration():
    with open(args.config, 'r', encoding='utf-8') as file:
        result = json.load(file)
    if result.get('schema') != 1:
        raise ValueError('unsupported gateway configuration')
    return result

def pinned(route):
    if not route.get('available', False):
        return False
    pid, birth = int(route.get('pid') or 0), int(route.get('birth') or 0)
    if not pid:
        return route.get('remote', False)
    if not birth or identity.mm_process_start_time(pid) != birth:
        return False
    port = urllib.parse.urlsplit(route['endpoint']).port or 80
    result = subprocess.run(['/usr/sbin/lsof', '-nP', '-a', '-i4TCP:' + str(port),
                             '-sTCP:LISTEN', '-Fpn'], capture_output=True, timeout=3)
    listener, found = None, []
    for line in result.stdout.decode('utf-8', 'replace').splitlines():
        if line.startswith('p'):
            listener = int(line[1:])
        elif line.startswith('n') and listener:
            host, _, value = line[1:].rpartition(':')
            if host in ['127.0.0.1', '*'] and value == str(port):
                found.append(listener)
    return bool(found) and all(identity.mm_process_belongs_to(p, identity.mm_process_start_time(p), pid, birth) == 1 for p in found)

def upstream_url(route, path):
    base = route['endpoint'].rstrip('/')
    parts = urllib.parse.urlsplit(base)
    if parts.scheme not in ['http', 'https'] or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
        raise ValueError('invalid configured endpoint')
    return base + path[len('/v1'):]

def authorization(route):
    return {'Authorization': 'Bearer ' + route['apiKey']} if route.get('apiKey') else {}

def media_needed(value):
    needed = set()
    if isinstance(value, dict):
        kind = value.get('type')
        if kind in ['image_url', 'input_image', 'image']:
            needed.add('image')
        elif kind in ['input_audio', 'audio', 'audio_url']:
            needed.add('audio')
        elif kind in ['file', 'input_file', 'document']:
            needed.add('file')
        elif kind in ['video', 'input_video', 'video_url']:
            needed.add('video')
        for key, item in value.items():
            if key in ['image_url', 'images'] and item:
                needed.add('image')
            elif key == 'input_audio' and item:
                needed.add('audio')
            needed.update(media_needed(item))
    elif isinstance(value, list):
        for item in value:
            needed.update(media_needed(item))
    return needed

class Gateway(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'ModelManagerGateway/1'

    def log_message(self, *unused):
        pass

    def json_response(self, code, value):
        data = json.dumps(value, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def error(self, code, message, kind='gateway_error'):
        self.json_response(code, {'error': {'message': message, 'type': kind, 'code': kind}})

    def authenticated(self, config):
        key = self.headers.get('Authorization', '')
        expected = 'Bearer ' + config['apiKey']
        return hmac.compare_digest(key.encode(), expected.encode())

    def do_GET(self):
        try:
            config = configuration()
            if not self.authenticated(config):
                self.error(401, '网关密钥无效。', 'authentication_error'); return
            path = urllib.parse.urlsplit(self.path).path
            if path == '/health':
                self.json_response(200, {'status': 'ready', 'instance': config['instance'], 'schema': 1,
                                         'pid': os.getpid(), 'birth': identity.mm_process_start_time(os.getpid())}); return
            if path == '/gateway/status':
                with stats_lock:
                    value = dict(stats)
                value['uptime'] = time.time() - started
                self.json_response(200, value); return
            routes = [r for r in config['routes'] if r.get('enabled', True) and pinned(r)]
            def model(route):
                return {'id': route['alias'], 'object': 'model', 'created': int(started),
                        'owned_by': 'model-manager', 'name': route['name'],
                        'input_modalities': route['inputs'], 'context_length': route.get('context'),
                        'backend_revision': route['revision'], 'upstream_model': route['model'],
                        'modalities': {'input': route['inputs'], 'output': route.get('outputs', ['text'])}}
            if path == '/v1/models':
                self.json_response(200, {'object': 'list', 'data': [model(r) for r in routes]}); return
            if path.startswith('/v1/models/'):
                alias = urllib.parse.unquote(path[len('/v1/models/'):])
                selected = next((r for r in routes if r['alias'] == alias), None)
                if selected:
                    self.json_response(200, model(selected)); return
            self.error(404, '未找到网关接口或模型。', 'not_found')
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception:
            self.error(503, '网关配置或服务暂不可用。')

    def do_POST(self):
        acquired, upstream, began, headers_sent = False, None, time.monotonic(), False
        try:
            self.connection.settimeout(30)
            config = configuration()
            if not self.authenticated(config):
                self.error(401, '网关密钥无效。', 'authentication_error'); return
            path = urllib.parse.urlsplit(self.path).path
            if path not in allowed or urllib.parse.urlsplit(self.path).query:
                self.error(404, '此接口未提供网关路由。', 'not_found'); return
            if self.headers.get('Transfer-Encoding'):
                self.error(411, '请提供 Content-Length。', 'invalid_request_error'); return
            try:
                length = int(self.headers.get('Content-Length', '0'))
            except ValueError:
                self.error(400, 'Content-Length 无效。', 'invalid_request_error'); return
            if length <= 0 or length > 64 * 1024 * 1024:
                self.error(413, '请求需要非空且不超过 64 MiB。', 'request_too_large'); return
            if not slots.acquire(blocking=False):
                self.error(429, '网关并发请求已满，请稍后重试。', 'rate_limit_error'); return
            acquired = True
            with stats_lock:
                stats['requests'] += 1; stats['active'] += 1
            body = self.rfile.read(length)
            if len(body) != length:
                self.error(400, '请求未完整接收。', 'invalid_request_error'); return
            content_type = self.headers.get('Content-Type', 'application/json')
            multipart = content_type.startswith('multipart/form-data')
            if multipart:
                match = re.search(rb'(name="model"[^\r\n]*\r\n\r\n)([^\r\n]+)', body)
                if not match:
                    self.error(400, '上传请求缺少模型名称。', 'invalid_request_error'); return
                alias = match.group(2).decode('utf-8')
                needed = {'audio'} if path.startswith('/v1/audio/') else {'image'}
                value = None
            else:
                try:
                    value = json.loads(body)
                except (ValueError, UnicodeError):
                    self.error(400, '请求不是有效 JSON。', 'invalid_request_error'); return
                if not isinstance(value, dict) or not isinstance(value.get('model'), str):
                    self.error(400, '请选择网关公布的模型。', 'invalid_request_error'); return
                # Tool schemas may describe image fields; inspect user input, not schemas.
                payload = {k: value[k] for k in ['messages', 'input', 'prompt', 'images'] if k in value}
                alias, needed = value['model'], media_needed(payload)
            route = next((r for r in config['routes'] if r['alias'] == alias and r.get('enabled', True)), None)
            if not route:
                self.error(404, '模型未注册到网关。', 'model_not_found'); return
            if not pinned(route):
                self.error(503, '原模型服务已停止或端口归属已改变。', 'backend_unavailable'); return
            if not needed.issubset(set(route['inputs'])):
                self.error(400, '此路由的输入模式不接受这些媒体：' + ', '.join(sorted(needed)), 'unsupported_modality'); return
            # Verify the model still belongs to the pinned backend before forwarding payloads.
            probe = urllib.request.Request(upstream_url(route, '/v1/models'), headers=authorization(route))
            with opener.open(probe, timeout=10) as response:
                listed = json.loads(response.read(16 * 1024 * 1024 + 1))
            if route['model'] not in [m.get('id') for m in listed.get('data', [])] or not pinned(route):
                self.error(503, '后端模型或服务已变化，请刷新模型服务。', 'backend_changed'); return
            if multipart:
                body = body[:match.start(2)] + route['model'].encode() + body[match.end(2):]
            else:
                value['model'] = route['model']
                body = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
            headers = authorization(route)
            headers['Content-Type'] = content_type
            headers['Accept'] = self.headers.get('Accept', '*/*')
            request = urllib.request.Request(upstream_url(route, path), data=body, headers=headers, method='POST')
            try:
                upstream = opener.open(request, timeout=300)
            except urllib.error.HTTPError as error:
                upstream = error
            self.send_response(upstream.status)
            for name in ['Content-Type', 'Retry-After', 'X-Request-ID']:
                if upstream.headers.get(name):
                    self.send_header(name, upstream.headers[name])
            self.send_header('Transfer-Encoding', 'chunked')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            self.end_headers(); headers_sent = True
            while True:
                chunk = upstream.read1(32768)
                if not chunk:
                    break
                self.wfile.write(format(len(chunk), 'x').encode() + b'\r\n' + chunk + b'\r\n')
                self.wfile.flush()
            self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
            self.close_connection = True
            if upstream.status >= 400:
                with stats_lock:
                    stats['failed'] += 1
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception:
            with stats_lock:
                stats['failed'] += 1
            if not headers_sent:
                self.error(502, '后端请求失败或响应中断，请查看对应模型服务。', 'backend_error')
            else:
                self.close_connection = True
        finally:
            if upstream:
                upstream.close()
            if acquired:
                with stats_lock:
                    stats['active'] -= 1; stats['total_ms'] += (time.monotonic() - began) * 1000
                slots.release()

server = ThreadingHTTPServer(('127.0.0.1', args.port), Gateway)
server.daemon_threads = True
signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
server.serve_forever(poll_interval=0.2)
server.server_close()
