"""Render the project's own trusted Markdown guides into static Pages documents."""
from pathlib import Path
import markdown
root=Path(__file__).resolve().parents[1]
for lang,name in [('en','USER_GUIDE.md'),('zh','USER_GUIDE.zh-CN.md')]:
    document=(root/'docs'/name).read_text()
    parser=markdown.Markdown(extensions=['tables','fenced_code','toc'])
    content=parser.convert(document)
    content=content.replace('src="assets/images/','src="assets/').replace('href="USER_GUIDE.zh-CN.md"','href="guide.zh-CN.html"').replace('href="USER_GUIDE.md"','href="guide.html"')
    for local,target in [('LICENSING.md','docs/LICENSING.md'),('../README.md','README.md'),('../README.zh-CN.md','README.zh-CN.md')]:
        content=content.replace('href="'+local+'"','href="https://github.com/etongle/ModelDock/blob/main/'+target+'"')
    title='User guide' if lang=='en' else '使用说明'
    page=f'''<!doctype html><html lang="{'en' if lang=='en' else 'zh-Hans'}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{title} — ModelDock</title><meta name="description" content="Illustrated ModelDock usage guide"><link rel="icon" href="assets/logo.png"><link rel="stylesheet" href="site.css"></head><body data-page="guide" data-language="{lang}"><a class="skip-link" href="#main" data-i18n="skip">Skip to content</a><header class="site-header"><div class="wrap header-inner"><a class="brand" href="./"><img src="assets/logo.png" width="36" height="36" alt=""><span>ModelDock</span></a><nav aria-label="Main navigation"><a href="./#workflow" data-i18n="navHow">How it works</a><a href="https://github.com/etongle/ModelDock">GitHub ↗</a></nav><button type="button" id="language" class="language">中文</button></div></header><main id="main" class="wrap guide-layout"><aside class="guide-toc" aria-label="{'Contents' if lang=='en' else '目录'}">{parser.toc}</aside><article class="guide-content">{content}</article></main><footer class="wrap"><a class="brand" href="./"><img src="assets/logo.png" width="28" height="28" alt=""><span>ModelDock</span></a><p data-i18n="footer">Source available. Noncommercial use.</p></footer><script src="site.js" defer></script></body></html>'''
    (root/'website'/('guide.html' if lang=='en' else 'guide.zh-CN.html')).write_text(page)
    print('Built guide',lang)
