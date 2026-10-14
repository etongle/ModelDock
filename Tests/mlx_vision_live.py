"""Verify the downloaded model against an owned MLX-VLM service."""
import base64
import ctypes
import json
import os
import signal
import socket
import struct
import subprocess
import time
import urllib.request
import zlib
from pathlib import Path

project = Path(__file__).resolve().parents[1]
state = Path.home() / 'Library/Application Support/ModelManager'
entry = json.loads((state / 'engines/mlx/vision.json').read_text())
server = state / 'engines/mlx' / entry['executable']
job = next(j for j in json.loads((state / 'downloads.json').read_text())
           if j['repository'] == 'mlx-community/Qwen3.8-27B-4bit' and j['state'] == '已完成')
model = Path(job['root']) / job['folder']
evidence = project / 'artifacts/mlx-vision-live-v065'
evidence.mkdir(parents=True, exist_ok=True)

def png(swapped=False):
    def chunk(name, data):
        return struct.pack('!I', len(data)) + name + data + struct.pack('!I', zlib.crc32(name + data) & 0xffffffff)
    left, right = ((0, 0, 255), (255, 0, 0)) if swapped else ((255, 0, 0), (0, 0, 255))
    scan = b''.join(b'\x00' + bytes(left) * 128 + bytes(right) * 128 for _ in range(128))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', 256, 128, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(scan)) + chunk(b'IEND', b'')

def available(port):
    with socket.socket() as s:
        try:
            s.bind(('127.0.0.1', port))
            return True
        except OSError:
            return False

port = next(p for p in range(18783, 18793) if available(p))
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
environment = dict(os.environ, HF_HUB_OFFLINE='1', PYTHONDONTWRITEBYTECODE='1', HF_HUB_DISABLE_TELEMETRY='1')
log = (evidence / 'server.log').open('w')
process = subprocess.Popen([str(server), '--model', str(model), '--host', '127.0.0.1', '--port', str(port)],
                           env=environment, stdout=log, stderr=log, start_new_session=True)
print('Loading downloaded vision model on owned test port', port, flush=True)
try:
    for _ in range(180):
        if process.poll() is not None:
            raise RuntimeError('MLX-VLM exited; see ' + str(evidence / 'server.log'))
        try:
            with opener.open('http://127.0.0.1:%s/v1/models' % port, timeout=2) as response:
                models = json.load(response)
                if response.status == 200:
                    break
        except Exception:
            pass
        time.sleep(1)
    else:
        raise RuntimeError('Vision service did not become ready')
    (evidence / 'models.json').write_text(json.dumps(models, indent=2))
    results = []
    for swapped in (False, True):
        data = png(swapped)
        (evidence / ('blue-red.png' if swapped else 'red-blue.png')).write_bytes(data)
        body = {'model': str(model), 'messages': [{'role': 'user', 'content': [
            {'type': 'text', 'text': 'Name the colors of the LEFT and RIGHT halves of this image. Answer briefly in English as left: color, right: color.'},
            {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + base64.b64encode(data).decode()}}]}],
            'max_tokens': 64, 'temperature': 0, 'stream': False, 'enable_thinking': False}
        request = urllib.request.Request('http://127.0.0.1:%s/v1/chat/completions' % port,
                                         json.dumps(body).encode(), {'Content-Type': 'application/json'})
        with opener.open(request, timeout=240) as response:
            result = json.load(response)
        content = result['choices'][0]['message']['content']
        print('Vision response:', content, flush=True)
        assert 'red' in content.lower() and 'blue' in content.lower(), content
        first, second = ('blue', 'red') if swapped else ('red', 'blue')
        assert content.lower().index(first) < content.lower().index(second), content
        results.append({'swapped': swapped, 'content': content, 'usage': result.get('usage')})
    report = {'result': 'passed', 'runtime': entry['version'], 'model': str(model),
              'port': port, 'checks': ['actual image input', 'changed image changes response', 'existing weights only'], 'responses': results}
    (evidence / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report, ensure_ascii=False), flush=True)
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=20)
    log.close()
