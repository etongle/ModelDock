#!/usr/bin/env python3
import argparse
import json
import pathlib
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--config', required=True)
parser.add_argument('--url', required=True)
parser.add_argument('--media-alias', required=True)
parser.add_argument('--text-alias', required=True)
parser.add_argument('--remote-alias', required=True)
parser.add_argument('--request-root', required=True)
args = parser.parse_args()
config = json.loads(pathlib.Path(args.config).read_text())
key = config['apiKey']

def call(path, value=None, token=key, content_type='application/json'):
    body = value if isinstance(value, bytes) else json.dumps(value).encode() if value is not None else None
    request = urllib.request.Request(args.url + path, data=body,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': content_type})
    try:
        return urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error:
        return error

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

with call('/models', token='invalid') as response:
    require(response.status == 401, 'Gateway accepted wrong authentication')
with call('/models') as response:
    data = json.load(response)['data']
    ids = [entry['id'] for entry in data]
    require(len(ids) == len(set(ids)) and all(alias in ids for alias in [args.media_alias, args.text_alias, args.remote_alias]), 'Aliases missing or duplicated')
    require(key not in json.dumps(data) and 'upstream-fixture-secret' not in json.dumps(data), 'Models endpoint leaked credentials')

tools = [{'type': 'function', 'function': {'name': 'read_image', 'parameters': {'type': 'object',
          'properties': {'images': {'type': 'array', 'items': {'type': 'string'}}, 'image_url': {'type': 'string'}}}}}]
with call('/chat/completions', {'model': args.text_alias, 'messages': [{'role': 'user', 'content': 'Hi'}], 'tools': tools}) as response:
    require(response.status == 200, 'Tool schema was mistaken for media input')
image = {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,fixture-image'}}
with call('/chat/completions', {'model': args.text_alias, 'messages': [{'role': 'user', 'content': [image]}]}) as response:
    require(response.status == 400 and json.load(response)['error']['code'] == 'unsupported_modality', 'Text model accepted image')
parts = [{'type': 'text', 'text': 'inspect'}, image,
    {'type': 'input_audio', 'input_audio': {'data': 'fixture-audio', 'format': 'wav'}},
    {'type': 'file', 'file': {'file_data': 'fixture-file', 'filename': 'test.pdf'}}]
with call('/chat/completions', {'model': args.media_alias, 'messages': [{'role': 'user', 'content': parts}], 'tools': tools}) as response:
    require(response.status == 200, 'Supported media was not proxied')
with call('/chat/completions', {'model': args.remote_alias, 'messages': [{'role': 'user', 'content': 'Hi'}]}) as response:
    require(response.status == 200, 'Upstream-specific credentials were not sent')
with call('/chat/completions', {'model': args.text_alias, 'messages': [], 'test_error': True}) as response:
    require(response.status == 418 and json.load(response)['error']['message'] == 'fixture-error', 'Upstream error/status was changed')
with call('/chat/completions', b'{bad-json') as response:
    require(response.status == 400, 'Invalid JSON accepted')
with call('/chat/completions', {'model': 'missing', 'messages': []}) as response:
    require(response.status == 404, 'Unknown alias routed to an arbitrary model')
boundary = 'gateway_fixture'
multipart = ('--' + boundary + '\r\nContent-Disposition: form-data; name="model"\r\n\r\n' + args.media_alias +
    '\r\n--' + boundary + '\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\nfixture-audio\r\n--' + boundary + '--\r\n').encode()
with call('/audio/transcriptions', multipart, content_type='multipart/form-data; boundary=' + boundary) as response:
    require(response.status == 200, 'Multipart media route failed')
began = time.monotonic()
with call('/chat/completions', {'model': args.media_alias, 'messages': [{'role': 'user', 'content': 'Hi'}], 'stream': True, 'tools': tools}) as response:
    require(response.status == 200 and 'text/event-stream' in response.headers['Content-Type'], 'Streaming type changed')
    first = response.read1(4096)
    first_ms = (time.monotonic() - began) * 1000
    rest = response.read()
    total_ms = (time.monotonic() - began) * 1000
    raw = (first + rest).decode()
    events = [json.loads(line[6:]) for line in raw.splitlines() if line.startswith('data: ') and line != 'data: [DONE]']
    require(total_ms - first_ms > 700 and '"content": "A"' in first.decode(), 'Stream was buffered until completion')
    calls = [event['choices'][0]['delta'].get('tool_calls', []) for event in events]
    fragments = ''.join(part['function'].get('arguments', '') for group in calls for part in group)
    require(json.loads(fragments) == {'ok': True} and 'data: [DONE]' in raw, 'Tool-call fragments or terminal event were damaged')
records = []
for file in pathlib.Path(args.request_root).glob('**/requests-*.jsonl'):
    records.extend(json.loads(line) for line in file.read_text().splitlines())
require(any(record['body'].get('messages', [{}])[0].get('content') == parts for record in records if record['body'].get('messages')), 'Media payload changed')
require(all(record['body'].get('model', 'fixture-model') == 'fixture-model' for record in records), 'Gateway alias reached backend')
require(any(record['authorization'] == 'Bearer upstream-fixture-secret' for record in records), 'Upstream credentials missing')
require(all(record['authorization'] != 'Bearer ' + key for record in records), 'Gateway secret leaked to backend')
require(any('name="model"\r\n\r\nfixture-model\r\n' in record['body'].get('multipart', '') for record in records), 'Multipart model not mapped')
result = {'result': 'passed', 'stream_first_ms': round(first_ms, 2), 'stream_total_ms': round(total_ms, 2),
    'checks': ['Model aliases are unique', 'Gateway authentication enforced', 'Model listing hides credentials',
    'Tool schemas stay valid in text mode', 'Text-only blocks media before inference', 'Image/audio/file payloads preserved',
    'Multipart model routing', 'Gateway key is not forwarded', 'Configured upstream key used',
    'Backend status/error preserved', 'Invalid JSON and unknown aliases rejected', 'SSE is incremental', 'Tool fragments and DONE preserved']}
pathlib.Path(args.request_root, 'http-result.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
