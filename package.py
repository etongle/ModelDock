"""Build clean shareable DMG/ZIP artifacts from the verified application only."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parent
app = project / 'build/ModelDock.app'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
assert info['LSMinimumSystemVersion'] == '14.0'
assert (app / 'Contents/Resources/PythonRuntime/bin/python3').is_file()
assert (app / 'Contents/Resources/ThirdPartyNotices').is_dir()
allowed = {'AppIcon.icns', 'gateway.py', 'strata.py', 'app_update.py', 'audio_server.py', 'image_server.py', 'ProcessIdentity.dylib', 'PythonRuntime', 'python-runtime.json', 'ThirdPartyNotices', 'Localization', 'LICENSE', 'LICENSE-NOTICE.txt'}
assert {p.name for p in (app / 'Contents/Resources').iterdir()} == allowed, 'Unexpected application resources'
assert not list(app.rglob('__pycache__')), 'Bytecode should not be embedded in distribution'
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
out = project / 'dist' / version
out.mkdir(parents=True, exist_ok=True)
stage = Path(tempfile.mkdtemp(prefix='package-stage-', dir=project / 'build'))
readme = f'''ModelDock {version} — Installation / 安装说明

Apple Silicon (M-series) Macs · macOS 14 or later.

1. Open the DMG and drag ModelDock.app to Applications.
2. Open ModelDock from Applications. The first-launch language is English.
3. Click the globe/language button at the top right to choose English,
   简体中文, Français, Português or Follow system. Settings (⌘,) also has
   Interface language. Language changes apply immediately.
4. Select/install a compatible engine, then import or download a model.
   Homebrew-managed engines require Homebrew: https://brew.sh
   The manager includes the Python runtime used by its unified gateway.
5. Settings → App updates checks official GitHub Releases daily and can
   automatically download, verify and install newer versions. Model files,
   settings and existing model service processes are preserved.
6. Downloads & Import supports Hugging Face, ModelScope, GitHub repositories,
   individual files and Release assets. Download 2 models at once by default;
   change the limit (1–8) in the sidebar or Settings → Downloads. The + button
   opens a clean import form. Task/file progress includes time remaining.
7. Solutions (⌘6) offers multilingual live translation with microphone
   captions, audio file translation and optional speech. Install and start
   matched components, or edit an existing configuration. Each solution
   retains its dedicated gateway URL when edited.
8. Stopped service cards and service details can start an existing instance
   with its saved configuration. Instance deletion keeps services, models
   and engines unless optional cleanup is explicitly selected; shared
   resources are protected. Port conflicts are checked before restart;
   Use free port changes the draft until Save & Start / Save & Restart.
9. Strata SC117 Flash-Next and MFLUX Qwen-Image-2.1-Turbo integrations are
   previews. Full-model inference validation remains pending complete
   model downloads. Image generation requires a separate MFLUX runtime.
10. Close the main window to keep downloads/monitoring running. Use the
   menu-bar icon to reopen it; clicking outside its panel dismisses it.

This distribution is ad-hoc signed and is not Apple-notarized. If a trusted
copy is blocked, follow Apple's Open Anyway instructions:
https://support.apple.com/102445

Models, credentials and personal configuration are not included.
Existing manager data remains in ~/Library/Application Support/ModelManager.
An update preserves model files and service configuration.

License: PolyForm Noncommercial 1.0.0. Commercial use is not granted.
The application includes LICENSE, required notices and third-party notices
in Contents/Resources. External engines/models retain their own licenses.

Project and illustrated guides: https://github.com/etongle/ModelDock

中文
将 ModelDock.app 拖到“应用程序”并打开。首次默认英语，点击主界面右上角的地球
语言按钮即可切换，也可按 ⌘, 打开设置。支持中文、法语、葡萄牙语或跟随系统。
可信安装包被拦截时参考上面的 Apple 官方说明。
默认关闭主窗口继续后台运行，点击菜单栏图标重新打开，点击面板外部自动收起。
软件限于许可规定的非商业使用；第一方与第三方许可在应用资源中保留。
本发行包不包含个人配置、密钥或模型权重。
'''

try:
    staged_app = stage / app.name
    subprocess.run(['/usr/bin/ditto', '--noextattr', '--norsrc', str(app), str(staged_app)], check=True)
    os.symlink('/Applications', stage / 'Applications')
    (stage / 'INSTALL.txt').write_text(readme, encoding='utf-8')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged_app)], check=True)
    base = 'ModelDock-' + version + '-AppleSilicon'
    dmg, archive = out / (base + '.dmg'), out / (base + '.zip')
    # Existing releases stay intact; generating a new copy requires explicit removal.
    assert not dmg.exists() and not archive.exists(), 'Release artifacts already exist'
    subprocess.run(['/usr/bin/hdiutil', 'create', '-volname', 'ModelDock ' + version, '-fs', 'HFS+', '-format', 'UDZO', '-srcfolder', str(stage), str(dmg)], check=True)
    subprocess.run(['/usr/bin/hdiutil', 'verify', str(dmg)], check=True)
    subprocess.run(['/usr/bin/ditto', '--noextattr', '--norsrc', '-c', '-k', '--keepParent', str(staged_app), str(archive)], check=True)
    (out / 'INSTALL.txt').write_text(readme, encoding='utf-8')
    def digest(file):
        value = hashlib.sha256()
        with file.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''): value.update(block)
        return value.hexdigest()
    artifacts = [{'name':p.name,'bytes':p.stat().st_size,'sha256':digest(p)} for p in [dmg,archive]]
    (out / 'SHA256SUMS.txt').write_text(''.join(row['sha256'] + '  ' + row['name'] + '\n' for row in artifacts))
    report = {'version':version,'appBundle':'ModelDock.app','minimumMacOS':'14.0','architecture':'arm64','signing':'ad-hoc','notarized':False,'bundledPython':True,'userConfigurationIncluded':False,'modelsIncluded':False,'artifacts':artifacts}
    (out / 'release.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps(report,ensure_ascii=False))
finally:
    shutil.rmtree(stage,ignore_errors=True)
