"""Verify ASR multipart and reference-voice WAV transport through the real gateway."""
import base64
import ctypes
from http.server import ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audio_server', ROOT / 'Resources/audio_server.py')
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


class Backend:
    def __init__(self, task):
        self.task, self.path, self.value = task, '/Models/' + task, None
    def transcribe(self, value):
        self.value = value
        return {'text': 'Bonjour'}
    def speech(self, value):
        self.value = value
        return b'RIFF' + b'\0' * 4 + b'WAVE' + b'\0' * 36


class AudioGatewayChecks(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='modeldock-audio-gateway-')
        self.addCleanup(self.folder.cleanup)
        self.backends = [Backend('asr'), Backend('tts')]
        self.servers = []
        routes = []
        lib = ROOT / 'build/ModelDock.app/Contents/Resources/ProcessIdentity.dylib'
        identity = ctypes.CDLL(str(lib))
        identity.mm_process_start_time.argtypes = [ctypes.c_int]
        identity.mm_process_start_time.restype = ctypes.c_uint64
        for backend in self.backends:
            server = ThreadingHTTPServer(('127.0.0.1', 0), audio.handler(backend))
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.servers.append(server)
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)
            routes.append({'alias': backend.task, 'name': backend.task, 'model': backend.path,
                           'endpoint': 'http://127.0.0.1:' + str(server.server_port) + '/v1',
                           'inputs': audio.input_modalities(backend),
                           'outputs': ['text'] if backend.task == 'asr' else ['audio'],
                           'pid': os.getpid(), 'birth': identity.mm_process_start_time(os.getpid()),
                           'available': True})
        self.config = Path(self.folder.name) / 'gateway.json'
        self.settings = {'schema': 1, 'instance': 'audio-fixture', 'apiKey': 'fixture-local-key', 'routes': routes}
        self.config.write_text(json.dumps(self.settings))
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0)); self.port = probe.getsockname()[1]
        self.process = subprocess.Popen([sys.executable, '-B', str(ROOT / 'Resources/gateway.py'),
            '--config', str(self.config), '--identity-lib', str(lib), '--port', str(self.port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.stop_gateway)
        for _ in range(100):
            try:
                if self.call('/health')[0] == 200: break
            except OSError:
                time.sleep(0.02)
        else:
            self.fail('Gateway did not start')
    def stop_gateway(self):
        if self.process.poll() is None:
            self.process.terminate(); self.process.wait(timeout=5)
    def call(self, path, value=None, kind='application/json'):
        body = value if isinstance(value, bytes) else None if value is None else json.dumps(value).encode()
        req = urllib.request.Request('http://127.0.0.1:' + str(self.port) + path,
            data=body, headers={'Authorization': 'Bearer fixture-local-key', 'Content-Type': kind})
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.headers, error.read()
    def test_asr_and_reference_voice_round_trip(self):
        body = b'--x\r\nContent-Disposition: form-data; name="model"\r\n\r\nasr\r\n--x\r\nContent-Disposition: form-data; name="file"; filename="voice.wav"\r\nContent-Type: audio/wav\r\n\r\nRIFFsample\r\n--x--\r\n'
        status, _, response = self.call('/v1/audio/transcriptions', body, 'multipart/form-data; boundary=x')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(response)['text'], 'Bonjour')
        self.assertEqual(self.backends[0].value['model'], '/Models/asr')
        self.assertEqual(self.backends[0].value['file'], b'RIFFsample')
        reference = base64.b64encode(b'RIFFsample').decode()
        status, headers, response = self.call('/v1/audio/speech', {'model': 'tts', 'input': 'Hello',
            'reference_audio': reference, 'reference_text': 'Bonjour'})
        self.assertEqual(status, 200)
        self.assertEqual(headers['Content-Type'], 'audio/wav')
        self.assertEqual(response[:4], b'RIFF')
        self.assertEqual(self.backends[1].value['model'], '/Models/tts')
        self.assertEqual(self.backends[1].value['reference_audio'], reference)
    def test_declared_input_and_output_capabilities_are_enforced(self):
        self.assertEqual(self.call('/v1/audio/speech', {'model': 'asr', 'input': 'Hello'})[0], 400)
        self.assertIsNone(self.backends[0].value)
        self.settings['routes'][1]['inputs'] = ['text']
        self.config.write_text(json.dumps(self.settings))
        status, _, result = self.call('/v1/audio/speech', {'model': 'tts', 'input': 'Hello',
            'reference_audio': base64.b64encode(b'RIFFsample').decode(), 'reference_text': 'Bonjour'})
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(result)['error']['code'], 'unsupported_modality')
        self.assertIsNone(self.backends[1].value)


if __name__ == '__main__':
    unittest.main()
