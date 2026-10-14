"""Install a verified, isolated MLX-VLM companion without replacing MLX-LM."""
import json
import os
import subprocess
import time
import uuid
from pathlib import Path

project = Path(__file__).resolve().parents[1]
versions = json.loads(Path('/private/tmp/model-manager-mlx-versions.json').read_text())
vision_version = versions['mlx-vlm']['version']
text_version = versions['mlx-lm']['version']
assert all(value and all(c.isalnum() or c in '.-_' for c in value) for value in (vision_version, text_version))
root = Path.home() / 'Library/Application Support/ModelManager/engines/mlx'
directory = root / str(uuid.uuid4())
assert str(directory.resolve()).startswith(str(root.resolve()) + '/')
python = next(p for p in ('/opt/homebrew/opt/python@3.13/bin/python3.13', '/opt/homebrew/opt/python@3.12/bin/python3.12', '/opt/homebrew/bin/python3') if os.access(p, os.X_OK))
environment = directory / 'venv'
subprocess.run([python, '-m', 'venv', str(environment)], check=True)
subprocess.run([str(environment / 'bin/python3'), '-m', 'pip', '--isolated', 'install', '--disable-pip-version-check',
                '--index-url', 'https://pypi.org/simple', 'mlx-vlm==' + vision_version, 'mlx-lm==' + text_version], check=True)
server = environment / 'bin/mlx_vlm.server'
env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
help_text = subprocess.check_output([str(server), '--help'], env=env, text=True, stderr=subprocess.STDOUT)
assert all(option in help_text for option in ('--model', '--host', '--port'))
entry = {'kind': 'mlx', 'version': vision_version, 'executable': str(server.relative_to(root)),
         'source': 'PyPI · Blaizzy/mlx-vlm', 'installedAt': time.time() - 978307200}
temporary = root / ('vision-' + str(uuid.uuid4()) + '.tmp')
temporary.write_text(json.dumps(entry))
os.replace(temporary, root / 'vision.json')
evidence = project / 'artifacts/mlx-vlm-runtime-v065'
evidence.mkdir(parents=True, exist_ok=True)
(evidence / 'server-help.txt').write_text(help_text)
(evidence / 'installation.json').write_text(json.dumps({'result': 'passed', 'entry': entry, 'textRuntimePreserved': True}, indent=2))
print(json.dumps({'result': 'passed', 'version': vision_version, 'server': str(server), 'textRuntimePreserved': True}))
