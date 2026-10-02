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
