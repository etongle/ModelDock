"""Replace the manager application, preserving independently running services."""
import ctypes
import hashlib
import json
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

project = Path(__file__).resolve().parents[1]
build = project / 'build/ModelDock.app'
installed = Path('/Applications/ModelDock.app') if Path('/Applications/ModelDock.app').exists() else Path('/Applications/模型管理.app')
state = Path.home() / 'Library/Application Support/ModelManager'
native = ctypes.CDLL(str(build / 'Contents/Resources/ProcessIdentity.dylib'))
native.mm_process_start_time.argtypes = [ctypes.c_int]
native.mm_process_start_time.restype = ctypes.c_uint64
native.mm_process_path.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]

def identity(pid):
    return native.mm_process_start_time(int(pid)) if pid else 0

def process_path(pid):
    buffer = ctypes.create_string_buffer(4096)
    native.mm_process_path(int(pid), buffer, len(buffer))
    return buffer.value.decode()

def request(port, path='/v1/models', key=None):
    req = urllib.request.Request('http://127.0.0.1:%s%s' % (port, path))
    if key:
        req.add_header('Authorization', 'Bearer ' + key)
    try:
        with urllib.request.urlopen(req, timeout=3) as result:
            return result.status
    except Exception as exc:
        return getattr(exc, 'code', 0)

def snapshot():
    records = json.loads((state / 'services.json').read_text())
    gateway = json.loads((state / 'gateway/process.json').read_text())
    settings = json.loads((state / 'gateway/settings.json').read_text())
    active = [{'id': x['id'], 'engine': x['engineID'], 'port': x['port'],
               'pid': x.get('pid'), 'savedBirth': x.get('processStart'),
               'actualBirth': identity(x.get('pid')), 'http': request(x['port'])}
              for x in records if x.get('pid')]
    ports = {x['port'] for x in active} | {18790, 11434, 8081}
    listeners = {}
    for port in sorted(ports):
        result = subprocess.run(['/usr/sbin/lsof', '-nP', '-iTCP:%s' % port, '-sTCP:LISTEN', '-t'], capture_output=True, text=True)
        listeners[str(port)] = [{'pid': int(x), 'birth': identity(int(x))} for x in sorted(set(result.stdout.split())) if x.isdigit()]
    gateway_port = gateway.get('port', settings.get('port', 18790))
    gateway_key = settings.get('apiKey', settings.get('key')) or gateway.get('apiKey', gateway.get('key'))
    return {'services': active, 'listeners': listeners, 'gatewayHttp': request(gateway_port, key=gateway_key),
            'gatewayPid': gateway.get('pid'), 'gatewayBirth': identity(gateway.get('pid')),
            'configurationIds': sorted(x['id'] for x in records),
            'configurations': [{k: x.get(k) for k in ['id', 'engineID', 'modelID', 'modelPath', 'port', 'context', 'pid']} for x in records]}

def download_snapshot():
    path = state / 'downloads.json'
    if not path.exists():
        return {}
    result = {}
    for job in json.loads(path.read_text()):
        files = []
        for remote in job['files']:
            destination = Path(job['root']) / job['folder'] / remote['path']
            partial = Path(str(destination) + '.incomplete')
            existing = destination if destination.is_file() else partial
            size = existing.stat().st_size if existing.is_file() else 0
            prefix = b''
            if size:
                with existing.open('rb') as stream:
                    prefix = stream.read(min(size, 8192))
            files.append({'path': str(destination), 'bytes': size,
                          'prefixBytes': len(prefix), 'prefixHash': hashlib.sha256(prefix).hexdigest()})
        result[job['id']] = {'state': job['state'],
                             'configuration': {k: job[k] for k in ['site', 'repository', 'revision', 'root', 'folder']},
                             'files': files}
    return result

expected = sys.argv[1]
extra_launch = sys.argv[2:]
if extra_launch:
    assert len(extra_launch) == 8 and extra_launch[::2] == ['--launch-local-model', '--launch-engine', '--launch-port', '--launch-mode']
    assert Path(extra_launch[1]).is_dir() and extra_launch[3] == 'mlx' and extra_launch[7] == 'multimodal'
    assert 1024 <= int(extra_launch[5]) <= 65535
    assert not any(x['port'] == int(extra_launch[5]) for x in json.loads((state / 'services.json').read_text())), 'Requested model service already configured'
version = plistlib.loads((build / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
assert version == expected, (version, expected)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(build)], check=True)
before = snapshot()
assert all(x['actualBirth'] and x['actualBirth'] == x['savedBirth'] for x in before['services']), 'Service ownership could not be verified'
assert before['gatewayHttp'] == 200 and before['gatewayBirth'], 'Gateway is not ready'
backup = Path(tempfile.mkdtemp(prefix='model-manager-update-', dir='/private/tmp')) / '模型管理.previous.app'
subprocess.run(['/usr/bin/ditto', str(installed), str(backup)], check=True)
manager = str(installed / 'Contents/MacOS/ModelManager')
downloads_before = download_snapshot()
rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True).splitlines()
for row in rows:
    parts = row.strip().split(None, 1)
    if len(parts) == 2 and parts[1] == manager and process_path(int(parts[0])) == manager:
        pid = int(parts[0])
        birth = identity(pid)
        if identity(pid) == birth:
            os.kill(pid, signal.SIGTERM)
            for _ in range(50):
                if identity(pid) != birth:
                    break
                time.sleep(.1)
            assert identity(pid) != birth, 'Manager did not terminate'
downloads_stopped = download_snapshot()
resume_ids = [job_id for job_id, job in downloads_before.items()
              if job['state'] == '下载中' and downloads_stopped.get(job_id, {}).get('state') == '下载中']
assert len(resume_ids) <= 1, 'More than one previously active download; review before automatic resume'
subprocess.run(['/usr/bin/ditto', str(build), str(installed)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
launch = ['/usr/bin/open', str(installed)]
if resume_ids or extra_launch:
    launch += ['--args']
    if resume_ids:
        launch += ['--resume-download-job', resume_ids[0]]
    launch += extra_launch
subprocess.run(launch, check=True)
time.sleep(5)
after = snapshot()
after_services = {x['id']: x for x in after['services']}
for prior in before['services']:
    current = after_services.get(prior['id'])
    assert current and {k: v for k, v in prior.items() if k != 'http'} == {k: v for k, v in current.items() if k != 'http'}, 'Existing model process changed'
    if prior['http'] == 200:
        assert current['http'] == 200, 'Previously ready service became unavailable'
after_configurations = {x['id']: x for x in after['configurations']}
assert all(after_configurations.get(x['id']) == x for x in before['configurations']), 'Existing model configuration changed'
assert before['gatewayPid'] == after['gatewayPid'] and before['gatewayBirth'] == after['gatewayBirth'] and after['gatewayHttp'] == 200, 'Gateway changed'
assert all(after['listeners'].get(port) == rows for port, rows in before['listeners'].items() if rows), 'Existing listener process changed'
if not extra_launch:
    assert before['configurationIds'] == after['configurationIds'], 'Model configurations changed unexpectedly'
else:
    port = int(extra_launch[5])
    for _ in range(90):
        if request(port) == 200:
            break
        time.sleep(1)
    else:
        raise AssertionError('Multimodal model service did not become ready')
    after = snapshot()
    assert any(x['port'] == port and x['engine'] == 'mlx' and x['actualBirth'] == x['savedBirth'] and x['http'] == 200 for x in after['services']), 'New multimodal service ownership missing'
downloads_after = download_snapshot()
preserved = []
for job_id, prior in downloads_stopped.items():
    current = downloads_after.get(job_id)
    assert current and prior['configuration'] == current['configuration'], 'Download task or destination changed'
    for old_file in prior['files']:
        destination = Path(old_file['path'])
        existing = destination if destination.is_file() else Path(str(destination) + '.incomplete')
        assert existing.is_file() or old_file['bytes'] == 0, 'Downloaded data removed'
        if old_file['bytes']:
            assert existing.stat().st_size >= old_file['bytes'], 'Downloaded data truncated'
            with existing.open('rb') as stream:
                prefix = stream.read(old_file['prefixBytes'])
            assert hashlib.sha256(prefix).hexdigest() == old_file['prefixHash'], 'Downloaded prefix changed'
    preserved.append({'id': job_id, 'repository': current['configuration']['repository'],
                      'state': current['state'], 'actualBytes': sum(x['bytes'] for x in current['files']),
                      'requestedResume': job_id in resume_ids})
report = {'result': 'passed', 'version': expected, 'backup': str(backup), 'before': before, 'after': after,
          'downloadTasks': preserved}
target = project / ('artifacts/installation-v%s.json' % expected.replace('.', ''))
target.parent.mkdir(exist_ok=True)
target.write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps({'result': 'passed', 'version': expected, 'backup': str(backup), 'servicesPreserved': len(after['services']), 'gatewayHttp': after['gatewayHttp'], 'downloadTasks': preserved, 'evidence': str(target)}, ensure_ascii=False))
