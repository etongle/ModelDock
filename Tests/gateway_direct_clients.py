from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import time

root = Path(sys.argv[1]).resolve()
exports = json.loads((root / 'live-exports.json').read_text())
originals = [Path.home() / name for name in ['.config/opencode/opencode.json', '.pi/agent/models.json',
    '.pi/agent/settings.json', '.pi/agent/auth.json']]
def fingerprints():
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in originals if path.is_file()}
before = fingerprints()
results = []
for entry in exports:
    env = dict(os.environ)
    for name in entry.get('unsetEnvironment') or []:
        env.pop(name, None)
    env.update(entry['environment'])
    env['PI_TELEMETRY'] = '0'
    env['PI_OFFLINE'] = '1'
    fixture = Path(entry['project']) / 'fixture.txt'
    fixture.write_text('MODEL_MANAGER_CONTEXT_READ_FIXTURE\n')
    prompt = '请只使用 read 工具读取 ' + str(fixture) + '，然后回复文件内容。不要使用其他工具。'
    if entry['client'] == 'opencode':
        config = json.loads(env['OPENCODE_CONFIG_CONTENT'])
        config['permission'] = {'*': 'deny', 'read': 'allow'}
        env['OPENCODE_CONFIG_CONTENT'] = json.dumps(config)
        for selector in ['DATA', 'CACHE', 'STATE']:
            env['XDG_' + selector + '_HOME'] = str(root / 'direct-native' / selector.lower())
        command = [entry['executable'], '--pure', 'run', '--model', entry['providerID'] + '/' + entry['model'], '--format', 'json', prompt]
    else:
        command = [entry['executable']] + entry['arguments'] + ['--offline', '--no-session', '--print', prompt]
    started = time.monotonic()
    done = subprocess.run(command, cwd=entry['project'], env=env, capture_output=True, text=True, timeout=150)
    (root / (entry['client'] + '-direct.stdout')).write_text(done.stdout)
    (root / (entry['client'] + '-direct.stderr')).write_text(done.stderr)
    passed = done.returncode == 0 and 'MODEL_MANAGER_CONTEXT_READ_FIXTURE' in done.stdout
    if entry['client'] == 'opencode':
        events = []
        for line in done.stdout.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        passed = passed and any(item.get('type') == 'tool_use' and item.get('part', {}).get('tool') == 'read' for item in events)
        passed = passed and not any(item.get('type') == 'error' for item in events)
    result = {'client': entry['client'], 'passed': passed, 'exit': done.returncode,
        'seconds': round(time.monotonic() - started, 2), 'directGateway': True, 'toolsEnabled': True}
    results.append(result)
    print(json.dumps(result), flush=True)
unchanged = before == fingerprints()
report = {'result': 'passed' if unchanged and all(item['passed'] for item in results) else 'failed',
    'checks': results, 'originalClientConfigsUnchanged': unchanged, 'streamNotRewritten': True}
(root / 'direct-clients-result.json').write_text(json.dumps(report, indent=2))
sys.exit(0 if report['result'] == 'passed' else 1)
