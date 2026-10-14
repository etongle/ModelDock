// Isolated JavaScript checks; no request is sent to Google or a real property.
import fs from 'node:fs/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = await fs.readFile('website/analytics.js', 'utf8');
const config = {enabled:true,provider:'ga4',measurementId:'G-TEST123456',hostname:'etongle.github.io',pathPrefix:'/ModelDock/'};
async function run({hostname='etongle.github.io',path='/ModelDock/',configuration=config,failure=false,repeat=false}={}) {
 const scripts=[];let requests=0;
 const document={currentScript:{src:'https://etongle.github.io/ModelDock/analytics.js'},referrer:'https://example.com/source?private=value',createElement:()=>({}),head:{appendChild:s=>scripts.push(s)}};
 const context={document,location:{hostname,pathname:path,origin:'https://'+hostname,search:'?private=value'},URL,Date,window:{},fetch:async()=>{requests++;if(failure)throw Error('network unavailable');return {ok:true,json:async()=>configuration}}};
 vm.createContext(context);vm.runInContext(source,context);await new Promise(r=>setImmediate(r));
 if(repeat){vm.runInContext(source,context);await new Promise(r=>setImmediate(r));}
 return {scripts,requests,events:context.window.dataLayer?.map(a=>Array.from(a))||[]};
}
assert.equal((await run({hostname:'localhost'})).requests,0);
assert.equal((await run({path:'/OtherProject/'})).requests,0);
for(const configuration of [{...config,enabled:false},{...config,measurementId:''},{...config,measurementId:'<script>'},{...config,hostname:'example.com'},{...config,pathPrefix:'/'}]) assert.equal((await run({configuration})).scripts.length,0);
assert.equal((await run({failure:true})).scripts.length,0);
const valid=await run({repeat:true});assert.equal(valid.scripts.length,1);
const commands=valid.events.filter(e=>e[0]==='config');assert.equal(commands.length,1);
assert.equal(commands[0][1],config.measurementId);
assert.equal(commands[0][2].page_location,'https://etongle.github.io/ModelDock/');
assert.equal(commands[0][2].page_referrer,'https://example.com');
assert.equal(commands[0][2].allow_ad_personalization_signals,false);
assert.equal(commands[0][2].allow_google_signals,false);
for(const file of ['website/index.html','website/guide.html','website/guide.zh-CN.html']) assert.match(await fs.readFile(file,'utf8'),/src="analytics\.js"/);
const actual=JSON.parse(await fs.readFile('website/analytics-config.json','utf8'));assert.equal(actual.enabled,false);assert.equal(actual.measurementId,'');
console.log(JSON.stringify({result:'passed',checks:['empty/invalid ID sends no analytics','local previews and other project paths excluded','network failure does not break the page','duplicate loader sends one config/pageview','query/referrer parameters excluded','advertising features disabled','all website pages include loader'],realAnalyticsRequestsSent:0}));
