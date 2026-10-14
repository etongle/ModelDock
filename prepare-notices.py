"""Keep upstream license files from the matching verified Python build."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile
import urllib.request

project = Path(__file__).resolve().parent
cache = project / 'build/runtime-cache'
archive = cache / 'python-3.13.16-20261009-full.tar.zst'
expected = '70025edd2ed4bf0a333677928ded047368726954253b6e428732e71e9c5a163e'
source = 'https://mirrors.nju.edu.cn/github-release/astral-sh/python-build-standalone/20261009/cpython-3.13.16%2B20261009-aarch64-apple-darwin-pgo%2Blto-full.tar.zst'
def digest(file):
    value = hashlib.sha256()
    with file.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): value.update(block)
    return value.hexdigest()
if not archive.exists() or digest(archive) != expected:
    temporary = archive.with_suffix('.download')
    with urllib.request.urlopen(source, timeout=60) as incoming, temporary.open('wb') as outgoing: shutil.copyfileobj(incoming, outgoing)
    if digest(temporary) != expected: raise RuntimeError('License archive checksum mismatch')
    temporary.replace(archive)
members = subprocess.check_output(['/usr/bin/tar', '-tf', str(archive)], text=True).splitlines()
wanted = [name for name in members if PurePosixPath(name).name.lower().startswith(('license', 'copying', 'copyright', 'notice')) or name == 'python/PYTHON.json']
for name in wanted:
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or path.parts[0] != 'python': raise RuntimeError('Unsafe license archive path')
stage = Path(tempfile.mkdtemp(prefix='license-', dir=cache))
try:
    subprocess.run(['/usr/bin/tar', '-xf', str(archive), '-C', str(stage)] + wanted, check=True)
    metadata = json.loads((stage / 'python/PYTHON.json').read_text())
    target = project / 'Resources/ThirdPartyNotices'
    target.mkdir(exist_ok=True)
    for original in (stage / 'python').rglob('*'):
        if original.is_file() and original.name != 'PYTHON.json':
            if original.is_symlink(): raise RuntimeError('Unexpected license symlink')
            relative = original.relative_to(stage / 'python')
            destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(original, destination)
    (target / 'Python-distribution.json').write_text(json.dumps({'source': 'https://github.com/astral-sh/python-build-standalone/releases/tag/20261009', 'pythonVersion': metadata.get('python_version'), 'licenses': metadata.get('licenses'), 'archiveSHA256': expected}, indent=2))
    print(json.dumps({'files': len(wanted) - 1, 'pythonVersion': metadata.get('python_version'), 'licenses': metadata.get('licenses')}))
finally:
    shutil.rmtree(stage, ignore_errors=True)
