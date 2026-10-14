"""Stage only reviewed source, documentation and static assets for public GitHub."""
from pathlib import Path
import json, shutil, zipfile, hashlib
root=Path(__file__).resolve().parents[1]
out=root/'artifacts/publish-v080';stage=out/'ModelDock';stage.mkdir(parents=True,exist_ok=True)
files=['README.md','README.zh-CN.md','CONTRIBUTING.md','LICENSE','LICENSE-NOTICE.txt','.gitignore','build.sh','package.py','prepare-runtime.py','prepare-notices.py']
folders=['Sources','Resources','Tests','Tools','docs','website','.github']
for name in files:shutil.copy2(root/name,stage/name)
for name in folders:
 shutil.copytree(root/name,stage/name,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc','.DS_Store'))
selected=[p for p in stage.rglob('*') if p.is_file()]
for p in selected:
 if p.suffix in ['.swift','.py','.mjs','.md','.html','.js','.yml','.json','.txt']:
  text=p.read_text()
  assert str(Path.home()) not in text,('Developer path in staged source',p)
 assert not p.is_symlink(),('Unexpected public symlink',p)
archive=out/'ModelDock-0.8.0-source-and-docs.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
 for p in selected:z.write(p,p.relative_to(out))
manifest={'result':'prepared','repository':'https://github.com/etongle/ModelDock','remoteWritesPerformed':False,'files':len(selected),'archive':archive.name,'bytes':archive.stat().st_size,'sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'includes':['first-party source','localization catalogs','dependency license notices','English/Chinese introductions and illustrated guides','GitHub Pages static site/workflow'],'excludes':['personal state','model weights','build caches','runtime archives','development screenshots/logs','credentials','synced project sources']}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(manifest))
