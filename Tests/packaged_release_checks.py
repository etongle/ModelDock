"""Verify the actual DMG and ZIP, including relocated runtime execution."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
version = sys.argv[1] if len(sys.argv) > 1 else plistlib.loads((project / 'build/ModelDock.app/Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
release = project / 'dist' / version
root = project / 'artifacts' / ('packaged-v' + version.replace('.', ''))
root.mkdir(parents=True, exist_ok=True)
manifest = json.loads((release / 'release.json').read_text())
for item in manifest['artifacts']:
    h = hashlib.sha256()
    with (release / item['name']).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
    assert h.hexdigest() == item['sha256']
mount = root / 'mount'; mount.mkdir(exist_ok=True)
dmg = next(release.glob('*.dmg'))
mounted = False
try:
    raw = subprocess.check_output(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), '-plist', str(dmg)])
    plistlib.loads(raw); mounted = True
    assert (mount / 'Applications').is_symlink() and os.readlink(mount / 'Applications') == '/Applications'
    assert (mount / ('INSTALL.txt' if manifest.get('appBundle') else '安装说明.txt')).is_file()
    extracted = root / 'zip'
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(next(release.glob('*.zip'))), str(extracted)], check=True)
    apps = [('dmg', mount / manifest.get('appBundle', '模型管理.app')), ('zip', extracted / manifest.get('appBundle', '模型管理.app'))]
    for label, app in apps:
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleShortVersionString'] == version and info['LSMinimumSystemVersion'] == '14.0'
        headers = subprocess.check_output(['/usr/bin/otool', '-l', str(app / 'Contents/MacOS/ModelManager')], text=True)
        assert 'minos 14.0' in headers
        home = root / ('home-' + label); home.mkdir(exist_ok=True)
        env = dict(os.environ, CFFIXED_USER_HOME=str(home), PATH='/usr/bin:/bin:/usr/sbin:/sbin')
        output = root / label
        policy = '(version 1)(allow default)(deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local") (literal "/usr/bin/python3") (subpath "/Applications/Llama.app") (subpath "/Applications/LM Studio.app"))(deny process-exec (subpath "/opt/homebrew") (subpath "/usr/local") (literal "/usr/bin/python3"))'
        subprocess.run(['/usr/bin/sandbox-exec', '-p', policy, str(app / 'Contents/MacOS/ModelManager'), '--distribution-checks', '--state-dir', str(home / 'Library/Application Support/ModelManager'), '--check-dir', str(output)], env=env, check=True, timeout=45)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        assert not list(app.rglob('__pycache__'))
    report = {'result':'passed','version':version,'checks':['DMG/ZIP hashes match release manifest','DMG has application, Applications shortcut and instructions','both extracted apps have valid signatures and macOS 14 target','relocated gateway runs using bundled Python while external runtimes are blocked','signatures remain valid after runtime use','temporary test ports released','personal configuration and models excluded by clean application staging'],'olderOSHardwareTested':False}
    (root / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps(report,ensure_ascii=False))
finally:
    if mounted: subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount)], check=True)
