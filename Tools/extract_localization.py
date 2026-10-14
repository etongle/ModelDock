"""Extract source-language messages without changing model identities or persisted states."""
from pathlib import Path
import json, re
ROOT = Path(__file__).resolve().parents[1]
CJK = re.compile('[\u3400-\u9fff]')

def string_at(s, pos):
    raw = pos > 0 and s[pos-1] == '#'
    triple = s.startswith('"""',pos)
    stop = '"""' if triple else '"'
    start = pos + len(stop); i = start; chunks=[]; args=[]; literal=start
    while i < len(s):
        if s.startswith(stop,i):
            chunks.append(s[literal:i]); return i+len(stop), ''.join(chunks), args, raw or triple
        if s[i] == '\\':
            if i+1 < len(s) and s[i+1] == '(' and not raw:
                chunks.append(s[literal:i]); j=i+2; depth=1; argstart=j
                while j < len(s) and depth:
                    if s[j] == '"': j,_,_,_ = string_at(s,j); continue
                    if s[j] == '(' : depth+=1
                    elif s[j] == ')' : depth-=1
                    j+=1
                args.append(s[argstart:j-1]); chunks.append('{'+str(len(args)-1)+'}'); i=j; literal=j; continue
            i+=2; continue
        i+=1
    raise ValueError('Unterminated Swift string')

def literals(s):
    i=0
    while i<len(s):
        if s.startswith('//',i):
            j=s.find('\n',i); i=len(s) if j<0 else j; continue
        if s.startswith('/*',i):
            depth=1; i+=2
            while i<len(s) and depth:
                if s.startswith('/*',i):depth+=1;i+=2
                elif s.startswith('*/',i):depth-=1;i+=2
                else:i+=1
            continue
        if s[i]=='"':
            start=i; i,key,args,special=string_at(s,i)
            yield start,i,key,args,special
        else:i+=1

def decoded(s):
    return s.replace('\\n','\n').replace('\\t','\t').replace('\\r','\r').replace('\\"','"').replace('\\\\','\\')

if __name__=='__main__':
    keys={}; origins={}
    for path in sorted((ROOT/'Sources').glob('*.swift')):
        if path.stem.endswith('Checks') or path.stem=='Localization':continue
        for _,_,key,args,special in literals(path.read_text()):
            if special or not CJK.search(key):continue
            key=decoded(key)
            if not args and re.search(r'%(?:\d+\$)?[-+0-9.]*[df@]',key):
                n=[0]
                def fmt(m):
                    v='{'+str(n[0])+'}';n[0]+=1;return v
                key=re.sub(r'%(?:\d+\$)?[-+0-9.]*[df@]',fmt,key)
            keys[key]=key;origins.setdefault(key,[]).append(path.name)
    keys["跟随系统"]="跟随系统"
    ordered=sorted(keys,key=lambda k:(k not in ['运行引擎','模型文件','模型服务','下载导入','资源与性能','模型管理','设置','完成','启动服务','停止服务'],len(k),k))
    (ROOT/'Resources/Localization/zh-Hans.json').write_text(json.dumps({k:k for k in ordered},ensure_ascii=False,indent=2)+'\n')
    (ROOT/'artifacts/localization-v080/source-index.json').write_text(json.dumps(origins,ensure_ascii=False,indent=2)+'\n')
    print(len(keys),sum(map(len,keys)))
