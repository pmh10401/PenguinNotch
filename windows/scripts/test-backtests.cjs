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
