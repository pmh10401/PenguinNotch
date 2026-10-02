'use strict';
const task6fs = require('node:fs');
const task6path = require('node:path');
const test=require('node:test'),assert=require('node:assert/strict');
const S=require('../penguinnotch/ui/stocks.js');
const B=require('../penguinnotch/ui/backtests.js');
const samples=require('../../Tests/Fixtures/stock-forecast-evaluation-v1.json').replayCases;
const copy=v=>structuredClone(v);
function outcomes(input){return ['1m','10m','1d'].map(i=>B.predictReplay(input,i));}
test('testTargetCannotChangePrediction',()=>{
  const a=copy(samples[0].caseData),b=copy(a);a.target.actualClose=1;b.target.actualClose=1000;
  assert.equal(B.validCase(a),true);assert.equal(B.validCase(b),true);
  assert.deepEqual(outcomes(a.input),outcomes(b.input));
  const i=a.input,session={start:i.sessionStart,end:i.sessionEnd};
  const future={...i.minutes.at(-1),end:i.cutoff+60000,open:1e9,high:1e9,low:1e9,close:1e9};
  assert.deepEqual(S.completedBars([...i.minutes,future],i.cutoff,'1m',session),i.minutes);
  assert.deepEqual(outcomes({...i,minutes:S.completedBars([...i.minutes,future],i.cutoff,'1m',session)}),outcomes(i));
  assert.equal(B.validInput({...i,minutes:[...i.minutes,future]}),false);
  assert.ok(outcomes({...i,minutes:[...i.minutes,future]}).every(o=>o.status==='skipped'&&o.forecast===null));
  const daily=B.predictReplay(i,'1d');assert.equal(daily.forecast.expectedClose,i.inputPrice);assert.equal(daily.forecast.observations,60);
  assert.equal(i.cutoff,i.sessionEnd-3600000);
});
test('public fixture parity, DST, early end, KR and zero volume',()=>{
  for(const {caseData,expected} of samples){
    assert.equal(B.validCase(caseData),true);
    for(const interval of ['1m','10m','1d']){
      const o=B.predictReplay(caseData.input,interval),e=expected[interval];assert.equal(o.status,'forecast');
      assert.equal(o.model,`GBM ${interval==='1d'?'daily':interval} zero drift v1 / replay v1`);
      assert.equal(o.forecast.expectedClose,caseData.input.inputPrice);assert.equal(o.forecast.observations,e.observations);
      for(const key of ['lowerClose','upperClose'])assert.ok(Math.abs(o.forecast[key]-e[key])<=e[key]*1e-8,key);
      assert.ok(Math.abs(o.forecast.riseProbability-e.riseProbability)<=1e-6);
    }
  }
});
test('consecutive suffix, 11 bars, over 60 returns, daily shortage and stale input',()=>{
  const i=copy(samples[0].caseData.input);
  assert.equal(B.predictReplay({...i,minutes:i.minutes.slice(-11)},'1m').forecast.observations,10);
  assert.equal(B.predictReplay({...i,minutes:i.minutes.slice(-10)},'1m').reason,'insufficient_intraday_history');
  assert.equal(B.predictReplay({...i,minutes:i.minutes.filter((_,n)=>n!==i.minutes.length-6)},'1m').reason,'insufficient_intraday_history');
  assert.equal(B.predictReplay(i,'1m').forecast.observations,329);
  assert.equal(B.predictReplay({...i,dailyCloses:i.dailyCloses.slice(0,60)},'1d').reason,'insufficient_daily_history');
  const stale={...i,minutes:i.minutes.slice(0,-3)};stale.inputBarEnd=stale.minutes.at(-1).end;stale.inputPrice=stale.minutes.at(-1).close;
  assert.equal(B.validInput(stale),false);
  const aged={...i,minutes:i.minutes.slice(0,-2)};aged.inputBarEnd=aged.minutes.at(-1).end;aged.inputPrice=aged.minutes.at(-1).close;
  assert.equal(B.validInput(aged),true);
  assert.notEqual(B.predictReplay(aged,'1d').forecast.lowerClose,S.estimate(aged.inputPrice,aged.dailyCloses.map(c=>c.price),{start:i.sessionStart,end:i.sessionEnd},aged.inputBarEnd).lowerClose);
});
test('reject invalid data and unknown fields at every case input boundary',()=>{
  const base=samples[0].caseData;
  const mutations=[c=>c.input.inputPrice=NaN,c=>c.input.previousClose=Infinity,c=>c.input.priceBasis='unadjusted',c=>c.input.minutes[0].priceBasis='unadjusted',c=>c.input.minutes[0].high=1,c=>c.input.minutes[0].volume=-1,c=>c.input.minutes[0].end+=.5,c=>c.input.minutes.push(c.input.minutes[0]),c=>c.input.dailyCloses[0].date=c.input.cutoff,c=>c.input.dailyCloses[1]=c.input.dailyCloses[0],c=>c.input.caseID='../TEST',c=>c.input.cutoff++,c=>c.input.token='fake',c=>c.token='fake',c=>c.target.token='fake',c=>c.source.token='fake',c=>c.source.minutePages[0].token='fake',c=>c.source.minutePages[0].nextBefore='junk',c=>c.target.actualClose=0];
  for(const mutate of mutations){const c=copy(base);mutate(c);assert.equal(B.validCase(c),false,mutate.toString());}
});

test('ten-minute completion, consecutive suffix and volume sum',()=>{
  const i=copy(samples[0].caseData.input);
  assert.equal(B.predictReplay({...i,minutes:i.minutes.slice(-110)},'10m').forecast.observations,10);
  assert.equal(B.predictReplay({...i,minutes:i.minutes.slice(-109)},'10m').reason,'insufficient_intraday_history');
  assert.equal(B.predictReplay({...i,minutes:i.minutes.filter((_,n)=>n!==i.minutes.length-16)},'10m').reason,'insufficient_intraday_history');
  const bars=i.minutes.slice(-10).map((b,n)=>({...b,volume:n+1})),trading={start:i.sessionStart,end:i.sessionEnd};
  const complete=S.completedBars(bars,i.cutoff,'10m',trading);
  assert.equal(complete.length,1);assert.equal(complete[0].volume,55);
  assert.equal(complete[0].open,bars[0].open);assert.equal(complete[0].close,bars[9].close);
  assert.equal(S.completedBars(bars.slice(0,-1),i.cutoff,'10m',trading).length,0);
});

test('bounded public input and browser module expose the same pure calculation',()=>{
  const fs=require('node:fs'),vm=require('node:vm'),i=copy(samples[0].caseData.input);
  assert.equal(B.validInput({...i,dailyCloses:[...i.dailyCloses,i.dailyCloses.at(-1)]}),false);
  const many=Array.from({length:1401},(_,n)=>({...i.minutes.at(-1),end:i.cutoff-1400+n}));
  assert.equal(B.validInput({...i,minutes:many}),false);
  assert.equal(B.validInput({...i,sessionStart:Number.MAX_SAFE_INTEGER+1}),false);
  const context=vm.createContext({PenguinNotchStocks:S});
  vm.runInContext(fs.readFileSync(require.resolve('../penguinnotch/ui/backtests.js'),'utf8'),context);
  assert.equal(JSON.stringify(context.PenguinNotchBacktests.predictReplay(i,'1d')),JSON.stringify(B.predictReplay(i,'1d')));
});


test('archive is a strict dedicated native IPC with byte-preserving bodies',async()=>{
  const calls=[],body=JSON.stringify(samples[0].caseData)+'\n';
  globalThis.__TAURI__={core:{invoke:async(command,args)=>{
    calls.push([command,args]);return {type:'receipt',sha256:'a'.repeat(64)};
  }}};
  assert.deepEqual(await B.archive('saveCase',{runID:'12345678-1234-1234-1234-123456789abc',body}),{type:'receipt',sha256:'a'.repeat(64)});
  assert.deepEqual(calls,[['stock_backtest_archive',{request:{action:'saveCase',runID:'12345678-1234-1234-1234-123456789abc',body}}]]);
  for(const payload of [{runID:'../bad',body},{runID:'12345678-1234-1234-1234-123456789abc',body,path:'/tmp/a'},
    {runID:'12345678-1234-1234-1234-123456789abc',body:JSON.stringify({...samples[0].caseData,token:'fake'})}])
    await assert.rejects(()=>B.archive('saveCase',payload));
  assert.equal(calls.length,1);
  globalThis.__TAURI__.core.invoke=async()=>({type:'empty'});
  await assert.rejects(()=>B.archive('saveCase',{runID:'12345678-1234-1234-1234-123456789abc',body}));
  delete globalThis.__TAURI__;
});

const runID='12345678-1234-1234-1234-123456789abc';
function manifest(){const i=samples[0].caseData.input;return {version:1,runID,createdAt:1790366460000,collectionStartedAt:1790366460000,
  collectionCompletedAt:null,protocolVersion:'replay-v1',codeVersion:'task3-test',priceBasis:B.PRICE_BASIS,cutoffMinutes:60,sessions:20,
  symbols:[i.stockID],models:['GBM daily zero drift v1 / replay v1'],status:'ready',cases:[{caseID:i.caseID,stockID:i.stockID,tradingDay:i.tradingDay,
    status:'pending',inputSHA256:null,resultSHA256:null,reason:null}]};}
function result(){const i=samples[0].caseData.input;return {version:1,caseID:i.caseID,inputSHA256:'a'.repeat(64),calculationVersion:'replay-v1',computedAt:1790366460000,
  outcomes:[B.predictReplay(i,'1d')]};}
test('archive whitelist covers every manifest/result nesting level, versions and numeric bounds',async()=>{
  const m=manifest(),r=result();assert.equal(B.validManifest(m),true);assert.equal(B.validResult(r),true);
  for(const field of ['accountSeq','token','quantity']){
    for(const select of [m=>m,m=>m.cases[0]]){const bad=copy(m);select(bad)[field]='synthetic';assert.equal(B.validManifest(bad),false);}
    for(const select of [r=>r,r=>r.outcomes[0],r=>r.outcomes[0].forecast]){const bad=copy(r);select(bad)[field]='synthetic';assert.equal(B.validResult(bad),false);}
  }
  for(const mutate of [m=>m.version=2,m=>m.runID='../x',m=>m.models=['unknown'],m=>m.sessions=21,m=>m.createdAt=.5,m=>m.symbols.push(m.symbols[0]),
    m=>m.cases[0].status='saved',m=>m.cases[0].caseID='../history',m=>m.cases[0].tradingDay='2026-02-30',m=>delete m.collectionCompletedAt,
    m=>m.codeVersion='\ud800']){const bad=copy(m);mutate(bad);assert.equal(B.validManifest(bad),false,mutate.toString());}
  for(const mutate of [r=>r.version=2,r=>r.caseID='../x',r=>r.inputSHA256='junk',r=>r.calculationVersion='v2',r=>r.computedAt=Number.MAX_SAFE_INTEGER+1,
    r=>r.outcomes[0].model='unknown',r=>r.outcomes[0].forecast.riseProbability=2,r=>r.outcomes[0].forecast.lowerClose=0,
    r=>r.outcomes[0].forecast.observations=61,r=>r.outcomes.push(r.outcomes[0]),r=>r.outcomes[0].reason='fake',r=>delete r.outcomes[0].reason]){
    const bad=copy(r);mutate(bad);assert.equal(B.validResult(bad),false,mutate.toString());
  }
  let calls=0;globalThis.__TAURI__={core:{invoke:async()=>{calls++;return {type:'empty'};}}};
  for(const [action,payload] of [['list',{path:'/tmp/x'}],['create',{manifest:{...m,token:'synthetic'}}],['updateProgress',{runID,entries:[{...m.cases[0],quantity:1}],status:'paused'}],
    ['saveResult',{runID,body:JSON.stringify({...r,token:'synthetic'})}],['saveCase',{runID,body:JSON.stringify(samples[0].caseData)+' '.repeat(2*1024*1024)}],
    ['loadCase',{runID,caseID:'us_TEST_2026-02-30'}],['saveCase',{runID,body:'\ud800'}]])await assert.rejects(()=>B.archive(action,payload));
  assert.equal(calls,0);delete globalThis.__TAURI__;
});
test('each archive action checks its native tagged reply and preserves load bytes',async()=>{
  const m=manifest(),r=result(),body=JSON.stringify(samples[0].caseData)+' \n',resultBody=JSON.stringify(r)+'\n',calls=[];
  globalThis.__TAURI__={core:{invoke:async(command,{request})=>{
    calls.push(command);switch(request.action){
      case 'list':return {type:'manifests',manifests:[m]};case 'loadManifest':return {type:'manifest',manifest:m};
      case 'loadCase':return {type:'body',body,sha256:'a'.repeat(64)};
      case 'loadResult':return {type:'body',body:resultBody,sha256:'b'.repeat(64)};
      case 'saveResult':return {type:'receipt',sha256:'b'.repeat(64)};default:return {type:'empty'};
    }
  }}};
  assert.equal((await B.archive('list')).manifests.length,1);await B.archive('create',{manifest:m});
  assert.deepEqual((await B.archive('loadManifest',{runID})).manifest,m);
  assert.equal((await B.archive('loadCase',{runID,caseID:m.cases[0].caseID})).body,body);
  assert.equal((await B.archive('loadResult',{runID,caseID:m.cases[0].caseID})).body,resultBody);
  await B.archive('saveResult',{runID,body:resultBody});await B.archive('updateProgress',{runID,entries:m.cases,status:'paused'});
  assert.ok(calls.every(c=>c==='stock_backtest_archive'));
  for(const bad of [{type:'empty',token:'fake'},{type:'receipt',sha256:'bad'}, {type:'body',body:null,sha256:'a'.repeat(64)},
    {type:'body',body:JSON.stringify({...r,caseID:'us_OTHER_2026-09-25'}),sha256:'a'.repeat(64)}]){
    globalThis.__TAURI__.core.invoke=async()=>bad;await assert.rejects(()=>B.archive('loadResult',{runID,caseID:m.cases[0].caseID}));
  }
  globalThis.__TAURI__.core.invoke=async()=>({type:'body',body:null,sha256:null});assert.equal((await B.archive('loadResult',{runID,caseID:m.cases[0].caseID})).body,null);
  delete globalThis.__TAURI__;
  await assert.rejects(()=>B.archive('list'));
});
test('independent target-proof/input metadata pages are valid but still bounded to eight',()=>{
  const c=copy(samples[0].caseData);c.source.minutePages.push({before:'2026-09-25T20:00:00Z',nextBefore:'2026-09-25T19:59:00Z',fetchedAt:c.target.fetchedAt});
  assert.equal(B.validCase(c),true);c.source.minutePages=Array(9).fill(c.source.minutePages[0]);assert.equal(B.validCase(c),false);
});


function duplicateJSON(body,key,value,first,escaped=false){
  const k=escaped?'"\\u'+key.charCodeAt(0).toString(16).padStart(4,'0')+key.slice(1)+'"':JSON.stringify(key);
  const member=k+':'+JSON.stringify(value);
  return first?'{'+member+','+body.slice(1):body.slice(0,-1)+','+member+'}';
}
test('duplicate decoded raw keys cannot reach native IPC or hide in raw native replies',async()=>{
  const c=samples[0].caseData,r=result(),body=JSON.stringify(c),rb=JSON.stringify(r);
  let calls=0;globalThis.__TAURI__={core:{invoke:async()=>{calls++;return {type:'receipt',sha256:'a'.repeat(64)};}}};
  for(const first of [false,true])for(const escaped of [false,true]){
    for(const field of ['token','accountSeq','quantity']){
      const raw=duplicateJSON(body,'source',{...c.source,[field]:'SYNTHETIC_ONLY'},first,escaped);
      assert.equal(Object.keys(JSON.parse(raw)).length,Object.keys(c).length);
      await assert.rejects(()=>B.archive('saveCase',{runID,body:raw}));
    }
    const outcome={...r.outcomes[0],forecast:{...r.outcomes[0].forecast,quantity:'SYNTHETIC_ONLY'}};
    const rawResult=duplicateJSON(rb,'outcomes',[outcome],first,escaped);
    await assert.rejects(()=>B.archive('saveResult',{runID,body:rawResult}));
    const rawInput=duplicateJSON(JSON.stringify(c.input),'caseID',c.input.caseID,first,escaped);
    const nestedCase=body.replace(JSON.stringify(c.input),rawInput);
    await assert.rejects(()=>B.archive('saveCase',{runID,body:nestedCase}));
    const forecast=JSON.stringify(r.outcomes[0].forecast);
    const rawForecast=duplicateJSON(forecast,'observations',60,first,escaped);
    await assert.rejects(()=>B.archive('saveResult',{runID,body:rb.replace(forecast,rawForecast)}));
  }
  assert.equal(calls,0);
  globalThis.__TAURI__.core.invoke=async()=>({type:'body',body:duplicateJSON(body,'source',c.source,false,true),sha256:'a'.repeat(64)});
  await assert.rejects(()=>B.archive('loadCase',{runID,caseID:c.input.caseID}));
  delete globalThis.__TAURI__;
});
test('raw scan handles escaped string punctuation and whitespace before decoded aliases',async()=>{
  const c=copy(samples[0].caseData);
  c.source.minutePages[0].before='2026-09-25T19:00:00.000Z';
  const body=JSON.stringify(c).replace('"provider":','"pro\\u0076ider" \n\t:');
  let calls=0;globalThis.__TAURI__={core:{invoke:async()=>{calls++;return {type:'receipt',sha256:'a'.repeat(64)};}}};
  await B.archive('saveCase',{runID,body});
  const alias=body.replace('"pro\\u0076ider" \n\t:', '"provider":"toss","pro\\u0076ider" \n\t:');
  await assert.rejects(()=>B.archive('saveCase',{runID,body:alias}));
  // Invalid semantic values must still be refused after strings with escaped quotes/braces are scanned.
  const quoted=JSON.stringify({...c,source:{...c.source,provider:'x\\"}:[{'}});
  await assert.rejects(()=>B.archive('saveCase',{runID,body:quoted}));
  assert.equal(calls,1);delete globalThis.__TAURI__;
});


// Public-only transport + temporary native-archive stand-in; never delegates to the real IPC/network.
function collectorFixture(t,{market='us',mode='',dailyCount=61}={}){
 const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'penguin-backtest-'));t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
 let clock=Date.parse('2026-09-25T22:00:00Z');const calls=[],writes=[],manifests=new Map();
 const previous=day=>{let date=new Date(day+'T12:00:00Z');do{date.setUTCDate(date.getUTCDate()-1);}while([0,6].includes(date.getUTCDay()));return date.toISOString().slice(0,10);};
 const session=(day,m=market)=>{const midnight=S.timestamp(day,m);return {start:midnight+(m==='kr'?9:9.5)*3600000,end:midnight+(m==='kr'?15.5:16)*3600000};};
 const calendar=(day,m)=>{const body=d=>{const r=session(d,m),regularMarket={startTime:new Date(r.start).toISOString(),endTime:new Date(r.end).toISOString()};return m==='kr'?{integrated:{regularMarket}}:{regularMarket};};return {today:body(day),previousBusinessDay:body(previous(day)),nextBusinessDay:null};};
 const bar=(end,price)=>({end,open:price,high:price+1,low:price-1,close:price,volume:0});
 const invoke=async(command,{request})=>{
  assert.equal(command,'stock_backtest_archive');writes.push([request.action,clock]);
  const id=request.runID,m=manifests.get(id),file=request.caseID&&path.join(directory,id,request.caseID+'.json');
  if(request.action==='list')return {type:'manifests',manifests:[...manifests.values()].map(copy)};
  if(request.action==='create'){assert.ok(B.validManifest(request.manifest));const v=copy(request.manifest);manifests.set(v.runID,v);fs.mkdirSync(path.join(directory,v.runID));return {type:'empty'};}
  if(request.action==='loadManifest'){assert.ok(m);return {type:'manifest',manifest:copy(m)};}
  if(request.action==='loadCase'){if(!fs.existsSync(file))throw Error('Invalid replay archive');const body=fs.readFileSync(file,'utf8');return {type:'body',body,sha256:crypto.createHash('sha256').update(body).digest('hex')};}
  if(request.action==='saveCase'){assert.ok(B.validCase(JSON.parse(request.body)));const c=JSON.parse(request.body),f=path.join(directory,id,c.input.caseID+'.json');if(fs.existsSync(f))assert.equal(fs.readFileSync(f,'utf8'),request.body);else fs.writeFileSync(f,request.body);return {type:'receipt',sha256:crypto.createHash('sha256').update(request.body).digest('hex')};}
  if(request.action==='loadResult'){const f=path.join(directory,id,request.caseID+'.result.json');if(!fs.existsSync(f))return {type:'body',body:null,sha256:null};const body=fs.readFileSync(f,'utf8');return {type:'body',body,sha256:crypto.createHash('sha256').update(body).digest('hex')};}
  if(request.action==='saveResult'){const r=JSON.parse(request.body);assert.ok(B.validResult(r));const c=fs.readFileSync(path.join(directory,id,r.caseID+'.json'),'utf8');assert.equal(r.inputSHA256,crypto.createHash('sha256').update(c).digest('hex'));assert.deepEqual(r.outcomes.map(o=>o.model).sort(),[...m.models].sort());const f=path.join(directory,id,r.caseID+'.result.json');if(fs.existsSync(f))assert.equal(fs.readFileSync(f,'utf8'),request.body);else fs.writeFileSync(f,request.body);return {type:'receipt',sha256:crypto.createHash('sha256').update(request.body).digest('hex')};}
  if(request.action==='updateProgress'){for(const e of request.entries)if(e.resultSHA256!==null){const f=path.join(directory,id,e.caseID+'.result.json');assert.equal(e.resultSHA256,crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex'));}m.cases=copy(request.entries);m.status=request.status;if(m.status==='completed')m.collectionCompletedAt=clock;assert.ok(B.validManifest(m));return {type:'empty'};}
  throw Error('Forbidden fake IPC action');
 };
 const stockRequest=async request=>{
  calls.push({request:copy(request),at:clock});
  if(request.type==='calendar')return {type:'calendar',value:calendar(request.date,request.market),requestedAt:clock};
  assert.equal(request.type,'candles');assert.equal(request.count,200);assert.equal(request.adjusted,true);assert.ok(['1m','1d'].includes(request.interval));
  assert.ok(B.validManifest([...manifests.values()][0]),'all dates frozen before candles');
  const bound=Date.parse(request.before),day=S.dayKey(bound,request.stock.market),r=session(day,request.stock.market);
  if(request.interval==='1d'){
   let d=day;const values=[bar(S.timestamp(d,request.stock.market),100)];
   for(let n=0;n<dailyCount;n++){d=previous(d);if(mode!=='previous-gap'||n!==0)values.push(bar(S.timestamp(d,request.stock.market),100+(n+1)/100));}
   return {type:'candles',values,nextBefore:null,requestedAt:clock};
  }
  const values=[];for(let end=bound;end>=r.start+60000&&values.length<(mode==='short-pages'?150:200);end-=['bounds','short-pages'].includes(mode)?1000:60000)values.push(bar(end,100+(r.end-end)/60000*.001));
  if(mode==='mismatch'&&bound===r.end)values[0]=bar(bound,101);
  if(mode==='proof-missing'&&bound===r.end)values.shift();
  let nextBefore=values.at(-1).end>r.start+60000?new Date(values.at(-1).end).toISOString():null;
  if(mode==='cursor'&&bound===r.end-3600000)nextBefore=request.before;
  if(mode==='conflict'&&bound!==r.end&&bound!==r.end-3600000)values[0]=bar(bound,102);
  if(mode==='partial'){values.splice(11);nextBefore=null;}
  return {type:'candles',values,nextBefore,requestedAt:clock};
 };
 const store=new B.BacktestStore({invoke,stockRequest,now:()=>clock,sleep:async ms=>{clock+=ms;}});
 return {store,invoke,stockRequest,calls,writes,manifests,directory,session,previous,calendar,bar,now:()=>clock,sleep:async ms=>{clock+=ms;},stock:{symbol:market==='kr'?'005930':'AAPL',market,visible:false}};
}
test('testCollectorsUseOnlyFrozenPublicInputs',async t=>{
 const f=collectorFixture(t);await f.store.ready;assert.equal(f.calls.length,0);await f.store.start({symbols:[f.stock],sessions:60});
 const m=f.store.runs[0];assert.equal(m.status,'completed');assert.equal(m.cases.length,60);assert.ok(m.cases.every(e=>e.status==='saved'));
 assert.equal(f.calls.filter(c=>c.request.type==='calendar').length,60);assert.equal(f.calls.filter(c=>c.request.interval==='1d').length,60);
 for(let n=1;n<f.calls.length;n++)assert.ok(f.calls[n].at-f.calls[n-1].at>=250);
 const fs=require('node:fs'),path=require('node:path');
 for(const e of m.cases){const c=JSON.parse(fs.readFileSync(path.join(f.directory,m.runID,e.caseID+'.json'),'utf8'));
  assert.equal(c.source.minutePages.length,3);assert.equal(c.input.minutes.length,330);assert.ok(c.input.minutes.every(b=>b.end<=c.input.cutoff));
  assert.equal(c.input.previousClose,100.01);assert.equal(S.dayKey(c.input.dailyCloses[0].date,'us'),f.previous(e.tradingDay));
  assert.equal(c.target.actualClose,100);assert.equal(c.input.dailyCloses.length,61);assert.ok(!c.input.minutes.some(b=>b.end===c.input.sessionEnd));
 }
 const before=f.calls.length,bytes=m.cases.map(e=>fs.readFileSync(path.join(f.directory,m.runID,e.caseID+'.json')));
 await f.store.resume(m.runID);assert.equal(f.calls.length,before);m.cases.forEach((e,n)=>assert.deepEqual(fs.readFileSync(path.join(f.directory,m.runID,e.caseID+'.json')),bytes[n]));
 assert.equal(f.store.progress.completed,60);assert.equal(f.store.activeRunID,null);
});
test('testSessionMismatchIsSkipped',async t=>{
 const f=collectorFixture(t,{market:'kr',mode:'mismatch'});await f.store.start({symbols:[f.stock],sessions:20});
 assert.ok(f.store.runs[0].cases.every(e=>e.status==='skipped'&&e.reason==='session_target_mismatch'&&e.inputSHA256===null));
 assert.equal(f.calls.filter(c=>c.request.interval==='1m').length,20);assert.equal(f.writes.filter(c=>c[0]==='saveCase').length,0);
});
test('previous business day gap skips common input but older history shortage is model-specific',async t=>{
 const gap=collectorFixture(t,{mode:'previous-gap'});await gap.store.start({symbols:[gap.stock],sessions:20});
 assert.ok(gap.store.runs[0].cases.every(e=>e.reason==='missing_previous_close'));assert.equal(gap.calls.filter(c=>c.request.interval==='1m').length,0);
 const short=collectorFixture(t,{dailyCount:2,mode:'partial'});await short.store.start({symbols:[short.stock],sessions:20});
 const m=short.store.runs[0],e=m.cases[0],c=JSON.parse((await short.invoke('stock_backtest_archive',{request:{action:'loadCase',runID:m.runID,caseID:e.caseID}})).body);
 assert.equal(e.status,'saved');assert.equal(B.predictReplay(c.input,'1d').reason,'insufficient_daily_history');
 assert.equal(B.predictReplay(c.input,'1m').status,'forecast');assert.equal(B.predictReplay(c.input,'10m').reason,'insufficient_intraday_history');
});
test('inclusive duplicates dedup but conflicting rows and repeating cursors skip',async t=>{
 for(const [mode,reason]of [['cursor','repeated_cursor'],['conflict','conflicting_duplicate']]){
  const f=collectorFixture(t,{mode});await f.store.start({symbols:[f.stock],sessions:20});assert.ok(f.store.runs[0].cases.every(e=>e.reason===reason));
 }
});
test('cancel, revisions, auth pauses, double starts, late replies and zero-query orphan resume',async t=>{
 const f=collectorFixture(t);await f.store.ready;let release,entered;
 const waiting=new Promise(resolve=>entered=resolve),reply=new Promise(resolve=>release=resolve);
 const store=new B.BacktestStore({invoke:f.invoke,stockRequest:async r=>{const v=await f.stockRequest(r);if(r.type==='candles'){entered();await reply;}return v;},now:f.now,sleep:f.sleep});
 const active=store.start({symbols:[f.stock],sessions:20});await waiting;
 await assert.rejects(()=>store.start({symbols:[f.stock],sessions:20}),/already_running/);
 store.configure({revision:1});release();await assert.rejects(()=>active,/cancelled/);
 assert.equal(store.runs[0].status,'paused');assert.equal(f.writes.filter(w=>w[0]==='saveCase').length,0);
 // Auth failures keep the frozen pending list, never skip it or automatically resume.
 const auth=new B.BacktestStore({invoke:f.invoke,stockRequest:async()=>{throw Error('Stock HTTP 401');},now:f.now,sleep:f.sleep});
 await assert.rejects(()=>auth.resume(store.runs[0].runID));assert.equal(auth.errorMessage,'authentication_paused');assert.equal(auth.runs.at(-1).status,'paused');
 // Cancel after native placement: orphan bytes are retained and linked on explicit resume.
 const g=collectorFixture(t);let owner;
 const invoke=async(command,args)=>{const out=await g.invoke(command,args);if(args.request.action==='saveCase')owner.cancel();return out;};
 owner=new B.BacktestStore({invoke,stockRequest:g.stockRequest,now:g.now,sleep:g.sleep});await assert.rejects(()=>owner.start({symbols:[g.stock],sessions:20}));
 const orphan=owner.runs[0],first=orphan.cases[0];assert.equal(first.status,'pending');
 const before=g.calls.length,bytes=(await g.invoke('stock_backtest_archive',{request:{action:'loadCase',runID:orphan.runID,caseID:first.caseID}})).body;
 const resumed=new B.BacktestStore({invoke:g.invoke,stockRequest:g.stockRequest,now:g.now,sleep:g.sleep});await resumed.resume(orphan.runID);
 assert.equal(g.calls.length-before,19*5);assert.ok(g.calls.slice(before,before+19).every(c=>c.request.type==='calendar')); // 19 pending dates: calendar + daily + 3 minute pages; orphan queried zero times.
 assert.equal((await g.invoke('stock_backtest_archive',{request:{action:'loadCase',runID:orphan.runID,caseID:first.caseID}})).body,bytes);
});

test('raw rows include proof, reserve the full next page and enforce eight-page cap',async t=>{
 for(const [mode,pages]of [['bounds',7],['short-pages',8]]){
  const f=collectorFixture(t,{mode});await f.store.start({symbols:[f.stock],sessions:20});
  const m=f.store.runs[0],c=JSON.parse((await f.invoke('stock_backtest_archive',{request:{action:'loadCase',runID:m.runID,caseID:m.cases[0].caseID}})).body);
  assert.equal(c.source.minutePages.length,pages);assert.equal(f.calls.length,20*(pages+2));assert.ok(c.input.minutes.length<=1400);
 }
 const missing=collectorFixture(t,{mode:'proof-missing'});await missing.store.start({symbols:[missing.stock],sessions:20});assert.ok(missing.store.runs[0].cases.every(e=>e.reason==='session_target_mismatch'));
});
test('observable owner covers calendar freeze, subscribe/reopen and late init listing',async t=>{
 const f=collectorFixture(t);let release,entered;const waiting=new Promise(resolve=>entered=resolve),reply=new Promise(resolve=>release=resolve);
 const store=new B.BacktestStore({invoke:f.invoke,stockRequest:async r=>{entered();await reply;return f.stockRequest(r);},now:f.now,sleep:f.sleep});
 const notifications=[],unsubscribe=store.subscribe(s=>notifications.push({id:s.activeRunID,busy:s.busy,progress:{...s.progress}}));
 const running=store.start({symbols:[f.stock],sessions:60});await waiting;
 assert.ok(store.activeRunID);assert.ok(store.busy);assert.equal(store.progress.total,60);const id=store.activeRunID;
 let reopenedID;const reopened=store.subscribe(s=>{reopenedID=s.activeRunID;});assert.equal(reopenedID,id);
 assert.ok(notifications.some(s=>s.id===id&&s.busy));store.cancel();release();await assert.rejects(()=>running,/cancelled/);
 assert.equal(store.activeRunID,null);assert.equal(store.busy,false);assert.equal(notifications.at(-1).id,null);assert.equal(f.manifests.size,0);unsubscribe();reopened();
 const g=collectorFixture(t,{mode:'partial'});let listResolve;
 const list=new Promise(resolve=>listResolve=resolve),invoke=async(c,a)=>a.request.action==='list'?list:g.invoke(c,a);
 const raced=new B.BacktestStore({invoke,stockRequest:g.stockRequest,now:g.now,sleep:g.sleep});await raced.start({symbols:[g.stock],sessions:20});
 listResolve({type:'manifests',manifests:[]});await raced.ready;assert.equal(raced.runs.length,1);assert.equal(raced.runs[0].status,'completed');
});
test('native public adapter bypasses display gate and retains full offsets/duplicates',async t=>{
 const f=collectorFixture(t,{market:'kr'}),native=[];
 const invoke=async(command,args)=>{
  if(command!=='stock_request')return f.invoke(command,args);
  const r=args.request;native.push(copy(r));assert.ok(['calendar','candles'].includes(r.kind));
  const reply=await f.stockRequest(r.kind==='calendar'?{type:'calendar',market:r.market,date:r.date}:{type:'candles',stock:{market:r.market,symbol:r.symbol},interval:r.interval,before:r.before,count:r.count,adjusted:r.adjusted});
  if(reply.type==='calendar')return {data:{result:reply.value},fetchedAt:reply.requestedAt};
  const candles=reply.values.map(b=>({timestamp:new Date(b.end).toISOString(),openPrice:String(b.open),highPrice:String(b.high),lowPrice:String(b.low),closePrice:String(b.close),volume:String(b.volume)}));
  return {data:{result:{candles,nextBefore:reply.nextBefore}},fetchedAt:reply.requestedAt};
 };
 const store=new B.BacktestStore({invoke,now:f.now,sleep:f.sleep});await store.start({symbols:[f.stock],sessions:20});
 assert.ok(store.runs[0].cases.every(e=>e.status==='saved'));assert.equal(native.length,101);assert.ok(native.every(r=>r.kind==='calendar'||r.interval!=='10m'&&r.adjusted===true&&r.count===200));
});

test('manifest session limit is per market',()=>{
 const m=manifest();m.symbols=['us:AAPL','kr:005930'];m.cases=[];
 const entry=(stockID,n)=>{const tradingDay=`2026-09-${String(n+1).padStart(2,'0')}`;return {caseID:stockID.replace(':','_')+'_'+tradingDay,stockID,tradingDay,status:'pending',inputSHA256:null,resultSHA256:null,reason:null};};
 for(let n=0;n<20;n++)m.cases.push(entry('us:AAPL',n),entry('kr:005930',n+1));
 assert.equal(m.cases.length,40);assert.equal(new Set(m.cases.map(e=>e.tradingDay)).size,21);assert.equal(B.validManifest(m),true);
 const same=copy(m);same.symbols.push('us:MSFT');same.cases.push(entry('us:MSFT',20));assert.ok(same.cases.length<=same.symbols.length*same.sessions);assert.equal(B.validManifest(same),false);
 const total=copy(m);total.cases.push(entry('us:AAPL',20));assert.ok(total.cases.length>total.symbols.length*total.sessions);assert.equal(B.validManifest(total),false);
 const identity=copy(m);identity.cases[0].stockID='kr:005930';assert.equal(B.validManifest(identity),false);
 const hash=copy(m);hash.cases[0].status='saved';hash.cases[0].inputSHA256='invalid';assert.equal(B.validManifest(hash),false);
 const duplicate=copy(m);duplicate.cases[1]=copy(duplicate.cases[0]);assert.equal(B.validManifest(duplicate),false);
});
test('collector freezes divergent market calendars',async t=>{
 const f=collectorFixture(t,{mode:'partial',dailyCount:2}),stocks=[{symbol:'AAPL',market:'us',visible:false},{symbol:'005930',market:'kr',visible:false}];
 let clock=Date.parse('2026-09-25T19:30:00Z'),candles=0,store;
 const dates=latest=>{const out=[];for(let n=0;n<20;n++){out.push(latest);latest=f.previous(latest);}return out;};
 const expected={us:dates('2026-09-24'),kr:dates('2026-09-25')};
 store=new B.BacktestStore({invoke:f.invoke,now:()=>clock,sleep:async ms=>{clock+=ms;},stockRequest:async request=>{
  if(request.type==='candles'){
   candles++;const m=store.runs[0];assert.ok(m);assert.equal(new Set(m.cases.map(e=>e.tradingDay)).size,21);
   for(const stock of stocks)assert.deepEqual(m.cases.filter(e=>e.stockID===S.stockID(stock)).map(e=>e.tradingDay),expected[stock.market]);
  }
  const reply=await f.stockRequest(request);reply.requestedAt=clock;return reply;
 }});
 await store.start({symbols:stocks,sessions:20});const m=store.runs[0];assert.equal(m.status,'completed');assert.equal(m.cases.length,40);
 assert.equal(candles,120);assert.ok(m.cases.every(e=>e.status==='saved'));assert.deepEqual((await f.invoke('stock_backtest_archive',{request:{action:'loadManifest',runID:m.runID}})).manifest.cases,m.cases);
});

test('testIncompleteCohortNeverScoresAsZero',()=>{
 const runID='12345678-1234-1234-1234-123456789abc',hash='a'.repeat(64),a=copy(samples[0].caseData),b=copy(samples[1].caseData);b.input.dailyCloses=b.input.dailyCloses.slice(0,2);
 const rows=[a,b].flatMap(c=>B.replayRows(runID,c,replayResult(c,hash,['1d','1m']),hash)),models=[...new Set(rows.map(r=>r.model))];
 const comparison=S.evaluationComparison(rows,models);assert.equal(comparison.pairedCount,1);
 assert.equal(comparison.rows.find(r=>r.model.includes('daily')).available.evaluated,1);assert.equal(comparison.rows.find(r=>r.model.includes('1m')).available.evaluated,2);
 assert.ok(comparison.rows.every(r=>r.available.mape===r.available.baselineMAPE));assert.equal(S.evaluationComparison(rows,[models[1]]).pairedCount,2);
 const pair=rows.slice(0,2);for(const patch of [{actualClose:null},{actualClose:1},{inputKey:'different-hash'},{capture:'manual'},{source:'recorded'}])assert.equal(S.evaluationComparison([pair[0],{...pair[1],...patch}],models).pairedCount,0);
 const baseline={...pair[0],expectedClose:pair[0].inputPrice,lowerClose:null,upperClose:null,riseProbability:null};assert.equal(S.evaluationMetrics([baseline]).brier,null);assert.equal(S.evaluationMetrics([baseline]).coverage,null);
 assert.equal(B.filteredEvaluationRows(rows,{market:'kr'}).length,0);assert.equal(B.filteredEvaluationRows(rows,{day:a.input.tradingDay,capture:'replay',source:'replay'}).length,2);
});
test('collector persists results before saved',async t=>{
 const f=collectorFixture(t,{mode:'partial',dailyCount:2});await f.store.start({symbols:[f.stock],sessions:20});
 const m=f.store.runs[0];assert.ok(m.cases.every(e=>e.resultSHA256!==null),'source-only cases must not be presented as scored');
 const loaded=await Promise.all(m.cases.map(e=>f.store.loadCase(m.runID,e.caseID))),summary=B.replaySummary(m,loaded,m.models);
 assert.equal(summary.requested,20);assert.equal(summary.acquired,20);assert.equal(summary.pending,0);assert.equal(summary.skipped,0);assert.equal(summary.unavailable,0);assert.equal(summary.stockCount,1);assert.equal(summary.dayCount,20);assert.equal(summary.comparison.pairedCount,0);
 assert.equal(summary.models.find(m=>m.model.includes('1m')).success,20);assert.equal(summary.models.find(m=>m.model.includes('daily')).skipped,20);
 const rows=B.replayRows(m.runID,loaded[0].caseData,loaded[0].result,loaded[0].inputSHA256),csv=readCSV(B.evaluationCSV(rows,S.evaluationMetrics(rows),{[rows[0].referenceID]:loaded[0].rawDetail}));
 const records=csv.slice(1).map(r=>Object.fromEntries(csv[0].map((k,n)=>[k,r[n]])));assert.ok(records.some(r=>r.type==='outcome'&&r.reason==='insufficient_daily_history'));assert.ok(records.some(r=>r.type==='outcome'&&r.reason==='insufficient_intraday_history'));
 const pending=copy(m);pending.status='paused';pending.collectionCompletedAt=null;pending.cases=pending.cases.map(e=>({...e,status:'pending',inputSHA256:null,resultSHA256:null}));const waiting=B.replaySummary(pending,loaded,m.models);assert.equal(waiting.rows.length,0);assert.equal(waiting.pending,20);assert.ok(waiting.models.every(m=>m.metrics.mape===null));
 assert.equal(B.replaySummary(m,loaded,m.models,{market:'kr'}).requested,0);
});
function replayResult(c,hash='a'.repeat(64),models=['1d','1m','10m']){
 return {version:1,caseID:c.input.caseID,inputSHA256:hash,calculationVersion:'replay-v1',computedAt:c.target.fetchedAt,outcomes:models.map(i=>B.predictReplay(c.input,i))};
}
function readCSV(body){
 const rows=[];let row=[],value='',quoted=false;
 for(let i=0;i<body.length;i++){const c=body[i];if(c==='"'){if(quoted&&body[i+1]==='"'){value+='"';i++;}else quoted=!quoted;}
 else if(!quoted&&c===','){row.push(value);value='';}else if(!quoted&&c==='\r'&&body[i+1]==='\n'){row.push(value);rows.push(row);row=[];value='';i++;}else value+=c;}
 assert.equal(quoted,false);return rows;
}
test('replay target-only scoring, unsupported bindings and exact public fixture aggregates',()=>{
 const runID='12345678-1234-1234-1234-123456789abc',hash='a'.repeat(64);
 for(const sample of samples){const c=copy(sample.caseData),r=replayResult(c,hash),rows=B.replayRows(runID,c,r,hash);
  assert.equal(rows.length,3);assert.ok(rows.every(row=>row.expectedClose===c.input.inputPrice));
  for(let n=0;n<3;n++){const expected=sample.expected[['1d','1m','10m'][n]],row=rows[n],m=S.evaluationMetrics([row]);
   assert.ok(Math.abs(row.lowerClose-expected.lowerClose)<=expected.lowerClose*1e-8);assert.ok(Math.abs(row.upperClose-expected.upperClose)<=expected.upperClose*1e-8);
   assert.ok(Math.abs(row.riseProbability-expected.riseProbability)<=1e-6);assert.equal(m.mape,m.baselineMAPE);
   assert.ok(Math.abs(m.brier-(expected.riseProbability-+(c.target.actualClose>c.input.previousClose))**2)<=1e-6);
   assert.ok(Math.abs(m.meanWidthPercent-(expected.upperClose-expected.lowerClose)/c.input.inputPrice*100)<=1e-6);
  }
  const changed=copy(c);changed.target.actualClose=1;assert.deepEqual(replayResult(changed,hash).outcomes,r.outcomes);
  assert.notEqual(S.evaluationMetrics(B.replayRows(runID,changed,r,hash)).mape,S.evaluationMetrics(rows).mape);
  for(const patch of [{version:2},{calculationVersion:'replay-v2'},{inputSHA256:'b'.repeat(64)},{caseID:'us_OTHER_2026-09-25'},{outcomes:[{...r.outcomes[0],model:'unsupported'}]}])assert.throws(()=>B.replayRows(runID,c,{...r,...patch},hash));
  assert.throws(()=>B.replayRows('invalid',c,r,hash));assert.throws(()=>B.replayRows(runID,{...c,version:2},r,hash));
 }
});
test('replay calibration, bounds, denominator exclusions and numeric CSV roundtrip',()=>{
 const runID='12345678-1234-1234-1234-123456789abc',c=samples[0].caseData;
 const base=B.replayRows(runID,c,replayResult(c),'a'.repeat(64))[0];
 const rows=[{...base,referenceID:' =PUBLIC("name")',inputKey:'one',riseProbability:.5,actualClose:base.previousClose,lowerClose:base.previousClose,upperClose:base.previousClose},
  {...base,inputKey:'two',riseProbability:1,actualClose:base.upperClose},
  {...base,inputKey:'three',riseProbability:0,actualClose:base.lowerClose},
  {...base,inputKey:'four',riseProbability:null,lowerClose:null,upperClose:null}];
 const m=S.evaluationMetrics(rows);assert.equal(m.evaluated,4);assert.equal(m.directionCount,2);assert.equal(m.coverage,100);
 const bins=B.evaluationCalibration(rows);assert.equal(bins.reduce((n,b)=>n+b.count,0),3);assert.equal(bins.find(b=>b.id===5).rises,0);
 assert.deepEqual(bins,S.probabilityBinsForRows(rows.slice(0,3)));assert.ok(bins.every(b=>b.lower>=0&&b.upper<=1));
 const huge=S.evaluationMetrics([{...base,inputPrice:1,expectedClose:1000,actualClose:1,lowerClose:1,upperClose:1000}]);assert.equal(huge.mape,99900);assert.equal(huge.meanWidthPercent,99900);assert.ok(huge.brier>=0&&huge.brier<=1);
 const raw='{"name":"=PUBLIC\\nname", "precise":100.000000000000000000001,"reason":"insufficient_daily_history"}\n';
 const exported=B.evaluationCSV([{...rows[0],expectedClose:-5,capture:'-manual'},...rows.slice(1)],S.evaluationMetrics(rows),{[rows[0].referenceID]:raw,'skip-only':'{"status":"skipped","reason":"missing_previous_close"}'});
 const [head,...values]=readCSV(exported),records=values.map(v=>Object.fromEntries(head.map((k,n)=>[k,v[n]])));
 const forecast=records.find(r=>r.type==='forecast');assert.equal(forecast.expectedClose,'-5');assert.equal(forecast.capture,"'-manual");assert.equal(forecast.referenceID,"' =PUBLIC(\"name\")");assert.equal(forecast.rawDetail,raw);
 assert.equal(forecast.source,'replay');assert.equal(forecast.inputKey,'one');assert.equal(forecast.priceBasis,B.PRICE_BASIS);assert.ok(forecast.limitation);
 const unsafe=readCSV(B.evaluationCSV([{...rows[0],expectedClose:'=PUBLIC("text")'}],S.evaluationMetrics(rows),{}));assert.equal(unsafe[1][head.indexOf('expectedClose')],"'=PUBLIC(\"text\")");
 const totals=records.find(r=>r.type==='metrics');assert.equal(totals.directionCount,'2');assert.equal(totals.probabilityCount,'3');assert.equal(totals.rangeCount,'3');
 assert.ok(records.some(r=>r.referenceID==='skip-only'&&r.rawDetail.includes('missing_previous_close')));
});
test('restart reuses orphan original result, cancel after saveResult, legacy completed stays unavailable',async t=>{
 const f=collectorFixture(t,{mode:'partial',dailyCount:2});let owner;
 const invoke=async(command,args)=>{const reply=await f.invoke(command,args);if(args.request.action==='saveResult')owner.cancel();return reply;};
 owner=new B.BacktestStore({invoke,stockRequest:f.stockRequest,now:f.now,sleep:f.sleep});await owner.ready;
 await assert.rejects(()=>owner.start({symbols:[f.stock],sessions:20}));
 const m=owner.runs[0],e=m.cases[0];assert.equal(m.status,'paused');assert.equal(e.status,'pending');assert.equal(e.resultSHA256,null);
 const original=await B.archive('loadResult',{runID:m.runID,caseID:e.caseID},f.invoke),caseOriginal=await B.archive('loadCase',{runID:m.runID,caseID:e.caseID},f.invoke);
 const before=f.calls.length,resumed=new B.BacktestStore({invoke:f.invoke,stockRequest:f.stockRequest,now:f.now,sleep:f.sleep});await resumed.ready;await resumed.resume(m.runID);
 assert.equal(f.calls.length-before,19*4); // one calendar + daily + proof + partial input, no request for orphan
 assert.deepEqual(await B.archive('loadResult',{runID:m.runID,caseID:e.caseID},f.invoke),original);
 const loaded=await resumed.loadCase(m.runID,e.caseID);assert.equal(loaded.caseBody,caseOriginal.body);assert.equal(loaded.resultBody,original.body);assert.equal(loaded.inputSHA256,caseOriginal.sha256);
 assert.equal(JSON.parse(loaded.rawDetail).caseBody,caseOriginal.body);assert.equal(loaded.referenceID,B.replayRows(m.runID,loaded.caseData,loaded.result,loaded.inputSHA256)[0].referenceID);
 const saved=f.manifests.get(m.runID);const old=copy(saved);old.cases=old.cases.map(e=>({...e,resultSHA256:null}));f.manifests.set(m.runID,old);
 const calls=f.calls.length,writes=f.writes.filter(([a])=>['saveCase','saveResult','updateProgress'].includes(a)).length;
 await resumed.resume(m.runID);const legacy=await resumed.loadCase(m.runID,e.caseID);
 assert.equal(legacy.result,null);assert.equal(f.calls.length,calls);assert.equal(f.writes.filter(([a])=>['saveCase','saveResult','updateProgress'].includes(a)).length,writes);
 const summary=B.replaySummary(old,[legacy],old.models);assert.equal(summary.rows.length,0);assert.equal(summary.unavailable,20);assert.equal(summary.comparison.pairedCount,0);assert.ok(summary.models.every(m=>m.metrics.mape===null));
 const bad=copy(saved);bad.cases[0].inputSHA256='0'.repeat(64);f.manifests.set(m.runID,bad);await assert.rejects(()=>resumed.loadCase(m.runID,e.caseID));
});

test('cancellation after terminal write reads immutable completion and never pauses it',async t=>{
 const f=collectorFixture(t,{mode:'partial',dailyCount:2});let owner;
 const invoke=async(command,args)=>{const reply=await f.invoke(command,args);if(args.request.action==='updateProgress'&&args.request.status==='completed')owner.cancel();return reply;};
 owner=new B.BacktestStore({invoke,stockRequest:f.stockRequest,now:f.now,sleep:f.sleep});await owner.ready;
 await assert.rejects(()=>owner.start({symbols:[f.stock],sessions:20}));assert.equal(owner.errorMessage,'collection_cancelled');
 assert.equal(owner.runs[0].status,'completed');assert.ok(B.validManifest(owner.runs[0]));assert.ok(owner.runs[0].cases.every(e=>e.resultSHA256));
 assert.equal(f.manifests.get(owner.runs[0].runID).status,'completed');assert.equal(owner.activeRunID,null);assert.equal(owner.busy,false);
});

test('Task6 mounts the retained replay store without a render-time predictor',()=>{
  assert.equal(typeof B.mountBacktests,'function');
  const settings=task6fs.readFileSync(task6path.join(__dirname,'../penguinnotch/ui/settings.html'),'utf8');
  assert.ok(settings.includes('retainReplayWindow'),'settings attaches the official close-event owner');
  assert.match(settings,/backtests\.js/);
});

test('Task6 actual close callback retains only active work and releases a hidden settled owner',async()=>{
  let listener,callback,hide=0,close=0,starts=0,prevented=0;
  const store={busy:false,activeRunID:null,subscribe(fn){listener=fn;fn(this);return()=>{};},start(){starts++;this.busy=true;this.activeRunID='public';listener();}};
  const visible=[];
  const win={onCloseRequested:async fn=>callback=fn,hide:async()=>hide++,close:async()=>{await callback({preventDefault(){prevented++;}});close++;}};
  const owner=B.retainReplayWindow(win,store,v=>visible.push(v));await owner.ready;
  store.start();await callback({preventDefault(){prevented++;}});
  assert.equal(hide,1);assert.equal(close,0);owner.show();assert.equal(starts,1);
  await callback({preventDefault(){prevented++;}});store.busy=false;store.activeRunID=null;listener();await Promise.resolve();await Promise.resolve();
  assert.equal(close,1);assert.equal(prevented,2);assert.deepEqual(visible,[false,true,false]);
  await callback({preventDefault(){throw Error('Idle close must destroy');}});assert.equal(hide,2);
  owner.dispose();
});

test('Task6 summary and CSV never pool models/captures and retain malicious public detail',()=>{
  const f=require('../../Tests/Fixtures/stock-forecast-evaluation-v1.json'),a=copy(f.rows[0]),b=copy(a),c=copy(a);
  b.model='B';b.capture='scheduled';c.source='replay';c.referenceID='public-replay';
  const rows=[a,b,c],groups=B.evaluationGroups(rows);assert.equal(groups.length,3);
  assert.ok(groups.every(g=>new Set(g.map(r=>r.model)).size===1&&new Set(g.map(r=>r.capture)).size===1));
  const name='=TEST,"quoted"\nnext',detail=JSON.stringify({name});
  const csv=B.groupedEvaluationCSV(rows,{[a.referenceID]:detail});
  assert.ok(readCSV(csv).some(row=>row.includes(detail)));assert.match(csv,/public-replay/);
  assert.equal(csv.split('\r\n').filter(line=>line.startsWith('"metrics"')).length,3);
  const html=B.evaluationSummaryHTML(rows,'ko');assert.match(html,/평가 완료/);assert.doesNotMatch(html,/undefined|NaN/);
});

test('Task6 provider and credential invalidation cancels before change, watchlist changes preserve frozen run',async()=>{
  let cancellations=0;const seen=[];
  const store=new S.Store({onReplayInvalidation:()=>{cancellations++;seen.push(store.settings.provider);},invoke:async(cmd,args)=>{
    if(cmd==='set_stock_settings'){assert.ok(cancellations>0);return args.settings;}
    if(cmd==='get_stock_credential_status'){assert.ok(cancellations>0);return {toss:false,finnhub:false};}
    throw Error('No other calls');
  }});
  store.configure({provider:'toss',enabled:false,symbols:[{market:'us',symbol:'TEST',visible:false}]});
  assert.equal(cancellations,0);
  await store.saveSettings({...store.settings,provider:'finnhub'});assert.equal(seen[0],'toss');
  const before=cancellations;store.configure({...store.settings,symbols:[]});assert.equal(cancellations,before);
  await store.reloadCredentials();assert.ok(cancellations>before);store.dispose();
});


test('Task6 saved comparison evaluates captures separately and replay calibration labels its source',()=>{
  const sample=copy(require('../../Tests/Fixtures/stock-forecast-evaluation-v1.json').records[0]);
  const html=S.comparisonHTML([sample,{...sample,capture:'scheduled',actualClose:110}], 'en');
  assert.equal((html.match(/<table /g)||[]).length,2);
  assert.ok(html.includes('0.952%'));assert.ok(html.includes('5.455%'));
  const rows=B.replayRows('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',samples[0].caseData,
    {version:1,caseID:samples[0].caseData.input.caseID,inputSHA256:'a'.repeat(64),calculationVersion:'replay-v1',computedAt:samples[0].caseData.target.fetchedAt,
     outcomes:[{model:'GBM daily zero drift v1 / replay v1',status:'forecast',reason:null,forecast:samples[0].expected['1d']}]},'a'.repeat(64));
  const replay=B.evaluationSummaryHTML(rows,'ko');assert.ok(replay.includes('과거 재현'));assert.ok(!replay.includes('Scheduled'));
});


test('Task6 fix1 idle status reload retains late listing but newer publication wins',async()=>{
  let resolve;
  const listed=manifest(),owner=new B.BacktestStore({invoke:async()=>new Promise(r=>resolve=r)});
  const settings=new S.Store({onReplayInvalidation:()=>owner.cancel(),invoke:async()=>({toss:false,finnhub:false})});
  await settings.reloadCredentials();resolve({type:'manifests',manifests:[listed]});await owner.ready;
  assert.equal(owner.runs.length,1,'idle status discovery must not erase provider-independent archives');
  assert.equal(owner.runs[0].runID,listed.runID);settings.dispose();
  let late;
  const newer=new B.BacktestStore({invoke:async()=>new Promise(r=>late=r)});
  const updated={...listed,status:'paused'};newer.publish(updated);
  late({type:'manifests',manifests:[listed]});await newer.ready;
  assert.equal(newer.runs[0].status,'paused','a stale initial list must not overwrite a published archive update');
});

test('Task6 fix2 busy first calendar accepts initial archive and retains it after cancel',async t=>{
  const f=collectorFixture(t);let listResolve,release,entered;
  const list=new Promise(r=>listResolve=r),blocked=new Promise(r=>release=r),waiting=new Promise(r=>entered=r);
  const owner=new B.BacktestStore({invoke:(c,a)=>a.request.action==='list'?list:f.invoke(c,a),
    stockRequest:async r=>{entered();await blocked;return f.stockRequest(r);},now:f.now,sleep:f.sleep});
  const running=owner.start({symbols:[f.stock],sessions:20}),cancelled=assert.rejects(running,/collection_cancelled/);
  await waiting;assert.equal(owner.archiveRevision,0);assert.equal(owner.busy,true);
  const id=owner.activeRunID,progress=copy(owner.progress),listed=manifest();
  listResolve({type:'manifests',manifests:[listed]});await owner.ready;
  const beforeCancel=copy(owner.runs),busy=owner.busy,activeID=owner.activeRunID,currentProgress=copy(owner.progress);
  owner.cancel();release();await cancelled;
  assert.deepEqual(beforeCancel,[listed],'read-only initial archive must load while first calendar is pending');
  assert.equal(busy,true);assert.equal(activeID,id);assert.deepEqual(currentProgress,progress);
  assert.deepEqual(owner.runs,[listed],'cancelling prepublication collection must retain the existing archive');
  assert.equal(owner.busy,false);assert.equal(owner.activeRunID,null);assert.equal(f.manifests.size,0);
});

test('Task6 fix2 late initial snapshot unions unknown IDs without rolling back current publication',async t=>{
  for(const status of ['running','paused','completed'])await t.test(status,async t=>{
    const f=collectorFixture(t,{mode:'partial'});let listResolve,release,entered;
    const list=new Promise(r=>listResolve=r),blocked=new Promise(r=>release=r),waiting=new Promise(r=>entered=r);
    let first=true;
    const owner=new B.BacktestStore({invoke:(c,a)=>a.request.action==='list'?list:f.invoke(c,a),
      stockRequest:async r=>{if(status!=='completed'&&r.type==='candles'&&first){first=false;entered();await blocked;}return f.stockRequest(r);},now:f.now,sleep:f.sleep});
    const running=owner.start({symbols:[f.stock],sessions:20});
    const cancelled=status!=='completed'?assert.rejects(running,/collection_cancelled/):null;
    if(status==='completed')await running;else await waiting;
    if(status==='paused'){owner.cancel();release();await cancelled;}
    const current=copy(owner.runs[0]),progress=copy(owner.progress),id=owner.activeRunID,busy=owner.busy;
    assert.ok(owner.archiveRevision>0);
    assert.equal(current.status,status);
    const old={...manifest(),createdAt:current.createdAt-2000,collectionStartedAt:current.createdAt-2000};
    const oldest={...old,runID:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',createdAt:old.createdAt-1000,collectionStartedAt:old.createdAt-1000};
    const stale={...current,status:'ready',collectionCompletedAt:null,cases:current.cases.map(e=>({...e,status:'pending',inputSHA256:null,resultSHA256:null,reason:null}))};
    listResolve({type:'manifests',manifests:[stale,old,oldest]});await owner.ready;
    const merged=copy(owner.runs),currentProgress=copy(owner.progress),activeID=owner.activeRunID,currentBusy=owner.busy;
    if(status==='running'){owner.cancel();release();await cancelled;}
    assert.deepEqual(merged,[oldest,old,current],'unknown old runs join in canonical createdAt order; known current rows win in full');
    assert.deepEqual(currentProgress,progress);assert.equal(activeID,id);assert.equal(currentBusy,busy);
    assert.equal(new Set(merged.map(m=>m.runID)).size,3,'no duplicate current run');
  });
});

test('Task6 fix2 stale listing errors and corrupt snapshots cannot reset published state',async t=>{
  for(const failure of ['reject','corrupt'])await t.test(failure,async()=>{
    let resolve,reject;const owner=new B.BacktestStore({invoke:()=>new Promise((a,b)=>{resolve=a;reject=b;})});
    const current={...manifest(),status:'paused'};owner.publish(current);owner.errorMessage='collection_cancelled';
    const progress=copy(owner.progress);
    if(failure==='reject')reject(Error('archive failure'));else resolve({type:'manifests',manifests:[{...manifest(),version:2}]});
    await owner.ready;assert.deepEqual(owner.runs,[current]);assert.deepEqual(owner.progress,progress);assert.equal(owner.errorMessage,'collection_cancelled');
  });
});

test('Task6 fix1 native settings epoch cancellation retries identical frozen public request once',async t=>{
  const f=collectorFixture(t,{mode:'partial'}),native=[];let epoch=0,release,entered;
  const waiting=new Promise(r=>entered=r),blocked=new Promise(r=>release=r);
  const invoke=async(command,args)=>{
    if(command==='set_stock_settings'){epoch++;return args.settings;}
    if(command!=='stock_request')return f.invoke(command,args);
    const request=args.request,initial=epoch;native.push({request:copy(request),at:f.now()});
    if(request.kind==='candles'&&native.filter(c=>c.request.kind==='candles').length===1){entered();await blocked;}
    if(initial!==epoch)throw 'Stock settings or credentials changed; retry with current settings';
    const reply=await f.stockRequest(request.kind==='calendar'?{type:'calendar',market:request.market,date:request.date}:{type:'candles',stock:{market:request.market,symbol:request.symbol},interval:request.interval,before:request.before,count:request.count,adjusted:request.adjusted});
    if(reply.type==='calendar')return {data:{result:reply.value},fetchedAt:reply.requestedAt};
    return {data:{result:{candles:reply.values.map(b=>({timestamp:new Date(b.end).toISOString(),openPrice:String(b.open),highPrice:String(b.high),lowPrice:String(b.low),closePrice:String(b.close),volume:String(b.volume)})),nextBefore:reply.nextBefore}},fetchedAt:reply.requestedAt};
  };
  const owner=new B.BacktestStore({invoke,now:f.now,sleep:f.sleep});await owner.ready;
  const settings=new S.Store({invoke,onReplayInvalidation:()=>owner.cancel()});
  settings.configure({enabled:false,provider:'toss',symbols:[f.stock]});
  const running=owner.start({symbols:settings.settings.symbols,sessions:20});await waiting;
  await settings.saveSettings({...settings.settings,symbols:[{symbol:'OTHER',market:'us'}],displayInterval:5});release();await running;
  const attempts=native.filter(c=>c.request.kind==='candles');assert.deepEqual(attempts[0].request,attempts[1].request);
  assert.ok(attempts[1].at-attempts[0].at>=250,'retry obeys the same request pacing');
  assert.equal(owner.runs[0].status,'completed');assert.deepEqual(owner.runs[0].symbols,[S.stockID(f.stock)]);
  assert.equal(f.writes.filter(w=>w[0]==='saveCase').length,20);assert.equal(f.writes.filter(w=>w[0]==='saveResult').length,20);
  assert.ok(native.every(c=>c.request.kind==='calendar'||c.request.symbol===f.stock.symbol&&c.request.adjusted===true&&c.request.count===200&&['1m','1d'].includes(c.request.interval)));
  for(let n=1;n<native.length;n++)assert.ok(native[n].at-native[n-1].at>=250);
  for(const entry of owner.runs[0].cases){
    const body=JSON.parse((await f.invoke('stock_backtest_archive',{request:{action:'loadCase',runID:owner.runs[0].runID,caseID:entry.caseID}})).body);
    assert.ok(body.input.minutes.length<=1400&&body.input.dailyCloses.length<=61&&body.source.minutePages.length<=8);
    assert.equal(body.source.minutePages.length,2,'failed attempt adds no source page/data');
  }
  settings.dispose();
});

test('Task6 fix1 cancelled retry is bounded and provider/key cancellation cannot resurrect it',async()=>{
  for(const message of ['request_cancelled','Stock settings or credentials changed; retry with current settings','Stock HTTP 429','Stock HTTP 401']){
    let clock=1000,calls=0;const owner=new B.BacktestStore({invoke:async()=>({type:'manifests',manifests:[]}),now:()=>clock,sleep:async ms=>clock+=ms,stockRequest:async()=>{calls++;throw Error(message);}});await owner.ready;
    await assert.rejects(()=>owner.request({type:'calendar',market:'us',date:'2026-09-25'},owner.generation,owner.revision));
    assert.equal(calls,message.includes('429')||message.includes('401')?1:2,'only one native cancellation retry, no HTTP/auth retry expansion');
  }
  for(const change of [{provider:'finnhub'},{revision:1}]){
    let owner,clock=1000,calls=0;
    owner=new B.BacktestStore({invoke:async()=>({type:'manifests',manifests:[]}),now:()=>clock,sleep:async ms=>{clock+=ms;owner.configure(change);},stockRequest:async()=>{calls++;throw Error('request_cancelled');}});await owner.ready;
    owner.busy=true;owner.activeRunID='public-run';
    await assert.rejects(()=>owner.request({type:'calendar',market:'us',date:'2026-09-25'},owner.generation,owner.revision),/collection_cancelled/);
    assert.equal(calls,1,'provider/key changes stop before the paced retry');
  }
});
