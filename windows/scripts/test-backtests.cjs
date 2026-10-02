'use strict';
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
  if(request.action==='updateProgress'){m.cases=copy(request.entries);m.status=request.status;if(m.status==='completed')m.collectionCompletedAt=clock;assert.ok(B.validManifest(m));return {type:'empty'};}
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
