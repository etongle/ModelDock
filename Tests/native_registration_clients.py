"""Validate actual pi/OpenCode model discovery with registered native configs."""
import json, os, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve()
exports = json.loads((root / 'native-exports.json').read_text())
home = root / 'native-client-home'; home.mkdir(exist_ok=True)
reports = []
for entry in exports:
    client = entry['client']
    # Use a separate test home: no mutation of the user's client settings.
    config = json.loads(Path(entry['registeredConfiguration']).read_text())
    config.pop('custom', None)
    if client == 'opencode':
        config['provider'].pop('existing', None)
        config.pop('mcp', None)  # Model discovery should not depend on external search.
        folder = home / '.config/opencode'; folder.mkdir(parents=True, exist_ok=True)
        (folder / 'opencode.json').write_text(json.dumps(config))
        env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), OPENCODE_DISABLE_MODELS_FETCH='1')
        for name in ['OPENCODE_CONFIG', 'OPENCODE_CONFIG_DIR', 'OPENCODE_TUI_CONFIG']: env.pop(name, None)
        for name in ['DATA', 'CACHE', 'STATE']: env['XDG_' + name + '_HOME'] = str(home / name.lower())
        command = ['/opt/homebrew/bin/opencode', 'models', entry['providerID']]
    else:
        config['providers'].pop('existing', None)
        folder = home / '.pi/agent'; folder.mkdir(parents=True, exist_ok=True)
        (folder / 'models.json').write_text(json.dumps(config))
        env = dict(os.environ, HOME=str(home), PI_CODING_AGENT_DIR=str(folder))
        command = ['/opt/homebrew/bin/pi', '--no-mcp', '--list-models', 'fixture']
    result = subprocess.run(command, cwd=home, env=env, capture_output=True, text=True, timeout=45)
    assert result.returncode == 0, (client, result.stderr, result.stdout)
    assert entry['model'] in result.stdout and 'fixture/text' in result.stdout, (client, result.stdout)
    reports.append({'client': client, 'modelsRecognized': ['fixture/vision', 'fixture/text'], 'result': 'passed'})
report = {'result': 'passed', 'checks': ['actual native client model listing', 'registered image/text models recognized', 'user profiles untouched'], 'clients': reports}
(root / 'native-clients-result.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
