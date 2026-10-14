from pathlib import Path
import base64
import json
import struct
import sys
import time
import urllib.error
import urllib.request
import zlib

root = Path(sys.argv[1]).resolve()
ready = json.loads((root / 'ready.json').read_text())
exports = json.loads((root / 'live-exports.json').read_text())
entry = next(item for item in exports if item['client'] == 'pi')
profile = json.loads(Path(entry['configuration']).read_text())
key = next(iter(profile['providers'].values()))['apiKey']
endpoint = ready['endpoint']

def request(path, payload=None):
    data = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None
    return urllib.request.Request(endpoint + path, data=data,
        headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})

with urllib.request.urlopen(request('/models'), timeout=15) as response:
    models = json.loads(response.read())['data']
assert len({model['id'] for model in models}) == len(models)

started = time.monotonic()
payload = {'model': ready['alias'], 'messages': [{'role': 'user', 'content': 'Reply with exactly OK.'}],
    'max_tokens': 256, 'temperature': 0, 'stream': True, 'chat_template_kwargs': {'enable_thinking': False}}
reply = ''
events = 0
finished = False
first = None
with urllib.request.urlopen(request('/chat/completions', payload), timeout=120) as response:
    assert response.headers['Content-Type'].startswith('text/event-stream')
    for raw in response:
        if not raw.startswith(b'data: '):
            continue
        value = raw[6:].strip()
        if value == b'[DONE]':
            finished = True
            break
        if first is None:
            first = time.monotonic() - started
        event = json.loads(value)
        events += 1
        for choice in event.get('choices', []):
            reply += choice.get('delta', {}).get('content') or ''
if not (finished and reply.strip() == 'OK'):
    (root / 'stream-diagnostic.json').write_text(json.dumps({'finished': finished, 'reply': reply, 'events': events}, ensure_ascii=False))
assert finished and reply.strip() == 'OK', 'Real gateway stream did not complete with OK'

def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

png = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 8, 8, 2, 0, 0, 0))
png += png_chunk(b'IDAT', zlib.compress((b'\0' + b'\xff\0\0' * 8) * 8)) + png_chunk(b'IEND', b'')
image = 'data:image/png;base64,' + base64.b64encode(png).decode()
media_payload = {'model': ready['alias'], 'messages': [{'role': 'user', 'content': [
    {'type': 'text', 'text': '请只回答图片的主要颜色，一个词。'},
    {'type': 'image_url', 'image_url': {'url': image}}]}], 'max_tokens': 64,
    'temperature': 0, 'chat_template_kwargs': {'enable_thinking': False}}
try:
    urllib.request.urlopen(request('/chat/completions', media_payload), timeout=20)
    raise AssertionError('Text-only Splash route accepted an image')
except urllib.error.HTTPError as error:
    assert error.code == 400 and json.loads(error.read())['error']['code'] == 'unsupported_modality'

vision = next((model for model in models if model['id'].startswith('llama-9931-') and 'image' in model['input_modalities']), None)
vision_result = {'tested': False, 'reason': 'No running image-capable Llama service'}
if vision:
    media_payload['model'] = vision['id']
    with urllib.request.urlopen(request('/chat/completions', media_payload), timeout=150) as response:
        result = json.loads(response.read())
    text = result['choices'][0]['message'].get('content') or ''
    assert '红' in text or 'red' in text.lower(), 'Real model did not recognize the red image'
    vision_result = {'tested': True, 'model': vision['id'], 'http': 200, 'reply': text,
        'usage': result.get('usage'), 'newModelLoaded': False}

report = {'result': 'passed', 'streamEvents': events, 'done': finished, 'reply': reply,
    'firstEventSeconds': round(first, 3), 'models': len(models), 'textMediaRejected': True,
    'vision': vision_result, 'existingModelsUsed': True}
(root / 'stream-result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False))
