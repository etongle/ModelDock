"""Generate translation drafts using the already-running local model; resume safely."""
from pathlib import Path
import json, re, time, urllib.request
ROOT=Path(__file__).resolve().parents[1]
DIR=ROOT/'Resources/Localization'
source=json.loads((DIR/'zh-Hans.json').read_text())
locales=['en','fr','pt']
data={lang:json.loads((DIR/(lang+'.json')).read_text()) if (DIR/(lang+'.json')).exists() else {} for lang in locales}
endpoint='http://127.0.0.1:8001/v1'
with urllib.request.urlopen(endpoint+'/models',timeout=10) as r: model=json.load(r)['data'][0]['id']

def save():
    for lang in locales:
        target=DIR/(lang+'.json'); tmp=target.with_suffix('.tmp')
        tmp.write_text(json.dumps(data[lang],ensure_ascii=False,indent=2)+'\n'); tmp.replace(target)

def valid(key,text):
    return isinstance(text,str) and bool(text.strip()) and not re.search('[\u3400-\u9fff]',text) and sorted(re.findall(r'\{\d+\}',key))==sorted(re.findall(r'\{\d+\}',text))

system='''You are a professional software localization translator. Translate native macOS AI model manager UI from Simplified Chinese to English (en), French (fr), and neutral Portuguese (pt). Return ONLY a JSON array, one object per input, with keys id,en,fr,pt. Keep every numbered placeholder {0}, {1}, etc EXACTLY ONCE PER SOURCE OCCURRENCE. Do not change product names, flags, paths, technical acronyms, units or IDs. Use concise natural UI wording. Terminology: engine=moteur/motor, model=modèle/modelo, draft model=modèle brouillon/modelo de rascunho (speculative decoding), service=service/serviço, gateway=passerelle/gateway. Splash, Llama, Ollama, MLX, pi, OpenCode, DFlash2 remain unchanged. “模型管理” as app name means ModelDock. “基座” in this app means runtime engine. Labels in quotation marks are other UI labels and should also be translated. Avoid verbose explanations. Preserve newlines. Never add Markdown fences.'''
keys=[key for key in source if any(not valid(key,data[lang].get(key)) for lang in locales)]
batches=[]; batch=[]; chars=0
for key in keys:
    if batch and (len(batch)>=40 or chars+len(key)>780):batches.append(batch);batch=[];chars=0
    batch.append(key);chars+=len(key)
if batch:batches.append(batch)
print('Starting',len(keys),'messages in',len(batches),'batches',flush=True)
for index,keys in enumerate(batches):
    request=[{'id':i,'text':key} for i,key in enumerate(keys)]
    errors=[]
    for attempt in range(3):
        try:
            body={'model':model,'messages':[{'role':'system','content':system},{'role':'user','content':json.dumps(request,ensure_ascii=False)}], 'temperature':0,'max_tokens':8192,'stream':False,'chat_template_kwargs':{'enable_thinking':False}}
            req=urllib.request.Request(endpoint+'/chat/completions',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
            with urllib.request.urlopen(req,timeout=240) as r: response=json.load(r)
            text=response['choices'][0]['message']['content'].strip();text=re.sub(r'^```(?:json)?\s*|\s*```$','',text)
            rows=json.loads(text)
            assert isinstance(rows,list) and len(rows)==len(keys),'Wrong row count'
            byid={row['id']:row for row in rows}
            for i,key in enumerate(keys):
                row=byid[i]
                for lang in locales: assert valid(key,row.get(lang)),(i,lang,'Invalid placeholders or untranslated text')
            for i,key in enumerate(keys):
                for lang in locales:data[lang][key]=byid[i][lang]
            save(); print(f'Batch {index+1}/{len(batches)}: {len(data["en"])}/{len(source)} translated',flush=True);break
        except Exception as e:
            errors.append(str(e));print('Retry',index+1,attempt+1,str(e)[:200],flush=True)
    else:
        (ROOT/'artifacts/localization-v080/translation-errors.json').write_text(json.dumps({'batch':keys,'errors':errors},ensure_ascii=False,indent=2));raise RuntimeError('Translation validation failed')
save();print('All translations generated and placeholders validated',flush=True)
