"""Repair only the specified ModelManager Pi profile, with exact backups."""
import fcntl
import json
import os
import tempfile
import urllib.request
from pathlib import Path
import sys

profile = Path(sys.argv[1]).resolve()
root = Path.home() / 'Library/Application Support/ModelManager/connections'
assert profile.parent == (root / 'profiles/pi').resolve(), 'Expected a managed Pi profile'
models_path, settings_path = profile / 'models.json', profile / 'settings.json'
assert not models_path.is_symlink() and not settings_path.is_symlink()
with (profile / '.model-manager-config.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    originals = {p: p.read_bytes() for p in [models_path, settings_path]}
    models, settings = json.loads(originals[models_path]), json.loads(originals[settings_path])
    records = json.loads((root.parent / 'services.json').read_text())
    changes = []
    for provider_id, provider in models['providers'].items():
        assert provider_id == 'model-manager-8001', 'Expected the affected local service'
        assert provider['baseUrl'] == 'http://127.0.0.1:8001/v1'
        for entry in provider['models']:
            record = next(r for r in records if r.get('pid') and r['port'] == 8001 and r['modelName'] == entry['id'])
            assert record['engineID'] == 'splash' and record['engineVersion'] == '1.3.1'
            with urllib.request.urlopen(provider['baseUrl'] + '/models', timeout=5) as response:
                assert entry['id'] in [m['id'] for m in json.load(response)['data']]
            context = entry['contextWindow']; assert context == record['context'] == 32768
            output, reserve = min(8192, context // 4), min(context // 2, min(8192, context // 4) + 4096)
            entry['maxTokens'] = output
            entry.setdefault('samplingParams', {})['chat_template_kwargs'] = {'enable_thinking': False}
            key = provider_id + '/' + entry['id']
            override = settings.setdefault('compaction', {}).setdefault('modelOverrides', {}).setdefault(key, {})
            override.update(reserveTokens=reserve, keepRecentTokens=min(2048, context // 4))
            changes.append({'provider': provider_id, 'model': entry['id'], 'maxTokens': output, 'reserveTokens': reserve, 'thinkingDisabled': True})
    assert changes
    backups = root / 'client-config-backups'
    backups.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix='pi-budget-', dir=backups))
    os.chmod(backup, 0o700)
    for p, data in originals.items():
        destination = backup / (p.name + '.backup'); destination.write_bytes(data); os.chmod(destination, 0o600)
    updates = {models_path: models, settings_path: settings}; written = []
    try:
        for p, value in updates.items():
            assert p.read_bytes() == originals[p], 'Configuration changed during repair'
            fd, temporary = tempfile.mkstemp(dir=profile, prefix='.pi-budget-')
            with os.fdopen(fd, 'w') as out:
                json.dump(value, out, ensure_ascii=False, indent=2); out.write('\n'); out.flush(); os.fsync(out.fileno())
            os.replace(temporary, p); written.append(p)
    except Exception:
        for p in written: p.write_bytes(originals[p]); os.chmod(p, 0o600)
        raise
    report = {'result': 'passed', 'profile': str(profile), 'backup': str(backup), 'changes': changes, 'sessionHistoryChanged': False, 'modelServiceRestarted': False}
    target = Path('artifacts/pi-profile-repair-v069.json'); target.parent.mkdir(exist_ok=True); target.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report, ensure_ascii=False))
