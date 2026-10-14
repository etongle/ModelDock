import fs from 'node:fs/promises';
import path from 'node:path';
const root=path.resolve('artifacts/website-v080');await fs.mkdir(root,{recursive:true});
const targets=await (await fetch('http://127.0.0.1:19229/json')).json();const target=targets.find(t=>t.url==='about:blank');if(!target)throw Error('Owned browser target missing');
const ws=new WebSocket(target.webSocketDebuggerUrl);await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j});
let id=0;const pending=new Map(),errors=[];
ws.onmessage=event=>{const msg=JSON.parse(event.data);if(msg.id){const p=pending.get(msg.id);pending.delete(msg.id);msg.error?p.reject(Error(JSON.stringify(msg.error))):p.resolve(msg.result)}else if(msg.method==='Runtime.exceptionThrown')errors.push(msg.params.exceptionDetails.text)};
const send=(method,params={})=>new Promise((resolve,reject)=>{const key=++id;pending.set(key,{resolve,reject});ws.send(JSON.stringify({id:key,method,params}))});
const evaluate=async(expression)=>{const r=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.text);return r.result.value};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const require=(ok,msg)=>{if(!ok)throw Error(msg)};
await send('Page.enable');await send('Runtime.enable');
await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
await send('Page.navigate',{url:'http://127.0.0.1:8765/'});await sleep(700);
await evaluate('localStorage.removeItem("modeldock-language");location.reload()');await sleep(550);
require(await evaluate('document.documentElement.lang==="en"'),'Website default not English');
require(await evaluate('[...document.images].every(i=>i.complete&&i.naturalWidth>0)'),'Broken landing page images');
await evaluate('document.querySelector("[data-tab=models]").click()');
require(await evaluate('document.getElementById("workflow-image").getAttribute("src").endsWith("en-models.png")'),'Model tab wrong screenshot');
await evaluate('document.querySelector("[data-tab=models]").dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowRight",bubbles:true}))');
require(await evaluate('document.querySelector("[data-tab=services]").getAttribute("aria-selected")==="true"&&document.activeElement.dataset.tab==="services"'),'Keyboard tabs failed');
await evaluate('document.getElementById("language").click()');await sleep(300);
require(await evaluate('document.documentElement.lang==="zh-Hans"&&document.querySelector("h1").textContent.includes("本地模型")'),'Chinese copy failed');
require(await evaluate('document.getElementById("workflow-image").getAttribute("src").includes("zh-Hans-services")'),'Chinese screenshot not changed');
await evaluate('document.getElementById("language").click()');
let screenshot=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});await fs.writeFile(path.join(root,'desktop.png'),Buffer.from(screenshot.data,'base64'));
const widths=[375,768,1440],measurements=[];
for(const width of widths){
 await send('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:1,mobile:width<600});await sleep(150);
 const result=await evaluate('({width:innerWidth,scroll:document.documentElement.scrollWidth})');require(result.scroll<=result.width+1,'Landing page horizontal overflow '+width);measurements.push(result);
 if(width===375){screenshot=await send('Page.captureScreenshot',{format:'png',captureBeyondViewport:true});await fs.writeFile(path.join(root,'mobile.png'),Buffer.from(screenshot.data,'base64'))}
}
for(const route of ['guide.html','guide.zh-CN.html']){
 await send('Page.navigate',{url:'http://127.0.0.1:8765/'+route});await sleep(450);
 require(await evaluate('[...document.images].every(i=>i.complete&&i.naturalWidth>0)'),'Broken guide image '+route);
 const broken=await evaluate('[...document.querySelectorAll("a[href^=\\"#\\"]")].map(a=>a.getAttribute("href").slice(1)).filter(id=>!document.getElementById(decodeURIComponent(id)))');require(!broken.length,'Guide anchors missing '+broken);
 const result=await evaluate('({width:innerWidth,scroll:document.documentElement.scrollWidth})');require(result.scroll<=result.width+1,'Guide horizontal overflow '+route);
}
require(!errors.length,'Browser JavaScript errors');
const report={result:'passed',checks:['English default and Chinese language switch','language-specific screenshots','workflow tabs and keyboard navigation','landing layouts at 375/768/1440','illustrated English/Chinese guides and anchor targets','no page-level horizontal overflow','no JavaScript exceptions'],measurements,externalPublicationChecked:false};await fs.writeFile(path.join(root,'result.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));ws.close();
