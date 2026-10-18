"""Exercise managed audio transport without downloading model weights or importing MLX."""
import base64
from http.server import ThreadingHTTPServer
import importlib.util
import json
import io
import tempfile
import wave
from pathlib import Path
import threading
from types import SimpleNamespace
import unittest
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location('audio_server', Path(__file__).resolve().parents[1] / 'Resources/audio_server.py')
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


class Backend:
    path = '/Models/Qwen3-ASR'
    task = 'asr'
    value = None
    def transcribe(self, value):
        self.value = value
        return {'text': 'Bonjour'}
    def speech(self, value):
        self.value = value
        return b'RIFF' + b'\0' * 4 + b'WAVE' + b'\0' * 36


class AudioServerChecks(unittest.TestCase):
    def test_real_decoder_receives_a_supported_file_extension(self):
        source = io.BytesIO()
        with wave.open(source, 'wb') as output:
            output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
            output.writeframes(b'\0\0' * 1600)
        def generate(path, **kwargs):
            self.assertEqual(Path(path).suffix, '.wav')
            with wave.open(path) as recorded: self.assertEqual(recorded.getnframes(), 1600)
            return SimpleNamespace(text='Recognized')
        backend = audio.AudioBackend.__new__(audio.AudioBackend)
        backend.model = SimpleNamespace(generate=generate)
        self.assertEqual(backend.transcribe({'file': source.getvalue()}), {'text': 'Recognized'})
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(audio.audio_file(folder, source.getvalue(), 'reference').suffix, '.wav')
            with self.assertRaisesRegex(ValueError, 'Unsupported audio format'):
                audio.audio_file(folder, b'not audio')
    def setUp(self):
        self.backend = Backend()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), audio.handler(self.backend))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
    def request(self, path, value=None, raw=None, kind='application/json'):
        body = raw if raw is not None else None if value is None else json.dumps(value).encode()
        req = urllib.request.Request('http://127.0.0.1:' + str(self.server.server_port) + path, data=body, headers={'Content-Type': kind})
        try:
            with urllib.request.urlopen(req, timeout=3) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.headers, error.read()
    def test_declares_operation_and_modalities(self):
        status, _, body = self.request('/v1/models')
        model = json.loads(body)['data'][0]
        self.assertEqual(status, 200)
        self.assertEqual(model['input_modalities'], ['audio'])
        self.assertEqual(model['modalities']['output'], ['text'])
        self.assertEqual(model['capabilities'], ['transcription'])
    def test_multipart_transcription_uses_uploaded_bytes(self):
        body = b'--test\r\nContent-Disposition: form-data; name="model"\r\n\r\n/Models/Qwen3-ASR\r\n--test\r\nContent-Disposition: form-data; name="file"; filename="voice.wav"\r\nContent-Type: audio/wav\r\n\r\nRIFFexample\r\n--test--\r\n'
        status, _, result = self.request('/v1/audio/transcriptions', raw=body, kind='multipart/form-data; boundary=test')
        self.assertEqual(status, 200); self.assertEqual(json.loads(result)['text'], 'Bonjour')
        self.assertEqual(self.backend.value['file'], b'RIFFexample')
    def test_wrong_model_and_operation_rejected(self):
        self.assertEqual(self.request('/v1/audio/transcriptions', {'model': 'another'})[0], 404)
        self.assertEqual(self.request('/v1/audio/speech', {'model': self.backend.path})[0], 404)
        self.assertIsNone(self.backend.value)
    def test_tts_binary_and_capabilities(self):
        self.backend.task = 'tts'; self.backend.path = '/Models/Qwen3-TTS-Base'
        status, headers, result = self.request('/v1/audio/speech', {'model': self.backend.path, 'input': 'Hello', 'reference_audio': base64.b64encode(b'RIFFreference').decode(), 'reference_text': 'Bonjour'})
        self.assertEqual(status, 200); self.assertEqual(headers['Content-Type'], 'audio/wav'); self.assertEqual(result[:4], b'RIFF')
        metadata = json.loads(self.request('/v1/models')[2])['data'][0]
        self.assertEqual(metadata['modalities']['output'], ['audio'])
    def test_empty_or_invalid_payload(self):
        for raw in [b'[]', b'null', b'bad']:
            self.assertEqual(self.request('/v1/audio/transcriptions', raw=raw)[0], 400)
        self.assertEqual(self.request('/v1/audio/transcriptions', raw=b'')[0], 413)
    def test_non_base_tts_does_not_claim_reference_audio(self):
        self.backend.task = 'tts'
        self.backend.model = SimpleNamespace(config=SimpleNamespace(tts_model_type='custom_voice'))
        metadata = json.loads(self.request('/v1/models')[2])['data'][0]
        self.assertEqual(metadata['input_modalities'], ['text'])
        status, _, _ = self.request('/v1/audio/speech', {'model': self.backend.path, 'input': 'Hello', 'reference_audio': base64.b64encode(b'RIFFreference').decode(), 'reference_text': 'Bonjour'})
        self.assertEqual(status, 400)
        self.assertIsNone(self.backend.value)
    def test_parser_rejects_duplicate_fields_and_malformed_audio(self):
        body = b'--x\r\nContent-Disposition: form-data; name="model"\r\n\r\na\r\n--x\r\nContent-Disposition: form-data; name="model"\r\n\r\nb\r\n--x--\r\n'
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            audio.fields('multipart/form-data; boundary=x', body)
        with self.assertRaises(ValueError): audio.audio_bytes('')
        with self.assertRaises(ValueError): audio.audio_bytes('not base64')


if __name__ == '__main__':
    unittest.main()
