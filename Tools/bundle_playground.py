"""Bundle the built, locally adapted MIT Playground client and its notices."""
from pathlib import Path
import json
import shutil

root = Path(__file__).resolve().parents[1]
client = root / 'Client/Playground'
target = root / 'Resources/PlaygroundClient'
assert (client / 'dist/index.html').is_file(), 'Build Client/Playground first'
if target.exists():
    shutil.rmtree(target)
shutil.copytree(client / 'dist', target)
shutil.copy2(client / 'modeldock-default.json', target / 'config-template.json')
notices = root / 'Resources/ThirdPartyNotices/GPT-Image-Playground'
notices.mkdir(parents=True, exist_ok=True)
shutil.copy2(client / 'LICENSE', notices / 'LICENSE.txt')
shutil.copy2(client / 'UPSTREAM-COMMIT.txt', notices / 'UPSTREAM-COMMIT.txt')
lock = json.loads((client / 'package-lock.json').read_text())
for name, package in lock.get('packages', {}).items():
    if not name.startswith('node_modules/') or package.get('dev'):
        continue
    module = client / name
    if not module.is_dir():
        continue
    for file in module.iterdir():
        if file.is_file() and file.name.lower().startswith(('license', 'copying', 'notice')):
            destination = notices / name.removeprefix('node_modules/').replace('/', '__')
            destination.mkdir(exist_ok=True)
            shutil.copy2(file, destination / file.name)
fonts = client / 'third-party-licenses'
if fonts.is_dir():
    shutil.copytree(fonts, notices / 'fonts', dirs_exist_ok=True)
(notices / 'LOCAL-CHANGES.txt').write_text('Adapted for ModelDock local model services: same-origin configuration, server-side gateway credentials, direct mask editing, generation progress, responsive input controls and local image preservation. Upstream MIT license remains applicable to this component.\n')
print('Bundled Playground client and runtime dependency notices')
