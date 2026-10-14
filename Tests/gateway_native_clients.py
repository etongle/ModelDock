from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import json,os,re,subprocess,sys,threading,urllib.request,time
root=Path(sys.argv[1]).resolve()
exports=json.loads((root/'live-exports.json').read_text())
fixture=Path(exports[0]['project'])/'fixture.txt'
fixture.write_text('MODEL_MANAGER_CONTEXT_READ_FIXTURE\n')
requests=[]
active=None
def opencode_run(executable,model):
    # OpenCode 2.x dropped --pure and attaches to a shared background service; --standalone keeps the isolated config.
    version=subprocess.run([executable,'--version'],capture_output=True,text=True,stdin=subprocess.DEVNULL).stdout
    found=re.search(r'(\d+)\.\d+',version)
    if found and int(found.group(1))>=2:return [executable,'run','--standalone','--model',model,'--format','json']
    return [executable,'--pure','run','--model',model,'--format','json']
class Proxy(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        request=urllib.request.Request(active['endpoint']+'/models',headers={'Authorization':'Bearer '+active['testApiKey']})
        with urllib.request.urlopen(request,timeout=5) as r:data=r.read()
        self.reply(200,data)
    def do_POST(self):
        original=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        native_stream=original.get('stream',False)
        request=dict(original,stream=False);request.pop('stream_options',None)
        sample={'client':active['client'],'model':request.get('model'),'tools':len(request.get('tools',[])),
            'systemCharacters':sum(len(str(m.get('content',''))) for m in request.get('messages',[]) if m['role']=='system'),
            'max_tokens':request.get('max_tokens'),'tool_result':any(m.get('role')=='tool' and 'MODEL_MANAGER_CONTEXT_READ_FIXTURE' in str(m.get('content')) for m in request.get('messages',[]))}
        requests.append(sample)
        if len(requests)>18:self.reply(400,b'{"error":{"message":"Repeated request guard","code":"test_stopped"}}');return
        try:
            upstream=urllib.request.Request(active['endpoint']+'/chat/completions',data=json.dumps(request).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+active['testApiKey']})
            with urllib.request.urlopen(upstream,timeout=110) as response:result=json.loads(response.read())
        except urllib.error.HTTPError as e:
            sample['http']=e.code;self.reply(e.code,e.read());return
        sample['http']=200;sample['usage']=result.get('usage')
        for choice in result.get('choices',[]):
            for call in choice['message'].get('tool_calls') or []:
                args=json.loads(call.get('function',{}).get('arguments','{}'))
                file=args.get('path') or args.get('filePath') or ''
                if not Path(file).is_absolute():file=str(Path(active['project'])/file)
                if call.get('function',{}).get('name')!='read' or Path(file).resolve()!=fixture.resolve():
                    sample['blocked_tool']=call.get('function',{}).get('name');self.reply(400,b'{"error":{"message":"Test permits only its own read fixture","code":"test_stopped"}}');return
        if not native_stream:self.reply(200,json.dumps(result).encode());return
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Connection','close');self.end_headers()
        for choice in result.get('choices',[]):
            delta=dict(choice['message'])
            for i,call in enumerate(delta.get('tool_calls') or []):call['index']=i
            for fragment in [{'index':choice['index'],'delta':delta,'finish_reason':None},{'index':choice['index'],'delta':{},'finish_reason':choice.get('finish_reason')}]:
                event={k:result[k] for k in ['id','created','model'] if k in result};event.update(object='chat.completion.chunk',choices=[fragment],usage=result.get('usage'))
                self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode())
        self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
    def reply(self,code,data):
        self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Proxy)
threading.Thread(target=server.serve_forever,daemon=True).start()
results=[]
try:
    for info in exports:
        active=info;requests.clear();client=info['client']
        config=json.loads(Path(info['configuration']).read_text());env=dict(os.environ)
        provider=next(iter(config['provider' if client=='opencode' else 'providers'].values()))
        active['testApiKey']=provider['options']['apiKey'] if client=='opencode' else provider['apiKey']
        for name in info.get('unsetEnvironment') or []:env.pop(name,None)
        env.update(info['environment']);
        if client=='opencode':
            for selector in ['DATA','CACHE','STATE']:env[f'XDG_{selector}_HOME']=str(root/'native-check'/selector.lower())
        env['PWD']=info['project'];env['PI_TELEMETRY']='0';env['PI_OFFLINE']='1'
        url=f'http://127.0.0.1:{server.server_port}/v1'
        if client=='pi':
            for p in config['providers'].values():p['baseUrl']=url
            profile=root/'pi-native';profile.mkdir(exist_ok=True)
            (profile/'models.json').write_text(json.dumps(config));(profile/'settings.json').write_text((Path(info['configuration']).parent/'settings.json').read_text())
            env['PI_CODING_AGENT_DIR']=str(profile)
        else:
            for p in config['provider'].values():p['options']['baseURL']=url
            env['OPENCODE_CONFIG_CONTENT']=json.dumps(config)
        session=None
        prompts=['你是谁？请用中文简要回答，不要调用工具。','你能做什么？请用中文简要回答，不要调用工具。',f'请只使用 read 工具读取 {fixture}，并告诉我文件的内容。不要使用其他工具。']
        for n,prompt in enumerate(prompts):
            if client=='pi':command=[info['executable']]+info['arguments']+['--offline','--session',str(root/'pi-conversation.jsonl'),'--print',prompt]
            else:
                command=opencode_run(info['executable'],info['providerID']+'/'+info['model'])
                if session:command+=['--session',session]
                command+=[prompt]
            began=len(requests);t=time.time();done=subprocess.run(command,cwd=info['project'],env=env,text=True,capture_output=True,timeout=150,stdin=subprocess.DEVNULL)
            (root/f'{client}-turn{n}.stdout').write_text(done.stdout);(root/f'{client}-turn{n}.stderr').write_text(done.stderr)
            if client=='opencode':
                pieces=[];compactions=0
                for line in done.stdout.splitlines():
                    try:event=json.loads(line)
                    except ValueError:continue
                    session=event.get('sessionID') or session
                    if event.get('type')=='text':pieces.append(event.get('part',{}).get('text',''))
                    if event.get('type')=='error':pieces.append('ERROR:'+str(event))
                reply=''.join(pieces)
            else:reply=done.stdout
            traffic=requests[began:]
            valid=done.returncode==0 and len(reply.strip())>10 and any(x['tools']>=4 for x in traffic) and all(x.get('http')==200 and not x.get('blocked_tool') for x in traffic) and len(traffic)<=5
            if n==2:valid=valid and any(x['tool_result'] for x in traffic) and 'MODEL_MANAGER_CONTEXT_READ_FIXTURE' in reply
            result={'client':client,'turn':n,'passed':valid,'seconds':round(time.time()-t,1),'requests':len(traffic),'replyCharacters':len(reply)}
            results.append(result);print(json.dumps(result),flush=True)
        (root/f'{client}-traffic.json').write_text(json.dumps(requests,indent=2))
    report={'result':'passed' if all(x['passed'] for x in results) else 'failed','full_coding_tools_enabled':True,'checks':results}
    (root/'full-tools-result.json').write_text(json.dumps(report,indent=2))
finally:
    server.shutdown();server.server_close();(root/'finish').touch()
sys.exit(0 if report['result']=='passed' else 1)
