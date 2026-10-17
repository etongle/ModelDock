"""Execute exported shell examples against an isolated HTTP fixture, without model weights."""
import argparse
import base64
import email.parser
import email.policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import subprocess
import threading
import wave

parser = argparse.ArgumentParser()
parser.add_argument('--directory', required=True)
parser.add_argument('--port', required=True, type=int)
args = parser.parse_args()
folder = Path(args.directory)
manifest = json.loads((folder / 'manifest.json').read_text())
prefix = '/solutions/' + manifest['solutionID'].lower() + '/v1'
records = []
audio = b'RIFFfixture audio with spaces and quotes'
image = b'\x89PNG\r\n\x1a\nfixture image'
audio_file = folder / "input voice 'sample'.wav"
image_file = folder / "input picture 'sample'.png"
audio_file.write_bytes(audio); image_file.write_bytes(image)
wav_buffer = io.BytesIO()
with wave.open(wav_buffer, 'wb') as wav:
    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000); wav.writeframes(b'\0\0' * 2)
wav_bytes = wav_buffer.getvalue()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def reply(self, data, kind='application/json', status=200):
        if not isinstance(data, bytes): data = json.dumps(data).encode()
        self.send_response(status); self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def check(self):
        if self.headers.get('Authorization') != 'Bearer example-fixture-key':
            self.reply({'error': 'authentication'}, status=401); return False
        return True
    def do_GET(self):
        if not self.check(): return
        if self.path not in [prefix + '/health', prefix + '/models']:
            self.reply({}, status=404); return
        records.append({'path': self.path})
        self.reply({'ready': True} if self.path.endswith('/health') else {'data': [{'id': 'asr'}]})
    def do_POST(self):
        if not self.check(): return
        body = self.rfile.read(int(self.headers['Content-Length']))
        try:
            if self.path == prefix + '/audio/transcriptions':
                parsed = email.parser.BytesParser(policy=email.policy.default).parsebytes(
                    b'Content-Type: ' + self.headers['Content-Type'].encode() + b'\r\n\r\n' + body)
                fields = {part.get_param('name', header='content-disposition'): part.get_payload(decode=True) for part in parsed.iter_parts()}
                assert fields['model'] == b'asr' and fields['file'] == audio
                records.append({'model': 'asr'}); self.reply({'text': 'Hello'})
                return
            value = json.loads(body)
            model = value['model']
            if self.path == prefix + '/audio/speech':
                assert model == 'tts' and base64.b64decode(value['reference_audio']) == audio
                assert value['reference_text'] == 'Hello' and value['input'] == 'Bonjour'
                records.append(value); self.reply(wav_bytes, 'audio/wav')
            elif self.path == prefix + '/chat/completions':
                assert model in ['chat', 'translation', 'vision']
                if model == 'translation': assert value['messages'][0]['role'] == 'system'
                if model == 'vision':
                    uri = value['messages'][0]['content'][1]['image_url']['url']
                    assert uri.startswith('data:image/png;base64,') and base64.b64decode(uri.split(',', 1)[1]) == image
                records.append(value); self.reply({'choices': [{'message': {'content': 'Bonjour'}}]})
            else:
                raise ValueError('Wrong URL')
        except Exception:
            self.reply({'error': 'Invalid example payload'}, status=400)


server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
try:
    environment = dict(os.environ, MODELDOCK_API_KEY='example-fixture-key',
        MODELDOCK_AUDIO_FILE=str(audio_file), MODELDOCK_IMAGE_FILE=str(image_file),
        MODELDOCK_REFERENCE_TEXT='Hello', MODELDOCK_SPEECH_TEXT='Bonjour', MODELDOCK_OUTPUT_FILE=str(folder / 'speech.wav'))
    for name in ['health', 'models', 'asr', 'translation', 'tts', 'chat', 'vision', 'translation-quoted']:
        script = folder / (name + '.sh')
        subprocess.run(['/bin/sh', '-n', str(script)], check=True)
        result = subprocess.run(['/bin/sh', str(script)], env=environment, capture_output=True, timeout=15)
        assert result.returncode == 0, name + ': ' + result.stderr.decode()[-500:]
    assert (folder / 'speech.wav').read_bytes() == wav_bytes
    assert any(item.get('model') == 'translation' and manifest['untrustedLanguage'] in item['messages'][0]['content'] for item in records)
    assert not (folder / 'unexpected-execution').exists(), 'Configuration text executed as shell code'
    count = len(records)
    environment.pop('MODELDOCK_API_KEY')
    result = subprocess.run(['/bin/sh', str(folder / 'health.sh')], env=environment, capture_output=True, timeout=5)
    assert result.returncode != 0 and len(records) == count, 'Missing key reached the HTTP fixture'
    (folder / 'result.json').write_text(json.dumps({'result': 'passed', 'executedExamples': 8,
        'checks': ['exact scoped URLs', 'multipart bytes', 'reference-voice WAV', 'image data URL', 'translation instruction',
                   'filenames with spaces and quotes', 'configuration shell quoting', 'missing key fails before requests']}))
    print('SOLUTION EXAMPLE CHECKS PASSED')
finally:
    server.shutdown(); server.server_close(); thread.join()
