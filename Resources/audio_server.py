"""One local Qwen3 ASR/TTS model per managed service; never downloads at inference time."""
import argparse
import base64
import binascii
import email.parser
import email.policy
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 32 * 1024 * 1024


def fields(content_type, body):
    if content_type.startswith('multipart/form-data'):
        message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
            b'Content-Type: ' + content_type.encode('ascii') + b'\r\nMIME-Version: 1.0\r\n\r\n' + body)
        if not message.is_multipart():
            raise ValueError('Invalid multipart request')
        result = {}
        for part in message.iter_parts():
            name = part.get_param('name', header='content-disposition')
            if name in result:
                raise ValueError('Duplicate field')
            value = part.get_payload(decode=True)
            if name:
                result[name] = value if name == 'file' else value.decode('utf-8')
        return result
    value = json.loads(body)
    if not isinstance(value, dict):
        raise ValueError('Expected a JSON object')
    return value


def audio_bytes(value):
    if not isinstance(value, str) or len(value) > MAX_BODY:
        raise ValueError('Expected base64 encoded audio')
    result = base64.b64decode(value, validate=True)
    if not result:
        raise ValueError('Audio is empty')
    return result


def input_modalities(backend):
    if backend.task == 'asr':
        return ['audio']
    variant = getattr(getattr(getattr(backend, 'model', None), 'config', None), 'tts_model_type', 'base')
    return ['text', 'audio'] if variant == 'base' else ['text']


class AudioBackend:
    def __init__(self, path, task):
        self.path, self.task = path, task
        print('Loading audio model: ' + path, flush=True)
        if task == 'asr':
            from mlx_audio.stt import load
            self.model = load(path)
        else:
            from mlx_audio.tts.utils import load_model
            self.model = load_model(path)
        print('Audio model loaded', flush=True)

    def transcribe(self, value):
        audio = value.get('file') or audio_bytes(value.get('audio'))
        if not isinstance(audio, bytes):
            raise ValueError('Missing audio file')
        with tempfile.TemporaryDirectory(prefix='modeldock-asr-') as folder:
            source = Path(folder) / 'input.audio'
            source.write_bytes(audio)
            kwargs = {}
            if value.get('language') and value['language'] != 'auto':
                kwargs['language'] = str(value['language'])
            result = self.model.generate(str(source), **kwargs)
            return {'text': result.text}

    def speech(self, value):
        import numpy as np
        text = value.get('input')
        if not isinstance(text, str) or not text.strip() or len(text) > 16000:
            raise ValueError('Supply 1–16000 characters of text')
        with tempfile.TemporaryDirectory(prefix='modeldock-tts-') as folder:
            kwargs = {'text': text}
            language = str(value.get('language') or 'auto').lower()
            variant = getattr(getattr(self.model, 'config', None), 'tts_model_type', 'base')
            if value.get('reference_audio'):
                source = Path(folder) / 'reference.audio'
                source.write_bytes(audio_bytes(value['reference_audio']))
                kwargs['ref_audio'] = str(source)
                if not isinstance(value.get('reference_text'), str) or not value['reference_text'].strip():
                    raise ValueError('Reference audio requires its transcript')
                kwargs['ref_text'] = value['reference_text']
                kwargs['lang_code'] = language
                generated = self.model.generate(**kwargs)
            elif variant == 'custom_voice':
                kwargs['speaker'] = value.get('voice') or 'Vivian'
                kwargs['language'] = language
                generated = self.model.generate_custom_voice(**kwargs)
            elif variant == 'voice_design':
                if not value.get('instructions'):
                    raise ValueError('VoiceDesign requires instructions')
                kwargs['instruct'] = str(value['instructions'])
                kwargs['language'] = language
                generated = self.model.generate_voice_design(**kwargs)
            else:
                raise ValueError('This Base model needs reference_audio and reference_text')
            chunks, sample_rate = [], None
            for result in generated:
                chunks.append(np.array(result.audio))
                sample_rate = getattr(result, 'sample_rate', None) or getattr(self.model, 'sample_rate', 24000)
            if not chunks:
                raise ValueError('The model produced no audio')
            output = io.BytesIO()
            audio = np.concatenate(chunks)
            pcm = (np.clip(audio, -1, 1) * 32767).astype('<i2')
            with wave.open(output, 'wb') as wav:
                wav.setnchannels(1 if pcm.ndim == 1 else pcm.shape[1])
                wav.setsampwidth(2)
                wav.setframerate(sample_rate)
                wav.writeframes(pcm.tobytes())
            return output.getvalue()


def handler(backend):
    lock = threading.Lock()
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def send(self, status, data, content_type='application/json'):
            if not isinstance(data, bytes):
                data = json.dumps(data, ensure_ascii=False).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True
        def error(self, status, message):
            self.send(status, {'error': {'message': message, 'type': 'invalid_request_error'}})
        def do_GET(self):
            if self.path == '/v1/models':
                self.send(200, {'object': 'list', 'data': [{'id': backend.path, 'object': 'model',
                    'owned_by': 'modeldock-audio', 'input_modalities': input_modalities(backend),
                    'modalities': {'input': input_modalities(backend),
                                   'output': ['text'] if backend.task == 'asr' else ['audio']},
                    'capabilities': ['transcription'] if backend.task == 'asr' else ['speech']} ]})
            elif self.path == '/health':
                self.send(200, {'service': 'modeldock-audio', 'loaded': True, 'task': backend.task})
            else:
                self.error(404, 'Use /v1/models or the audio API')
        def do_POST(self):
            expected = '/v1/audio/transcriptions' if backend.task == 'asr' else '/v1/audio/speech'
            if self.path != expected:
                self.error(404, 'This model does not provide that operation'); return
            if self.headers.get('Transfer-Encoding'):
                self.error(411, 'Content-Length required'); return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= MAX_BODY:
                    self.error(413, 'Request must be between 1 byte and 32 MiB'); return
            except ValueError:
                self.error(400, 'Invalid Content-Length'); return
            if not lock.acquire(blocking=False):
                self.error(429, 'Model is busy'); return
            try:
                self.connection.settimeout(30)
                body = self.rfile.read(length)
                if len(body) != length:
                    raise ValueError('Incomplete request')
                value = fields(self.headers.get('Content-Type', 'application/json'), body)
                if value.get('model') not in [backend.path, Path(backend.path).name]:
                    self.error(404, 'Model not loaded'); return
                if value.get('reference_audio') and 'audio' not in input_modalities(backend):
                    raise ValueError('This model does not accept reference audio')
                if backend.task == 'asr':
                    self.send(200, backend.transcribe(value))
                else:
                    self.send(200, backend.speech(value), 'audio/wav')
            except (ValueError, KeyError, TypeError, binascii.Error) as error:
                self.error(400, str(error))
            except Exception as error:
                print('Audio inference failed: ' + str(error), flush=True)
                self.error(500, 'Audio inference failed; see service log')
            finally:
                lock.release()
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True)
    parser.add_argument('--task', choices=['asr', 'tts'], required=True)
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    if not Path(args.model).is_absolute() or not (Path(args.model) / 'config.json').is_file() or not 1024 <= args.port <= 65535:
        parser.error('An existing local model directory and unprivileged port are required')
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
    backend = AudioBackend(str(Path(args.model).resolve()), args.task)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler(backend))
    server.daemon_threads = True
    print('Ready: http://127.0.0.1:' + str(args.port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
