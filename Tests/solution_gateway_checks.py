"""Solution URL contract checks against the real gateway and isolated local fixtures."""
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time
import unittest

from audio_gateway_checks import AudioGatewayChecks, Backend, audio


class SolutionGatewayChecks(AudioGatewayChecks):
    solution_id = 'fba3cb54-89b0-410d-a606-17a9cdf949c4'
    other_id = '5a994f3f-9265-4356-8e31-79b9825bf45c'

    def setUp(self):
        super().setUp()
        self.chat_requests = []
        requests = self.chat_requests
        class Chat(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def reply(self, value, kind='application/json'):
                data = value if isinstance(value, bytes) else json.dumps(value).encode()
                self.send_response(200); self.send_header('Content-Type', kind)
                self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            def do_GET(self): self.reply({'data': [{'id': '/Models/chat'}]})
            def do_POST(self):
                value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(value)
                if value.get('stream'):
                    self.reply(b'data: {"choices":[{"delta":{"content":"Bonjour"}}]}\n\ndata: [DONE]\n\n', 'text/event-stream')
                else:
                    self.reply({'choices': [{'message': {'content': 'Bonjour'}}]})
        server = ThreadingHTTPServer(('127.0.0.1', 0), Chat)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        routes = self.settings['routes']
        routes[0]['id'] = 'route-asr'; routes[1]['id'] = 'route-tts'
        route = dict(routes[0], id='route-chat', alias='global-chat', name='chat', model='/Models/chat',
                     endpoint='http://127.0.0.1:' + str(server.server_port) + '/v1', inputs=['text'], outputs=['text'])
        routes.append(route)
        self.settings['solutions'] = [
            {'id': self.solution_id, 'recipe': 'voice-translation', 'configured': True,
             'components': [{'role': 'asr', 'routeID': 'route-asr'}, {'role': 'translation', 'routeID': 'route-chat'}, {'role': 'tts', 'routeID': 'route-tts'}]},
            {'id': self.other_id, 'recipe': 'transcription', 'configured': True,
             'components': [{'role': 'asr', 'routeID': 'route-asr'}]}
        ]
        self.save_config()

    def save_config(self):
        temporary = self.config.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.settings)); temporary.replace(self.config)

    @property
    def base(self): return '/solutions/' + self.solution_id + '/v1'

    def test_scoped_models_and_health_only_describe_this_solution(self):
        status, _, body = self.call(self.base + '/models')
        self.assertEqual(status, 200)
        models = json.loads(body)['data']
        self.assertEqual([m['id'] for m in models], ['asr', 'translation', 'tts'])
        self.assertEqual(models[0]['input_modalities'], ['audio'])
        self.assertNotIn('fixture-local-key', body.decode())
        health = json.loads(self.call(self.base + '/health')[2])
        self.assertTrue(health['ready'])
        self.assertEqual(health['id'], self.solution_id)
        other = '/solutions/' + self.other_id + '/v1'
        self.assertEqual([m['id'] for m in json.loads(self.call(other + '/models')[2])['data']], ['asr'])
        self.assertEqual(self.call(other + '/chat/completions', {'model': 'global-chat', 'messages': []})[0], 404)
        self.assertEqual(self.chat_requests, [])

    def test_component_models_route_to_exact_backends(self):
        data = {'model': 'translation', 'messages': [{'role': 'user', 'content': 'Hello'}],
                'tools': [{'type': 'function', 'function': {'name': 'read'}}]}
        self.assertEqual(self.call(self.base + '/chat/completions', data)[0], 200)
        self.assertEqual(self.chat_requests[-1]['model'], '/Models/chat')
        self.assertEqual(self.chat_requests[-1]['tools'], data['tools'])
        self.assertEqual(self.call(self.base + '/chat/completions', {'messages': []})[0], 200)
        body = b'--x\r\nContent-Disposition: form-data; name="model"\r\n\r\nasr\r\n--x\r\nContent-Disposition: form-data; name="file"; filename="sample.wav"\r\n\r\nRIFFsample\r\n--x--\r\n'
        self.assertEqual(self.call(self.base + '/audio/transcriptions', body, 'multipart/form-data; boundary=x')[0], 200)
        self.assertEqual(self.backends[0].value['model'], '/Models/asr')
        self.assertEqual(self.backends[0].value['file'], b'RIFFsample')
        status, headers, body = self.call(self.base + '/audio/speech', {'model': 'tts', 'input': 'Hello',
            'reference_audio': base64.b64encode(b'RIFFsample').decode(), 'reference_text': 'Bonjour'})
        self.assertEqual(status, 200); self.assertEqual(headers['Content-Type'], 'audio/wav'); self.assertEqual(body[:4], b'RIFF')

    def test_scoped_stream_and_invalid_operations(self):
        status, headers, body = self.call(self.base + '/chat/completions', {'model': 'translation', 'messages': [], 'stream': True})
        self.assertEqual(status, 200); self.assertIn('text/event-stream', headers['Content-Type']); self.assertIn(b'data: [DONE]', body)
        self.assertEqual(self.call(self.base + '/chat/completions', {'model': 'asr', 'messages': []})[0], 400)
        self.assertIsNone(self.backends[0].value)
        self.assertEqual(self.call(self.base + '/models?other=1')[0], 404)
        self.assertEqual(self.call(self.base + '/chat/completions', {'model': None})[0], 400)

    def test_missing_disabled_or_stale_bindings_never_fall_back(self):
        self.settings['solutions'][0]['components'][1]['routeID'] = 'removed-route'
        self.save_config()
        status, _, body = self.call(self.base + '/chat/completions', {'model': 'translation', 'messages': []})
        self.assertEqual(status, 503); self.assertEqual(json.loads(body)['error']['code'], 'solution_component_unavailable')
        self.assertEqual(self.chat_requests, [])
        self.settings['solutions'][0]['components'][1]['routeID'] = 'route-chat'
        self.settings['routes'][2]['enabled'] = False; self.save_config()
        self.assertEqual(self.call(self.base + '/chat/completions', {'model': 'translation', 'messages': []})[0], 503)
        self.settings['routes'][2]['enabled'] = True; self.settings['routes'][2]['birth'] += 1; self.save_config()
        self.assertEqual(self.call(self.base + '/chat/completions', {'model': 'translation', 'messages': []})[0], 503)
        self.assertFalse(json.loads(self.call(self.base + '/health')[2])['ready'])
        self.assertEqual(self.chat_requests, [])

    def test_same_url_tracks_bound_port_and_removed_solution_returns_404(self):
        replacement = Backend('asr')
        server = ThreadingHTTPServer(('127.0.0.1', 0), audio.handler(replacement))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close); self.addCleanup(server.shutdown)
        self.settings['routes'][0]['endpoint'] = 'http://127.0.0.1:' + str(server.server_port) + '/v1'
        self.save_config()
        status, _, _ = self.call(self.base + '/audio/transcriptions', {'model': 'asr', 'audio': base64.b64encode(b'RIFFsample').decode()})
        self.assertEqual(status, 200); self.assertIsNone(self.backends[0].value); self.assertIsNotNone(replacement.value)
        self.settings['solutions'] = [self.settings['solutions'][1]]; self.save_config()
        self.assertEqual(self.call(self.base + '/models')[0], 404)
        self.assertEqual(self.call(self.base + '/audio/transcriptions', {'model': 'asr'})[0], 404)

    def test_scoped_sleeping_service_wakes_its_bound_route(self):
        route = self.settings['routes'][2]
        route['sleeping'] = True
        route['sourceID'] = 'chat-service'
        self.save_config()
        errors = []
        def resume():
            try:
                wake_file = self.config.parent / 'wake' / 'chat-service'
                deadline = time.monotonic() + 5
                while not wake_file.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(wake_file.exists())
                route['sleeping'] = False
                self.save_config()
            except Exception as error:
                errors.append(error)
        worker = threading.Thread(target=resume)
        worker.start()
        self.assertEqual(self.call(self.base + '/chat/completions', {'model': 'translation', 'messages': []})[0], 200)
        worker.join(6)
        self.assertEqual(errors, [])
        self.assertEqual(self.chat_requests[-1]['model'], '/Models/chat')

    def test_scoped_wake_rejects_changed_binding(self):
        route = self.settings['routes'][2]
        route.update(sleeping=True, sourceID='chat-service')
        self.save_config()
        errors = []
        def replace():
            try:
                wake_file = self.config.parent / 'wake' / 'chat-service'
                deadline = time.monotonic() + 5
                while not wake_file.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(wake_file.exists())
                route['sleeping'] = False
                self.settings['solutions'][0]['components'][1]['routeID'] = 'removed-route'
                self.save_config()
            except Exception as error:
                errors.append(error)
        worker = threading.Thread(target=replace)
        worker.start()
        self.assertEqual(self.call(self.base + '/chat/completions', {'model': 'translation', 'messages': []})[0], 503)
        worker.join(6)
        self.assertEqual(errors, [])
        self.assertEqual(self.chat_requests, [])

    def test_scoped_usage_records_backend_alias_without_payload(self):
        self.assertEqual(self.call(self.base + '/chat/completions', {'model': 'translation', 'messages': [{'role': 'user', 'content': 'private fixture prompt'}]})[0], 200)
        log = self.config.parent / 'requests.jsonl'
        deadline = time.monotonic() + 3
        while (not log.exists() or not log.read_text().strip()) and time.monotonic() < deadline:
            time.sleep(.02)
        text = log.read_text()
        entry = json.loads(text.splitlines()[-1])
        self.assertEqual(entry['model'], 'global-chat')
        self.assertEqual(entry['path'], self.base + '/chat/completions')
        self.assertNotIn('private fixture prompt', text)
        self.assertNotIn('Bonjour', text)


if __name__ == '__main__':
    unittest.main()
