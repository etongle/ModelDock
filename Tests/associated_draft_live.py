"""Prove the app launches a pinned main + DFlash2 + vision bundle."""
import base64, ctypes, json, os, signal, socket, subprocess, time, urllib.request, uuid
from pathlib import Path

project = Path(__file__).resolve().parents[1]
app = project / 'build/模型管理.app'
evidence = project / 'artifacts/associated-draft-live-v066'
state = evidence / ('state-' + str(uuid.uuid4()))
state.mkdir(parents=True, exist_ok=True)
global_state = Path.home() / 'Library/Application Support/ModelManager'
job = next(j for j in json.loads((global_state / 'downloads.json').read_text()) if j['repository'] == 'mlx-community/Qwen3.8-27B-4bit' and j['state'] == '已完成')
model = Path(job['root']) / job['folder']
draft = model.parents[2] / 'models--incoai--Qwen3.8-27B-DFlash2/snapshots/015e795645c74b1a0eeef3b570031fb62e769bc5'
assert (draft / 'model.safetensors').is_file()
assert not (state / 'services.json').exists(), 'Use a fresh isolated test state'
(state / 'model-associations.json').write_text(json.dumps({'mlx:' + str(model): {'draftMode': 'local', 'draftPath': str(draft)}}))
def available(port):
    with socket.socket() as sock:
        try: sock.bind(('127.0.0.1', port)); return True
        except OSError: return False
port = next(p for p in range(18841, 18851) if available(p))
native = ctypes.CDLL(str(app / 'Contents/Resources/ProcessIdentity.dylib'))
native.mm_process_start_time.argtypes = [ctypes.c_int]; native.mm_process_start_time.restype = ctypes.c_uint64
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
log = (evidence / 'app.log').open('w')
process = subprocess.Popen([str(app / 'Contents/MacOS/ModelManager'), '--state-dir', str(state), '--launch-associated-test', str(model),  '--launch-port', str(port), '--launch-mode', 'multimodal'], stdout=log, stderr=log)
spec = None
try:
    for _ in range(180):
        if process.poll() is not None: raise RuntimeError('App exited')
        if (state / 'services.json').exists():
            records = json.loads((state / 'services.json').read_text())
            if records:
                spec = records[0]
                assert spec['draftModelPath'] == str(draft) and '--draft-kind' in spec['launchArguments'], spec
                try:
                    with opener.open(f'http://127.0.0.1:{port}/v1/models', timeout=2) as r:
                        models = json.load(r)
                    if r.status == 200: break
                except Exception: pass
        time.sleep(1)
    else: raise RuntimeError('Associated service failed to start; see logs')
    responses = []
    for swapped in (False, True):
        image = project / 'artifacts/mlx-vision-live-v065' / ('blue-red.png' if swapped else 'red-blue.png')
        body = {'model': str(model), 'messages': [{'role': 'user', 'content': [
            {'type': 'text', 'text': 'Name the colors of the LEFT and RIGHT halves of this image. Answer briefly in English as left: color, right: color.'},
            {'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,' + base64.b64encode(image.read_bytes()).decode()}}]}], 'max_tokens': 64, 'temperature': 0, 'stream': False, 'enable_thinking': False}
        request = urllib.request.Request(f'http://127.0.0.1:{port}/v1/chat/completions', json.dumps(body).encode(), {'Content-Type': 'application/json'})
        with opener.open(request, timeout=240) as r: result = json.load(r)
        content = result['choices'][0]['message']['content']; first, second = ('blue', 'red') if swapped else ('red', 'blue')
        assert first in content.lower() and second in content.lower() and content.lower().index(first) < content.lower().index(second), content
        responses.append({'swapped': swapped, 'content': content, 'usage': result.get('usage')})
        print('Associated draft image response:', content, flush=True)
    runtime_log = (state / 'logs' / (spec['id'] + '.log')).read_text()
    assert 'dflash' in runtime_log.lower(), 'Drafter was not loaded'
    report = {'result': 'passed', 'model': str(model), 'draft': str(draft), 'port': port, 'pid': spec['pid'], 'launchArguments': spec['launchArguments'], 'responses': responses, 'checks': ['app generated associated launch', 'actual DFlash2 load', 'vision response changes with image', 'existing files only']}
    (evidence / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({'result': 'passed', 'evidence': str(evidence / 'result.json')}, ensure_ascii=False), flush=True)
finally:
    if spec and native.mm_process_start_time(spec['pid']) == spec.get('processStart'):
        os.killpg(spec['pid'], signal.SIGTERM)
        for _ in range(80):
            if native.mm_process_start_time(spec['pid']) != spec.get('processStart'): break
            time.sleep(.25)
    if process.poll() is None: process.terminate(); process.wait(timeout=20)
    log.close()
