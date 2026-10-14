import fs from 'node:fs/promises';
import path from 'node:path';
const root=path.resolve(process.env.MODELDOCK_WEBSITE_CHECK_DIR||'artifacts/website-v080');await fs.mkdir(root,{recursive:true});
const base=process.env.MODELDOCK_WEBSITE_URL||'http://127.0.0.1:8765/';
const browser=process.env.MODELDOCK_BROWSER_URL||'http://127.0.0.1:19229';
const expectedID=process.env.MODELDOCK_EXPECT_GA4_ID||'';
const targets=await (await fetch(browser+'/json')).json();const target=targets.find(t=>t.type==='page');if(!target)throw Error('Owned browser target missing');
const ws=new WebSocket(target.webSocketDebuggerUrl);await new Promise((r,j)=>{ws.onopen=r;ws.onerror=j});
let id=0;const pending=new Map(),errors=[],requests=[],responses=[],lifecycle=new Set();
ws.onmessage=event=>{const msg=JSON.parse(event.data);if(msg.id){const p=pending.get(msg.id);pending.delete(msg.id);msg.error?p.reject(Error(JSON.stringify(msg.error))):p.resolve(msg.result)}else if(msg.method==='Runtime.exceptionThrown')errors.push(msg.params.exceptionDetails.text);else if(msg.method==='Network.requestWillBeSent')requests.push(msg.params.request.url);else if(msg.method==='Network.responseReceived')responses.push({url:msg.params.response.url,status:msg.params.response.status});else if(msg.method==='Page.lifecycleEvent')lifecycle.add(msg.params.loaderId+':'+msg.params.name)};
const send=(method,params={})=>new Promise((resolve,reject)=>{const key=++id;pending.set(key,{resolve,reject});ws.send(JSON.stringify({id:key,method,params}))});
const evaluate=async(expression)=>{const r=await send('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw Error(r.exceptionDetails.text);return r.result.value};
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const require=(ok,msg)=>{if(!ok)throw Error(msg)};
const waitFor=async(check,message)=>{for(let attempt=0;attempt<220;attempt++){try{if(await check())return}catch{}await sleep(250)}throw Error(message)};
const navigate=async(url,selector)=>{const navigation=await send('Page.navigate',{url});require(!navigation.errorText,'Navigation failed: '+navigation.errorText);if(navigation.loaderId)await waitFor(()=>lifecycle.has(navigation.loaderId+':DOMContentLoaded'),'Page did not load '+url);await waitFor(()=>evaluate('document.readyState!=="loading"&&!!document.querySelector('+JSON.stringify(selector)+')'),'Page content missing '+url)};
const imagesReady=async()=>{await evaluate('[...document.images].forEach(i=>i.loading="eager")');for(let attempt=0;attempt<220;attempt++){if(await evaluate('[...document.images].every(i=>i.complete&&i.naturalWidth>0)'))return;await sleep(250)}};
await send('Page.enable');await send('Runtime.enable');await send('Network.enable');
await send('Page.setLifecycleEventsEnabled',{enabled:true});await send('Network.setCacheDisabled',{cacheDisabled:true});
if(expectedID)await send('Page.addScriptToEvaluateOnNewDocument',{source:'window.dataLayer=[];window.gtag=function(){window.dataLayer.push(arguments)};window.gtag("set",{debug_mode:true});'});
await send('Emulation.setDeviceMetricsOverride',{width:1440,height:1000,deviceScaleFactor:1,mobile:false});
await navigate(base,'#hero-image');
await evaluate('localStorage.removeItem("modeldock-language")');await navigate(base,'#hero-image');
require(await evaluate('document.documentElement.lang==="en"'),'Website default not English');
require(await evaluate('document.getElementById("hero-image").src.includes("splash-hero.png")'),'Splash hero missing');
await imagesReady();require(await evaluate('[...document.images].every(i=>i.complete&&i.naturalWidth>0)'),'Broken landing page images');
await evaluate('document.querySelector("[data-tab=models]").click()');
require(await evaluate('document.getElementById("workflow-image").getAttribute("src").endsWith("en-models.png")'),'Model tab wrong screenshot');
await evaluate('document.querySelector("[data-tab=models]").dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowRight",bubbles:true}))');
require(await evaluate('document.querySelector("[data-tab=services]").getAttribute("aria-selected")==="true"&&document.activeElement.dataset.tab==="services"'),'Keyboard tabs failed');
await evaluate('document.getElementById("language").click()');await sleep(300);
require(await evaluate('document.documentElement.lang==="zh-Hans"&&document.querySelector("h1").textContent.includes("本地模型")'),'Chinese copy failed');
require(await evaluate('document.getElementById("hero-image").src.includes("splash-hero.png")'),'Chinese switch replaced Splash hero');
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
 await navigate(new URL(route,base).href,'article');
 await imagesReady();require(await evaluate('[...document.images].every(i=>i.complete&&i.naturalWidth>0)'),'Broken guide image '+route);
 const broken=await evaluate('[...document.querySelectorAll("a[href^=\\"#\\"]")].map(a=>a.getAttribute("href").slice(1)).filter(id=>!document.getElementById(decodeURIComponent(id)))');require(!broken.length,'Guide anchors missing '+broken);
 const result=await evaluate('({width:innerWidth,scroll:document.documentElement.scrollWidth})');require(result.scroll<=result.width+1,'Guide horizontal overflow '+route);
}
require(!errors.length,'Browser JavaScript errors');
const isAnalytics=url=>/^https:\/\/(?:[a-z0-9-]+\.)?(?:googletagmanager\.com|google-analytics\.com)\//.test(url);
let analytics={enabled:false};
if(expectedID){
 await waitFor(()=>evaluate('window.modeldockAnalyticsLoaded===true'),'Configured analytics did not load');
 const configurations=await evaluate('window.dataLayer.filter(command=>command[0]==="config").map(command=>command[1])');require(configurations.length===1&&configurations[0]===expectedID,'Measurement ID missing or duplicate configuration');
 await waitFor(()=>responses.some(response=>{const url=new URL(response.url);return url.hostname.endsWith('google-analytics.com')&&url.pathname.endsWith('/collect')&&url.searchParams.get('tid')===expectedID&&url.searchParams.get('en')==='page_view'&&response.status>=200&&response.status<300}),'Google did not acknowledge a page_view for '+expectedID);
 analytics={enabled:true,measurementId:expectedID,debugMode:true,configurationCount:configurations.length,pageViewAcknowledgements:responses.filter(response=>{const url=new URL(response.url);return url.hostname.endsWith('google-analytics.com')&&url.searchParams.get('tid')===expectedID&&url.searchParams.get('en')==='page_view'}).map(response=>({status:response.status,event:'page_view'}))};
}else require(!requests.some(isAnalytics),'Analytics loaded while measurement ID is unset');
const report={result:'passed',checks:['English default and Chinese language switch','Splash hero retained in both languages','language-specific workflow screenshots','workflow tabs and keyboard navigation','landing layouts at 375/768/1440','illustrated English/Chinese guides and anchor targets','no page-level horizontal overflow','no JavaScript exceptions',expectedID?'configured GA4 page_view acknowledged by Google':'no analytics requests before a measurement ID is configured'],measurements,analytics,externalPublicationChecked:base.startsWith('https://'),sourceURL:base};await fs.writeFile(path.join(root,'result.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));ws.close();
