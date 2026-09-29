'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const S=require('../penguinnotch/ui/stocks.js');
const date=Date.parse;
const near=(a,b,e=1e-8)=>assert.ok(Math.abs(a-b)<e,`${a} != ${b}`);
const empty=()=>({version:1,trends:[],forecasts:[]});
const start=date('2026-09-28T13:30:00Z'),end=date('2026-09-28T20:00:00Z');
const closes=Array.from({length:31},(_,i)=>({date:S.timestamp(`2026-08-${String(31-i).padStart(2,'0')}`,'us'),price:i%2?101:100}));
function record(at=end-3500000,patch={}) {
  const forecast=S.estimate(104,closes.map(c=>c.price),{start,end},at);
  return {stockID:'us:AAPL',name:'Apple',market:'us',currency:'USD',model:S.MODEL,createdAt:at,quoteAt:at,sessionStart:start,sessionEnd:end,inputPrice:104,previousClose:100,...forecast,capture:'manual',evidence:{adjusted:true,closes},actualClose:null,evaluatedAt:null,...patch};
}
const bars=()=>Array.from({length:20},(_,i)=>({end:start+(221+i)*60000,open:90.5+i,high:91.6+i,low:90.4+i,close:91+i,volume:i===19?150:100}));
const raw=bars=>({result:{candles:bars.map(b=>({timestamp:new Date(b.end).toISOString(),openPrice:String(b.open),highPrice:String(b.high),lowPrice:String(b.low),closePrice:String(b.close),volume:String(b.volume)}))}});
const dailyRaw=rows=>({result:{candles:rows.map(c=>({timestamp:new Date(c.date).toISOString(),closePrice:String(c.price)}))}});
const clone=value=>structuredClone(value);
const flush=()=>new Promise(resolve=>setImmediate(resolve));

async function main(){
  const meterStock={symbol:'AAPL',market:'us',visible:true,color:'b026ff'};
  const meterStore={settings:S.normalizeSettings({enabled:true,symbols:[meterStock]}),quotes:new Map(),names:new Map(),now:()=>12000};
  for(const [price,close,fraction,color,reverse] of [[107.5,100,.25,'var(--ample)',false],[92.5,100,.25,'#FF453A',true],[115,100,.5,'var(--ample)',false],[85,100,.5,'#FF453A',true],[150,100,1,'var(--ample)',false],[50,100,1,'#FF453A',true],[100,100,0,'var(--ink-dim)',false],[100,null,null,'var(--ink-dim)',false],[Infinity,100,null,'var(--ink-dim)',false],[1e308,1e-308,null,'var(--ink-dim)',false]]){
    meterStore.quotes.set('us:AAPL',{price,previousClose:close,currency:'USD',quoteAt:12000});
    const meter=S.cells(meterStore,'en')[0].meter;
    assert.equal(meter.fraction,fraction);assert.equal(meter.color,color,'stock direction overrides custom accent');assert.equal(meter.counterclockwise,reverse);
  }
  const ringSource=fs.readFileSync(path.join(__dirname,'../penguinnotch/ui/notch.html'),'utf8');
  const svg=vm.runInNewContext(ringSource.slice(ringSource.indexOf('function svgArc('),ringSource.indexOf('function applyMeterStyle('))+';({stockSweep,svgArc,svgBar})');
  for(const fraction of [.001,.25,.5,.75,1]){
    const forward=svg.stockSweep(fraction,'#00FF88',false),reverse=svg.stockSweep(fraction,'#FF453A',true);
    for(const [markup,direction] of [[forward,1],[reverse,-1]]){
      assert.equal((markup.match(/<circle /g)||[]).length,1,'one hollow arc, no pie');
      assert.ok(!markup.includes('<path'));assert.match(markup,/fill="none"/);
      const radius=Number(markup.match(/ r="([^"]+)"/)[1]),dash=Number(markup.match(/stroke-dasharray="([^ ]+)/)[1]);
      near(dash,2*Math.PI*radius*fraction,.006);
      assert.match(markup,/transform="rotate\(-90 28 28\)"/,'12 oclock origin');
      const mirrored=markup.includes('transform="translate(56 0) scale(-1 1)"');
      // Sample the actual SVG dash halfway through its first quadrant, then apply its group transform.
      const angle=Math.min(dash/(2*radius),Math.PI/4),x=28+radius*Math.sin(angle),screenX=mirrored?56-x:x;
      assert.ok(direction*(screenX-28)>0,'gain sweeps right, loss sweeps left from twelve');
    }
    assert.equal(forward.replace('#00FF88','#FF453A').replace('<g>','<g transform="translate(56 0) scale(-1 1)">'),reverse,'only signed reading is mirrored');
    near(Number(svg.svgBar(fraction,'green').match(/width="([^"]+)/)[1]),50*fraction);
  }
  for(const empty of [0,null,NaN]) assert.equal(svg.stockSweep(empty,'red',true),'');
  assert.equal(svg.svgBar(0,'red'),'');
  console.log('PASS stock signed colors, neutral/missing quotes, hollow SVG sweep geometry and equal bar magnitude');
  assert.deepEqual(S.parseStock(' 삼성전자 '),null);
  assert.deepEqual(S.parseStock('kr:005930'),{symbol:'005930',market:'kr'});
  assert.deepEqual(S.parseStock('BRK.B'),{symbol:'BRK.B',market:'us'});
  assert.equal(S.parseStock('<svg>'),null);
  const normalized=S.normalizeSettings({...S.DEFAULTS,clientSecret:'do-not-retain',symbols:[{symbol:'AAPL',market:'us',name:'x'.repeat(220),visible:true,color:'#abcdef'}],candleCount:200});
  assert.equal(normalized.candleCount,20);assert.equal(normalized.symbols[0].name.length,200);assert.equal(normalized.symbols[0].color,'abcdef');assert.ok(!('clientSecret' in normalized));assert.deepEqual(S.normalizeSettings({symbols:[{symbol:'AAPL',market:'us',name:'',visible:true}]}).symbols,[{symbol:'AAPL',market:'us',visible:true}],'blank optional names omitted for native validation');
  const directory=S.parseDirectory('# comment\n005930\t삼성전자\tKOSPI\n000660\tSK하이닉스\tKOSPI');
  assert.equal(S.findCompanies(directory,'삼성')[0].code,'005930');
  assert.ok(S.parseDirectory(fs.readFileSync(path.join(__dirname,'../penguinnotch/ui/krx-listed-companies.tsv'),'utf8')).length>1000);

  const reorderList=[{symbol:'AAPL',market:'us',visible:true},{symbol:'MSFT',market:'us',visible:false},{symbol:'NVDA',market:'us',visible:true},{symbol:'005930',market:'kr',visible:true}];
  assert.deepEqual(S.reorderStocks(reorderList,'us:AAPL','kr:005930').map(S.stockID),['us:NVDA','us:MSFT','kr:005930','us:AAPL']);
  assert.equal(S.reorderStocks(reorderList,'us:MSFT','us:AAPL'),reorderList,'hidden slots stay fixed during visible drag');
  assert.equal(S.reorderStocks(reorderList,'us:AAPL','missing'),reorderList);
  assert.equal(S.dragStarted({clientX:0,clientY:0,altKey:false},{clientX:4,clientY:0}),false);
  assert.equal(S.dragStarted({clientX:0,clientY:0,altKey:false},{clientX:5,clientY:0}),true);
  assert.equal(S.dragStarted({clientX:0,clientY:0,altKey:true},{clientX:50,clientY:0}),false,'Alt is reserved for whole-notch movement');
  // Exercise the actual pointer handlers without a browser dependency.
  const handlers=new Map(),pointerStates=[],savedOrders=[];
  const target=()=>({addEventListener:(name,fn)=>handlers.set(name,fn),removeEventListener:name=>handlers.delete(name)});
  const makeRow=id=>({dataset:{stockDrag:id},classList:{remove(){},toggle(){}},closest(selector){return selector==='[data-stock-drag]'?this:null;}});
  const rows=reorderList.filter(s=>s.visible).map(s=>makeRow(S.stockID(s)));let over=rows[2],captured=false;
  const dragDocument={...target(),defaultView:target(),elementFromPoint:()=>over};
  const dragRoot={...target(),ownerDocument:dragDocument,contains:r=>rows.includes(r),querySelectorAll:()=>rows,setPointerCapture:()=>captured=true,hasPointerCapture:()=>captured,releasePointerCapture:()=>captured=false};
  const dragStore={settings:{symbols:reorderList},revision:0,busy:false,saveSettings:async settings=>savedOrders.push(settings.symbols.map(S.stockID))};
  const detach=S.bindStockDrag(dragRoot,dragStore,state=>pointerStates.push(state));
  const pointer=(extra={})=>({pointerId:1,button:0,altKey:false,clientX:0,clientY:0,target:rows[0],preventDefault(){},...extra});
  handlers.get('pointerdown')(pointer());handlers.get('pointermove')(pointer({clientX:4}));handlers.get('pointerup')(pointer({clientX:4}));
  assert.equal(savedOrders.length,0);assert.equal(pointerStates.length,0,'short clicks remain the existing refresh path');
  handlers.get('pointerdown')(pointer());handlers.get('pointermove')(pointer({clientX:10}));handlers.get('pointerup')(pointer({clientX:10}));
  assert.deepEqual(pointerStates,[true,false]);assert.deepEqual(savedOrders[0],['us:NVDA','us:MSFT','kr:005930','us:AAPL']);
  handlers.get('pointerdown')(pointer({altKey:true}));handlers.get('pointermove')(pointer({clientX:50,altKey:true}));handlers.get('pointerup')(pointer({clientX:50,altKey:true}));assert.equal(savedOrders.length,1);
  handlers.get('pointerdown')(pointer());handlers.get('pointermove')(pointer({clientX:10}));handlers.get('keydown')({key:'Escape'});handlers.get('pointerup')(pointer({clientX:10}));assert.equal(savedOrders.length,1,'Escape cancels without refresh or reorder');
  handlers.get('pointerdown')(pointer());handlers.get('pointermove')(pointer({clientX:10}));dragStore.revision++;handlers.get('pointerup')(pointer({clientX:10}));assert.equal(savedOrders.length,1,'settings changes reject an in-flight drag');detach();

  const quotes=S.decodeQuotes({result:[{symbol:'AAPL',lastPrice:'105',priceChangeRate:105,currency:'USD',timestamp:'2026-09-28T15:00:00Z'}]});
  const q=quotes.get('us:AAPL');assert.equal(q.price,105);assert.equal(S.changeRate(q),null,'never treat price or provider change field as a percent');
  const daily=[{date:S.timestamp('2026-09-28','us'),price:105},{date:S.timestamp('2026-09-25','us'),price:100},{date:S.timestamp('2026-09-24','us'),price:98}];
  q.previousClose=S.previousClose(daily,q.quoteAt,'us');near(S.changeRate(q),.05);
  assert.equal(S.previousClose(daily,date('2026-09-25T22:00:00Z'),'us'),98,'newer-dated candle must not become Friday quote baseline');
  assert.equal(S.previousClose(daily,date('2026-09-29T14:00:00Z'),'us'),105,'new session without candle uses latest preceding close');
  assert.equal(S.previousClose([daily[0]],q.quoteAt,'us'),null);
  const sundayQuote=date('2026-09-28T03:01:00Z'),soxlDaily=[{date:S.timestamp('2026-09-28','us'),price:144.1},{date:S.timestamp('2026-09-25','us'),price:151.45},{date:S.timestamp('2026-09-24','us'),price:146.33}];
  assert.equal(S.previousClose(soxlDaily,sundayQuote,'us'),151.45,'a future Monday candle must not make a Sunday quote skip Friday');
  assert.equal(S.previousClose(soxlDaily.slice(1),sundayQuote,'us'),151.45,'adding a newer candle cannot change the preceding close');
  const missing=S.decodeQuotes({result:[{symbol:'AAPL',lastPrice:100,currency:'USD',timestamp:null}]}).get('us:AAPL');assert.ok(Number.isNaN(missing.quoteAt));assert.equal(S.previousClose(daily,missing.quoteAt,'us'),null);
  const finn=S.decodeFinnhub({c:104,pc:100,t:start/1000});near(S.changeRate(finn),.04);assert.equal(finn.quoteAt,start);
  assert.throws(()=>S.decodeFinnhub({c:0,pc:100,t:100}));

  assert.equal(S.dayKey(date('2026-03-09T03:30:00Z'),'us'),'2026-03-08');
  assert.equal(S.dayKey(date('2026-03-09T03:30:00Z'),'kr'),'2026-03-09');
  assert.equal(S.timestamp('2026-03-09','us'),date('2026-03-09T04:00:00Z'));
  assert.equal(S.timestamp('2026-03-06','us'),date('2026-03-06T05:00:00Z'));
  assert.equal(S.timestamp('2026-11-02','us'),date('2026-11-02T05:00:00Z'));
  assert.equal(S.timestamp('2026-03-09','kr'),date('2026-03-08T15:00:00Z'));
  const calendar={result:{today:{regularMarket:{startTime:'2026-03-09T09:30:00-04:00',endTime:'2026-03-09T16:00:00-04:00'}},previousBusinessDay:{regularMarket:{startTime:'2026-03-06T09:30:00-05:00',endTime:'2026-03-06T16:00:00-05:00'}},nextBusinessDay:{}}};
  assert.equal(S.regularSession(calendar,'us',date('2026-03-09T14:00:00Z')).start,date('2026-03-09T13:30:00Z'));
  assert.equal(S.regularSession(calendar,'us',date('2026-03-06T15:00:00Z')).start,date('2026-03-06T14:30:00Z'));
  assert.equal(S.regularSession(calendar,'us',date('2026-03-09T20:00:00Z')),null);
  const early={result:{today:{regularMarket:{startTime:'2026-11-27T09:30:00-05:00',endTime:'2026-11-27T13:00:00-05:00'}}}};
  assert.equal(S.regularSession(early,'us',date('2026-11-27T17:00:00Z')).end,date('2026-11-27T18:00:00Z'),'official half-day close');
  const korean={result:{today:{integrated:{regularMarket:{startTime:'2026-09-28T09:00:00+09:00',endTime:'2026-09-28T15:30:00+09:00'}}}}};
  assert.equal(S.regularSession(korean,'kr',date('2026-09-28T01:00:00Z')).start,date('2026-09-28T00:00:00Z'));
  const interval=(startTime,endTime)=>({startTime,endTime});
  const quoteCalendar={result:{today:{},previousBusinessDay:{regularMarket:interval('2026-09-25T09:30:00-04:00','2026-09-25T16:00:00-04:00'),afterMarket:interval('2026-09-25T16:00:00-04:00','2026-09-25T20:00:00-04:00')},nextBusinessDay:{dayMarket:interval('2026-09-27T20:00:00-04:00','2026-09-28T04:00:00-04:00'),preMarket:interval('2026-09-28T04:00:00-04:00','2026-09-28T09:30:00-04:00'),regularMarket:interval('2026-09-28T09:30:00-04:00','2026-09-28T16:00:00-04:00'),afterMarket:interval('2026-09-28T16:00:00-04:00','2026-09-28T20:00:00-04:00')}}};
  for(const [at,phase,tradingDay] of [['2026-09-25T19:59:59Z','regularMarket','2026-09-25'],['2026-09-25T20:00:00Z','afterMarket','2026-09-25'],['2026-09-28T03:01:00Z','dayMarket','2026-09-28'],['2026-09-28T08:00:00Z','preMarket','2026-09-28'],['2026-09-28T13:30:00Z','regularMarket','2026-09-28']]) {
    const context=S.quoteContext(quoteCalendar,date(at));assert.equal(context.phase,phase);assert.equal(context.tradingDay,tradingDay);
  }
  assert.equal(S.quoteContext(quoteCalendar,date('2026-09-26T00:00:00Z')),null,'official interval ends are exclusive');
  assert.equal(S.quoteContext(quoteCalendar,date('2026-09-27T12:00:00Z')),null,'closed market is not inferred to be regular');
  assert.equal(S.quoteContext(quoteCalendar,NaN),null);assert.equal(S.quoteContext({},sundayQuote),null);
  const ambiguousCalendar=clone(quoteCalendar);ambiguousCalendar.result.today={...clone(quoteCalendar.result.nextBusinessDay),regularMarket:interval('2026-09-29T09:30:00-04:00','2026-09-29T16:00:00-04:00')};assert.equal(S.quoteContext(ambiguousCalendar,sundayQuote),null,'conflicting official trading days cannot supply a guessed session');
  assert.equal(S.quoteContext(calendar,date('2026-03-06T14:30:00Z')).regularStart,date('2026-03-06T14:30:00Z'));
  assert.equal(S.quoteContext(calendar,date('2026-03-09T13:30:00Z')).regularStart,date('2026-03-09T13:30:00Z'));
  early.result.today.afterMarket=interval('2026-11-27T13:00:00-05:00','2026-11-27T17:00:00-05:00');
  const halfDay=S.quoteContext(early,date('2026-11-27T18:00:00Z'));assert.equal(halfDay.phase,'afterMarket');assert.equal(halfDay.regularEnd,date('2026-11-27T18:00:00Z'));

  const b=bars(),now=b.at(-1).end;
  assert.deepEqual(S.decodeCandles(raw(b.slice().reverse()),'us'),b);
  assert.throws(()=>S.decodeCandles(raw([...b,b[0]]),'us'));
  assert.equal(S.movingAverage(b,20)[18],null);near(S.movingAverage(b,20).at(-1),100.5);
  const historical=Array.from({length:140},(_,i)=>({...b[0],end:start+i*60000,close:i+1}));
  near(S.movingAverage(historical,120).slice(-20).at(-1),80.5);
  assert.equal(S.movingAverage(historical.slice(-20),120).at(-1),null);
  const minutes=Array.from({length:200},(_,i)=>({end:start+(i+41)*60000,open:90.5+Math.floor(i/10),close:91+Math.floor(i/10),high:91.6+Math.floor(i/10),low:90.4+Math.floor(i/10),volume:i>=190?15:10}));
  assert.equal(S.tenMinuteBars(minutes).length,20);assert.equal(S.tenMinuteBars(minutes,true).length,20);
  assert.equal(S.tenMinuteBars(minutes.slice(0,-1),true).length,19);
  assert.equal(S.completedBars([...minutes,minutes[0]],now,'10m').length,0);
  assert.equal(S.technical(minutes,'10m','us',now,now).action,'buy');
  assert.equal(S.technical(minutes.slice(0,-1),'10m','us',now,now),null,'partial bucket cannot make 20 analysis bars');
  const across=b.map((bar,i)=>({...bar,end:bar.end-(i<10?3*86400000:0)}));
  const historicalSignal=S.technical(across,'1m','us',end+1000,end+1000);
  assert.equal(historicalSignal.action,'buy');assert.equal(historicalSignal.live,false,'history analysis needs neither holdings nor open session');near(historicalSignal.ratio,1.5);near(historicalSignal.slow,100.5);
  const broken=b.map((bar,i)=>({...bar,end:bar.end-(i===5?30000:0)}));assert.equal(S.technical(broken,'1m','us',now,now),null);
  assert.equal(S.technical(b,'1m','us',now-181000,now),null);assert.equal(S.technical(b,'1m','us',now+1,now),null);
  assert.equal(S.technical(b.map(bar=>({...bar,volume:0})),'1m','us',now,now),null);
  assert.equal(S.technical([...b,{...b.at(-1),end:now+60000,volume:99999}],'1m','us',now,now).ratio,1.5,'future bar ignored');
  const dayBars=b.map((bar,i)=>({...bar,end:S.timestamp(`2026-08-${String(i+1).padStart(2,'0')}`,'us')}));
  const today={...dayBars.at(-1),end:S.timestamp('2026-09-28','us'),volume:999999};
  assert.equal(S.technical([...dayBars,today],'1d','us',now,now).ratio,1.5,'open local daily candle excluded');

  const r=record();assert.equal(S.validForecast(r),true);
  assert.equal(r.expectedClose,r.inputPrice,'GBM zero drift expected price is precisely input quote');
  near(S.dailyVariance(closes.map(c=>c.price)),0.00010242319043534956,1e-12);
  // Independent reference: Python math.erf for Swift's erf distribution.
  near(r.riseProbability,1,1e-7);assert.ok(r.lowerClose<104&&r.upperClose>104);
  const atMoney=S.estimate(100,closes.map(c=>c.price),{start,end},start);
  near(atMoney.riseProbability,0.49798127404589243,2e-7);
  assert.equal(S.estimate(100,Array(31).fill(100),{start,end},start),null);
  assert.equal(S.estimate(100,closes.map(c=>c.price),{start,end},end),null);
  assert.equal(S.estimate(100,closes.slice(0,20).map(c=>c.price),{start,end},start),null);
  const confirmed=record(now,{inputPrice:111,expectedClose:111});
  assert.equal(S.technical(b,'1m','us',now,now,confirmed).live,true);
  assert.equal(S.technical(b,'1m','us',now+121000,now+121000,confirmed).live,false);
  const band=S.chartEstimate(confirmed,b,'1m',now);assert.equal(band.expectedClose,111);assert.equal(band.observations,19);
  assert.equal(S.chartEstimate(confirmed,b.filter((_,i)=>i!==16),'1m',now),null,'latest consecutive segment under10');
  assert.equal(S.chartEstimate(confirmed,b,'1d',now).observations,30);

  let h=S.appendSamples(empty(),[r],true);assert.equal(h.trends.length,1);assert.equal(h.forecasts.length,1);assert.equal(h.forecasts[0].capture,'scheduled');
  assert.deepEqual(Object.keys(h.trends[0]),S.TREND_KEYS);assert.ok(!('evidence' in h.trends[0]));
  h=S.appendSamples(h,[record(r.createdAt+10000),record(r.createdAt-60000)],true);assert.equal(h.trends.length,1,'same minute or delayed quote is not another sample');
  h=S.appendSamples(h,[record(r.createdAt+60000)],true);assert.equal(h.trends.length,2);assert.equal(h.forecasts.length,1);
  h=S.saveSnapshots(h,[r],r.createdAt);h=S.saveSnapshots(h,[record(r.createdAt+60000)],r.createdAt+60000);assert.equal(h.forecasts.length,2,'manual and scheduled once each; not per minute');
  const other=record(r.createdAt+120000,{model:'other model'});h=S.appendSamples(h,[other],false);assert.equal(h.trends.length,3,'model partitions retained');
  assert.deepEqual(S.validateHistory(JSON.parse(JSON.stringify(h))),h);
  assert.throws(()=>S.validateHistory({...h,privateAccount:'x'}));assert.throws(()=>S.validateHistory({...h,trends:[{...h.trends[0],accountSeq:3}]}));
  assert.equal(S.validForecast({...r,evidence:{...r.evidence,balance:1}}),false);
  assert.equal(S.validForecast({...r,evidence:{...r.evidence,closes:[...closes.slice(1),closes[0]]}}),false);
  assert.equal(S.validForecast({...r,actualClose:101,evaluatedAt:end+1000}),false,'same local day cannot be scored');
  const resolved={...r,actualClose:106,evaluatedAt:S.timestamp('2026-09-29','us')};assert.equal(S.validForecast(resolved),true);
  const metrics=S.score([resolved]);assert.equal(metrics.evaluated,1);near(metrics.mae,2);near(metrics.mape,2/106*100);near(metrics.baseline,metrics.mape);assert.equal(metrics.accuracy,1);
  const alternative={...resolved,model:'Other model',name:'Same stock, another label',createdAt:resolved.createdAt+1000,expectedClose:106,riseProbability:.8},unpaired={...resolved,stockID:'us:MSFT',name:'Microsoft'};
  const comparison=S.compareModels([resolved,alternative,unpaired]);assert.equal(comparison.pairedCount,1);assert.deepEqual(comparison.rows.map(row=>row.available.total),[2,1]);assert.deepEqual(comparison.rows.map(row=>row.paired.evaluated),[1,1]);near(comparison.rows[0].paired.mape,2/106*100);near(comparison.rows[1].paired.mape,0);near(comparison.baseline,2/106*100);
  const changedEvidence=clone(alternative.evidence);changedEvidence.closes[1].price+=.5;
  const changedPrevious=clone(alternative.evidence);changedPrevious.closes[0].price+=.5;
  const changedEvidenceTime=clone(alternative.evidence);changedEvidenceTime.closes[1].date+=60000;
  for(const patch of [{stockID:'us:MSFT'},{quoteAt:alternative.quoteAt+1},{inputPrice:105},{previousClose:100.5,evidence:changedPrevious},{sessionStart:start+1000},{sessionEnd:end+60000},{capture:'scheduled'},{evidence:changedEvidence},{evidence:changedEvidenceTime},{actualClose:107}]){
    const mismatch={...alternative,...patch};assert.equal(S.validForecast(mismatch),true);assert.equal(S.compareModels([resolved,mismatch]).pairedCount,0,'different inputs/evidence/resolved target cannot be paired');
  }
  assert.equal(S.compareModels([resolved,alternative,{...r,model:'Third pending model'}]).pairedCount,0,'intersection requires every recorded model, including a pending model');
  assert.equal(S.compareModels([resolved,resolved,alternative]).pairedCount,0,'duplicate model rows cannot establish a pair');
  const binRecords=[{p:0,close:100},{p:.099,close:101},{p:.1,close:100},{p:.5,close:100},{p:.59,close:101},{p:.9,close:99},{p:1,close:101}].map(({p,close},i)=>({...resolved,stockID:'us:BIN'+i,riseProbability:p,actualClose:close}));
  const bins=S.probabilityBins([...binRecords,{...r,riseProbability:.3}]);assert.deepEqual(bins.map(b=>b.id),[0,1,5,9],'empty and pending bands omitted; p=1 belongs to last band');
  const half=bins.find(b=>b.id===5);assert.equal(half.count,2);assert.equal(half.rises,1,'unchanged close is not rising; p=.5 is counted');near(half.meanProbability,.545);near(half.observedRate,.5);near(half.lower,.0945312057342307);near(half.upper,.9054687942657693);
  near(bins[1].lower,0);near(bins[1].upper,.7934506856227626);assert.ok(S.probabilityHTML(binRecords,'en').includes('95% Wilson interval'));assert.ok(S.probabilityHTML(binRecords,'en').includes('50–&lt;60%'));
  const evidenceMarkup=S.evidenceHTML(resolved,'en');assert.ok(evidenceMarkup.includes('Prediction evidence'));assert.ok(evidenceMarkup.includes('Completed daily closes (31)'));assert.ok(evidenceMarkup.includes('2026-08-31'));assert.ok(evidenceMarkup.includes('1.01%'));assert.ok(evidenceMarkup.includes('-0.99%'));assert.ok(evidenceMarkup.includes('0.00%'));assert.equal((evidenceMarkup.match(/<th scope="row">/g)||[]).length,31);assert.ok(S.evidenceHTML({...resolved,model:'<b>model</b>'},'en').includes('&lt;b&gt;model&lt;/b&gt;'));
  const filterSource={version:1,forecasts:[resolved,alternative,unpaired,{...resolved,capture:'scheduled'}],trends:[h.trends[0],{...h.trends[0],stockID:'us:MSFT',name:'Microsoft'}]},beforeFilters=clone(filterSource);
  const filtered=S.filterHistory(filterSource,{stockID:'us:AAPL',day:'2026-09-28',model:S.MODEL,capture:'manual'});assert.deepEqual(filtered.records,[resolved]);assert.deepEqual(filtered.cohort,[resolved,alternative],'comparison ignores model filter, retains stock/day/capture');assert.equal(filtered.traces.length,1);assert.equal(filtered.traces[0].stockID,'us:AAPL');assert.deepEqual(filterSource,beforeFilters,'filters never prune or mutate archive');
  assert.ok(S.comparisonHTML(filtered.cohort,'en').includes('Other model'));
  // Run the actual section renderers against a small DOM stand-in whose
  // innerHTML setter destroys disclosure nodes, just as the WebView does.
  const disclosureHost=()=>{
    let html='',nodes=[];
    return {dataset:{},get innerHTML(){return html;},set innerHTML(value){html=value;nodes=[...value.matchAll(/<details\b([^>]*)>/g)].map(([,attrs])=>({open:false,dataset:{stockDisclosure:attrs.match(/data-stock-disclosure="([^"]*)"/)?.[1]}}));},querySelectorAll(selector){return selector==='details[data-stock-disclosure]'?nodes.filter(node=>node.dataset.stockDisclosure):[];},querySelector(){return {};}};
  };
  const disclosureHosts={'#stock-holdings':disclosureHost(),'#stock-history':disclosureHost()},disclosureElement={querySelector:selector=>disclosureHosts[selector]||null,querySelectorAll:selector=>Object.values(disclosureHosts).flatMap(host=>host.querySelectorAll(selector))};
  const disclosureStore={forecastStocks:[{symbol:'AAPL',market:'us',name:'Apple'},{symbol:'MSFT',market:'us',name:'Microsoft'}],candidates:[r,unpaired],forecastError:'',accountError:'',historyError:'',reasons:new Map(),history:clone(filterSource)};
  const uiSource=fs.readFileSync(path.join(__dirname,'../penguinnotch/ui/stocks.js'),'utf8'),sectionCode=uiSource.slice(uiSource.indexOf('  function renderPortfolio(){'),uiSource.indexOf("  store.listen?.('stock-history-updated'"));
  const disclosureContext=vm.createContext({...S,element:disclosureElement,store:disclosureStore,language:()=> 'en',tr:key=>S.esc(key),historyFilter:{stockID:'',day:'',model:'',capture:''}});
  vm.runInContext(sectionCode+';renderPortfolio();renderHistory();',disclosureContext);
  const details=()=>disclosureElement.querySelectorAll('details[data-stock-disclosure]'),detail=key=>details().find(node=>node.dataset.stockDisclosure===key);
  const currentEvidence='current-evidence:'+r.stockID+'|'+r.sessionStart+'|'+r.model,savedEvidence='saved-evidence:'+S.forecastID(resolved),historyGroup=details().find(node=>node.dataset.stockDisclosure.startsWith('history:')).dataset.stockDisclosure;
  const keptOpen=['current:us:AAPL',currentEvidence,currentEvidence+'|closes',historyGroup,'record:'+S.forecastID(resolved),savedEvidence,savedEvidence+'|closes','comparison','probability','trace:'+r.stockID+'|'+r.sessionStart+'|'+r.model];
  for(const key of keptOpen){assert.ok(detail(key),'stable disclosure key exists: '+key);detail(key).open=true;}
  disclosureStore.candidates=[record(r.createdAt+60000),unpaired];disclosureStore.history.trends.push({...filterSource.trends[0],createdAt:r.createdAt+60000,quoteAt:r.quoteAt+60000});
  vm.runInContext('renderPortfolio();renderHistory();',disclosureContext);
  for(const key of keptOpen)assert.equal(detail(key).open,true,'quote/history update preserves '+key);assert.equal(detail('current:us:MSFT').open,false,'closed sibling stays closed');
  detail(currentEvidence).open=false;vm.runInContext('renderPortfolio();',disclosureContext);assert.equal(detail(currentEvidence).open,false,'user closing a disclosure is respected on the next tick');
  const restoreRoot=S.rememberDisclosures(disclosureElement);for(const selector of Object.keys(disclosureHosts))disclosureHosts[selector]=disclosureHost();vm.runInContext('renderPortfolio();renderHistory();',disclosureContext);restoreRoot();
  assert.equal(detail('comparison').open,true);assert.equal(detail(savedEvidence+'|closes').open,true,'nested state survives a full settings subtree replacement');assert.equal(detail(currentEvidence).open,false);
  disclosureStore.forecastStocks=[disclosureStore.forecastStocks[1]];vm.runInContext('renderPortfolio();',disclosureContext);assert.equal(detail('current:us:MSFT').open,false,'removed stock state does not migrate by row index');
  assert.ok(S.csv([{...r,name:'=HYPERLINK("bad")'}]).includes("'="),'spreadsheet formula injection escaped');
  const exported=[...S.csv([resolved]).split('\r\n')[1].matchAll(/"((?:[^"]|"")*)"/g)].map(match=>match[1].replace(/""/g,'"'));assert.deepEqual(JSON.parse(exported[S.FORECAST_KEYS.indexOf('evidence')]),resolved.evidence,'CSV retains exact numeric timestamps and saved candle evidence');
  assert.ok(!S.csv(h.trends,true).includes('evidence'));
  const markup=S.cardHTML({settings:{...S.DEFAULTS,enabled:true,provider:'finnhub',symbols:[{symbol:'AAPL',market:'us'}]},quotes:new Map(),names:new Map(),now:()=>now}, {symbol:'AAPL',market:'us',name:'<img src=x onerror=x>'},'en');
  assert.ok(markup.includes('&lt;img'));assert.ok(!markup.includes('data-stock-interval'),'Finnhub has no candle/technical/forecast sections');
  let cardNow=now;const watchedStock={symbol:'AAPL',market:'us',name:'Apple',visible:true};
  const watchedCard=new S.Store({invoke:async()=>{throw Error('Card rendering must not request data');},now:()=>cardNow});
  watchedCard.settings=S.normalizeSettings({enabled:true,forecastsEnabled:true,accountSeq:0,symbols:[watchedStock]});watchedCard.candidates=[confirmed];
  watchedCard.charts.set('us:AAPL|1m',{candles:b,fetchedAt:now,error:''});watchedCard.quotes.set('us:AAPL',{price:111,previousClose:100,quoteAt:now,currency:'USD'});
  assert.deepEqual(watchedCard.holdings,[]);assert.ok(S.cardHTML(watchedCard,watchedStock,'en').includes('<b>Consider buying</b>'),'fresh watched candidate confirms the card pattern without holdings');
  cardNow+=121000;const staleCard=S.cardHTML(watchedCard,watchedStock,'en');assert.ok(!staleCard.includes('<b>Consider buying</b>'));assert.ok(staleCard.includes('Bullish pattern · completed bars'),'stale watched quote still falls back to historical analysis');watchedCard.dispose();

  // Quote sessions are independent of forecasts/accounts and use the trade clock.
  const quoteFixture=(patch={})=>{
    const state={now:sundayQuote,quoteAt:sundayQuote,price:144.1,calendar:quoteCalendar,daily:soxlDaily,symbol:'SOXL',market:'us',currency:'USD',...patch},requests=[];
    const result=new S.Store({owner:true,now:()=>state.now,invoke:async(cmd,{request})=>{
      assert.equal(cmd,'stock_request');requests.push(clone(request));
      let data;
      if(request.kind==='prices')data={result:[{symbol:state.symbol,lastPrice:state.price,currency:state.currency,timestamp:typeof state.quoteAt==='number'?new Date(state.quoteAt).toISOString():state.quoteAt}]};
      else if(request.kind==='calendar'){if(state.calendarError)throw(state.calendarError===true?Error('Calendar unavailable'):state.calendarError);data=state.calendar;}
      else if(request.kind==='candles'){if(state.candleError)throw Error('Candles unavailable');data=dailyRaw(state.daily);}
      else if(request.kind==='names')data={result:[]};
      else throw Error('Unexpected quote request '+request.kind);
      return {data,fetchedAt:request.kind==='candles'?(state.candleFetchedAt??state.now):state.now};
    }});
    result.settingsReady=true;result.credentials={toss:true};result.settings=S.normalizeSettings({enabled:true,forecastsEnabled:false,symbols:[{symbol:state.symbol,market:state.market,visible:true}]});
    return {store:result,state,requests};
  };
  const sunday=quoteFixture();await sunday.store.refreshQuotes();
  const sundayResult=sunday.store.quotes.get('us:SOXL');assert.equal(sundayResult.context.tradingDay,'2026-09-28');assert.equal(sundayResult.context.phase,'dayMarket');assert.equal(sundayResult.previousClose,151.45);near(S.changeRate(sundayResult),(144.1-151.45)/151.45);
  assert.ok(sunday.requests.some(req=>req.kind==='calendar'&&req.date==='2026-09-27'),'calendar uses the quote local date, not Monday UTC');
  assert.deepEqual(sunday.requests.find(req=>req.kind==='candles'),{kind:'candles',symbol:'SOXL',market:'us',interval:'1d',count:3,adjusted:true});
  assert.ok(!sunday.requests.some(req=>['accounts','holdings'].includes(req.kind)));
  const sundayHTML=S.cardHTML(sunday.store,sunday.store.settings.symbols[0],'en');assert.match(sundayHTML,/Day market/);assert.match(sundayHTML,/Change vs prior regular close/);assert.match(sundayHTML,/2026-09-25 ET/);assert.match(sundayHTML,/09\/27\/2026, 23:01:00 ET/);
  const quoteRequestCount=sunday.requests.length;await sunday.store.refreshQuotes();assert.equal(sunday.requests.length,quoteRequestCount,'display refresh reuses 60-second quote inputs');
  // Parent verified these price/percentage pairs against public Toss WTS trades.
  const percentNow=Math.ceil(sundayQuote/6000)*6000,displayedQuote=sunday.store.quotes.get('us:SOXL');
  for(const [price,display] of [[144.07,'-4.87%'],[144.09,'-4.85%'],[144.11,'-4.84%'],[144.12,'-4.83%'],[158.81,'+4.85%']]) {
    displayedQuote.price=price;assert.equal(S.cells(sunday.store,'en',percentNow)[0].meter.text,display,'Toss quote percentages truncate toward zero');assert.ok(S.cardHTML(sunday.store,sunday.store.settings.symbols[0],'en').includes(' · '+display+'</p>'));near(S.changeRate(displayedQuote),(price-151.45)/151.45,1e-12);
  }
  for(const [price,previousClose,display] of [[100.1,100,'+0.10%'],[99.9,100,'-0.10%'],[1.13,1,'+13.00%'],[99.99999,100,'-0.00%']]) {
    Object.assign(displayedQuote,{price,previousClose});assert.equal(S.cells(sunday.store,'en',percentNow)[0].meter.text,display,'floating-point noise must not drop an exact hundredth-percent boundary');
  }
  displayedQuote.price=144.09;displayedQuote.previousClose=151.45;sunday.store.settings.provider='finnhub';assert.equal(S.cells(sunday.store,'en',percentNow)[0].meter.text,'-4.86%','Finnhub retains rounded percentages');sunday.store.settings.provider='toss';
  sunday.state.now+=60000;sunday.state.quoteAt=sunday.state.now;await sunday.store.refreshQuotes();assert.equal(sunday.requests.filter(req=>req.kind==='calendar').length,2);assert.equal(sunday.requests.filter(req=>req.kind==='candles').length,2,'latest quote daily bars refresh after one minute');sunday.store.dispose();
  const after=quoteFixture({quoteAt:date('2026-09-25T23:01:00Z')});await after.store.refreshQuotes();const afterResult=after.store.quotes.get('us:SOXL');assert.equal(afterResult.context.phase,'afterMarket');assert.equal(afterResult.previousClose,151.45,'Friday after-hours uses Friday close even on Sunday wall clock');
  const afterHTML=S.cardHTML(after.store,after.store.settings.symbols[0],'en');assert.match(afterHTML,/Change vs regular close/);assert.match(afterHTML,/09\/25\/2026, 19:01:00 ET/);assert.ok(!afterHTML.includes('Change vs prior regular close'));after.store.dispose();
  for(const patch of [{calendar:{}},{calendarError:true},{quoteAt:date('2026-09-27T12:00:00Z')},{quoteAt:null},{quoteAt:'2026-09-28'}]) {
    const unavailable=quoteFixture(patch);await unavailable.store.refreshQuotes();const value=unavailable.store.quotes.get('us:SOXL');assert.equal(value.price,144.1);assert.equal(value.previousClose,null);assert.equal(value.context,null);
    assert.ok(!unavailable.requests.some(req=>req.kind==='candles'));assert.match(S.cardHTML(unavailable.store,unavailable.store.settings.symbols[0],'en'),/Session unavailable/);
    if(patch.quoteAt===null||typeof patch.quoteAt==='string')assert.ok(Number.isNaN(value.quoteAt),'unknown time must not become now or midnight');unavailable.store.dispose();
  }
  for(const patch of [{candleError:true},{quoteAt:date('2026-09-25T23:01:00Z'),daily:soxlDaily.slice(2)}]) {
    const unavailable=quoteFixture(patch);await unavailable.store.refreshQuotes();const value=unavailable.store.quotes.get('us:SOXL');assert.ok(value.context);assert.equal(value.previousClose,null,'no fallback to an older close when the required daily candle is unavailable');assert.equal(S.changeRate(value),null);unavailable.store.dispose();
  }
  const close100=[{date:S.timestamp('2026-09-25','us'),price:100},{date:S.timestamp('2026-09-24','us'),price:98}],krClose100=[{date:S.timestamp('2026-09-26','kr'),price:100},{date:S.timestamp('2026-09-25','kr'),price:98}];
  const expectQuote=(store,price,close)=>{
    const q=[...store.quotes.values()][0],meter=S.cells(store,'en')[0].meter;
    assert.equal(q.price,price);assert.equal(q.previousClose,close);
    if(close==null){assert.equal(S.changeRate(q),null);assert.equal(meter.fraction,null);assert.equal(meter.color,'var(--ink-dim)');}
    else{near(S.changeRate(q),(price-close)/close);assert.equal(meter.color,price<close?'#FF453A':'var(--ample)');assert.equal(meter.counterclockwise,price<close);}
    return q;
  };
  const refreshAt=async(fix,patch={})=>{fix.state.now+=60001;if(patch.quoteAt===undefined)fix.state.quoteAt=fix.state.now;Object.assign(fix.state,patch);await fix.store.refreshQuotes();};
  const usCandle=quoteFixture({price:101,daily:close100});await usCandle.store.refreshQuotes();expectQuote(usCandle.store,101,100);
  await refreshAt(usCandle,{price:99,candleError:true});assert.equal(expectQuote(usCandle.store,99,100).context.phase,'dayMarket');
  await refreshAt(usCandle,{price:99,candleError:false,daily:[{date:S.timestamp('2026-09-25','us'),price:102},{date:S.timestamp('2026-09-24','us'),price:98}]});expectQuote(usCandle.store,99,102);usCandle.store.dispose();
  const usCal=quoteFixture({price:101,daily:close100});await usCal.store.refreshQuotes();expectQuote(usCal.store,101,100);
  await refreshAt(usCal,{price:99,calendarError:true});assert.equal(expectQuote(usCal.store,99,100).context.tradingDay,'2026-09-28');
  await refreshAt(usCal,{price:99,calendarError:false});expectQuote(usCal.store,99,100);usCal.store.dispose();
  for(const error of ['Invalid stock JSON response','Stock response is too large',Error('Invalid stock response')]) {
    const invalid=quoteFixture({price:101,daily:close100});await invalid.store.refreshQuotes();expectQuote(invalid.store,101,100);
    await refreshAt(invalid,{price:99,calendarError:error});assert.equal(expectQuote(invalid.store,99,null).context,null);invalid.store.dispose();
  }
  const krCandle=quoteFixture({price:101,daily:krClose100,symbol:'005930',market:'kr',currency:'KRW'});await krCandle.store.refreshQuotes();expectQuote(krCandle.store,101,100);
  assert.ok(!krCandle.requests.some(req=>req.kind==='calendar'));
  await refreshAt(krCandle,{price:99,candleError:true});expectQuote(krCandle.store,99,100);
  await refreshAt(krCandle,{price:99,candleError:false,daily:[{date:S.timestamp('2026-09-26','kr'),price:102},{date:S.timestamp('2026-09-25','kr'),price:98}]});expectQuote(krCandle.store,99,102);krCandle.store.dispose();
  const krFirst=quoteFixture({price:101,daily:krClose100,symbol:'005930',market:'kr',currency:'KRW',candleError:true});await krFirst.store.refreshQuotes();expectQuote(krFirst.store,101,null);krFirst.store.dispose();
  const emptyDaily=quoteFixture({price:101,daily:close100});await emptyDaily.store.refreshQuotes();await refreshAt(emptyDaily,{price:99,daily:[]});assert.ok(expectQuote(emptyDaily.store,99,null).context);emptyDaily.store.dispose();
  const emptyCal=quoteFixture({price:101,daily:close100});await emptyCal.store.refreshQuotes();await refreshAt(emptyCal,{price:99,calendar:{}});assert.equal(expectQuote(emptyCal.store,99,null).context,null);emptyCal.store.dispose();
  const missingBasis=quoteFixture({price:101,daily:close100});await missingBasis.store.refreshQuotes();await refreshAt(missingBasis,{price:99,daily:[{date:S.timestamp('2026-09-28','us'),price:105}]});expectQuote(missingBasis.store,99,null);missingBasis.store.dispose();
  const regularToAfter=quoteFixture({now:date('2026-09-25T19:58:00Z'),quoteAt:date('2026-09-25T19:58:00Z'),price:101,daily:[{date:S.timestamp('2026-09-24','us'),price:100},{date:S.timestamp('2026-09-23','us'),price:98}]});
  await regularToAfter.store.refreshQuotes();expectQuote(regularToAfter.store,101,100);assert.equal(regularToAfter.store.quotes.get('us:SOXL').context.phase,'regularMarket');
  regularToAfter.state.now=date('2026-09-25T20:00:01Z');regularToAfter.state.quoteAt=regularToAfter.state.now;regularToAfter.state.price=99;regularToAfter.state.candleError=true;
  await regularToAfter.store.refreshQuotes();expectQuote(regularToAfter.store,99,null);assert.equal(regularToAfter.store.quotes.get('us:SOXL').context.phase,'afterMarket');regularToAfter.store.dispose();
  const krNext=quoteFixture({now:date('2026-09-28T01:00:00Z'),quoteAt:date('2026-09-28T01:00:00Z'),price:101,daily:krClose100,symbol:'005930',market:'kr',currency:'KRW'});
  await krNext.store.refreshQuotes();expectQuote(krNext.store,101,100);
  krNext.state.now=date('2026-09-28T16:00:00Z');krNext.state.quoteAt=krNext.state.now;krNext.state.price=99;krNext.state.candleError=true;
  await krNext.store.refreshQuotes();expectQuote(krNext.store,99,null);krNext.store.dispose();
  const wiped=quoteFixture({price:101,daily:close100});await wiped.store.refreshQuotes();expectQuote(wiped.store,101,100);
  wiped.store.invalidate();assert.equal(wiped.store.quotes.size,0);assert.equal(wiped.store.quoteTimes.size,0);
  wiped.state.price=99;wiped.state.candleError=true;await wiped.store.refreshQuotes();expectQuote(wiped.store,99,null);wiped.store.dispose();
  const futureQuote=quoteFixture({quoteAt:sundayQuote+60000});await futureQuote.store.refreshQuotes();assert.equal(futureQuote.store.quotes.size,0,'future trade rejected, not retimestamped');assert.ok(!futureQuote.requests.some(req=>req.kind==='candles'));futureQuote.store.dispose();
  const orderedQuote=quoteFixture();await orderedQuote.store.refreshQuotes();orderedQuote.state.now+=60001;orderedQuote.state.quoteAt--;orderedQuote.state.price=999;await orderedQuote.store.refreshQuotes();assert.equal(orderedQuote.store.quotes.get('us:SOXL').price,144.1,'older REST trade cannot replace a newer quote');
  orderedQuote.state.now+=60001;orderedQuote.state.quoteAt=null;orderedQuote.state.price=145;await orderedQuote.store.refreshQuotes();assert.equal(orderedQuote.store.quotes.get('us:SOXL').price,144.1,'a newer fetch with no trade timestamp cannot replace a known dated quote');assert.equal(orderedQuote.store.quotes.get('us:SOXL').quoteAt,sundayQuote);
  orderedQuote.state.now+=60001;orderedQuote.state.quoteAt=sundayQuote-1;orderedQuote.state.price=998;await orderedQuote.store.refreshQuotes();assert.equal(orderedQuote.store.quotes.get('us:SOXL').price,144.1,'an unknown timestamp cannot erase the last accepted trade watermark');orderedQuote.store.dispose();
  const raced=quoteFixture(),quoteIPC=raced.store.invoke;let releaseCalendar,delayCalendar=true;
  raced.store.invoke=async(cmd,args)=>{if(args.request.kind==='calendar'&&delayCalendar){delayCalendar=false;return new Promise(resolve=>releaseCalendar=resolve);}return quoteIPC(cmd,args);};
  const earlierRefresh=raced.store.refreshQuotes();await flush();assert.equal(typeof releaseCalendar,'function');
  raced.state.now+=1000;raced.state.quoteAt=raced.state.now;raced.state.price=145;
  for(const key of raced.store.cache.keys())if(key.includes('"kind":"prices"')||key.includes('"kind":"calendar"'))raced.store.cache.delete(key);
  await raced.store.refreshQuotes();releaseCalendar({data:quoteCalendar,fetchedAt:sundayQuote});await earlierRefresh;
  assert.equal(raced.store.quotes.get('us:SOXL').price,145,'an older refresh completing last cannot overwrite the newer trade');raced.store.dispose();
  const finnRequests=[],finnStore=new S.Store({owner:true,now:()=>sundayQuote,invoke:async(cmd,{request})=>{assert.equal(cmd,'stock_request');finnRequests.push(request);return {data:{c:104,pc:100,t:sundayQuote/1000},fetchedAt:sundayQuote};}});
  finnStore.settingsReady=true;finnStore.credentials={finnhub:true};finnStore.settings=S.normalizeSettings({enabled:true,provider:'finnhub',symbols:[{symbol:'SOXL',market:'us',visible:true}]});await finnStore.refreshQuotes();near(S.changeRate(finnStore.quotes.get('us:SOXL')),.04);assert.deepEqual(finnRequests,[{kind:'finnhubQuote',symbol:'SOXL'}],'Finnhub keeps its provider previous close and never requests Toss calendar');finnStore.dispose();
  const fridayEnd=date('2026-09-25T20:00:00Z'),boundary=quoteFixture({now:fridayEnd-2000,quoteAt:fridayEnd-2000,daily:[{...soxlDaily[1],price:145},soxlDaily[2]]});
  await boundary.store.refreshQuotes();assert.equal(boundary.store.quotes.get('us:SOXL').previousClose,146.33);
  boundary.state.now=fridayEnd+1000;boundary.state.quoteAt=boundary.state.now;boundary.state.candleFetchedAt=fridayEnd-2000;
  // Simulate a fresh price arriving while native daily data is still cached pre-close.
  boundary.store.cache.delete(JSON.stringify({kind:'prices',symbols:['SOXL']})+'|');await boundary.store.refreshQuotes();
  assert.equal(boundary.store.quotes.get('us:SOXL').context.phase,'afterMarket');assert.equal(boundary.requests.filter(req=>req.kind==='candles').length,2,'phase change invalidates the frontend daily cache');assert.equal(boundary.store.quotes.get('us:SOXL').previousClose,null,'pre-close native snapshot is never an official closing baseline');
  assert.equal([...boundary.store.cache.keys()].filter(key=>key.includes('|quote:')).length,1,'old phase cache removed');
  boundary.state.now=fridayEnd+61001;boundary.state.quoteAt=boundary.state.now;boundary.state.candleFetchedAt=null;boundary.state.daily=soxlDaily;await boundary.store.refreshQuotes();assert.equal(boundary.store.quotes.get('us:SOXL').previousClose,151.45);boundary.store.dispose();

  const events=new Map(),calls=[];let persisted=empty(),clock=r.createdAt;
  const invoke=async(cmd,args)=>{
    calls.push({cmd,args:clone(args)});
    if(cmd==='get_stock_credential_status'){await flush();return {toss:true,finnhub:true};}
    if(cmd==='get_stock_settings')return {...S.DEFAULTS,enabled:true,symbols:[{symbol:'AAPL',market:'us',visible:true}]};
    if(cmd==='load_stock_history')return clone(persisted);
    if(cmd==='save_stock_history'){
      const delta=S.validateHistory(args.history),trends=new Map(persisted.trends.map(v=>[S.trendID(v),v])),forecasts=new Map(persisted.forecasts.map(v=>[S.forecastID(v),v]));
      for(const v of delta.trends)if(!trends.has(S.trendID(v)))trends.set(S.trendID(v),v);
      for(const v of delta.forecasts)forecasts.set(S.forecastID(v),forecasts.get(S.forecastID(v))?.actualClose?forecasts.get(S.forecastID(v)):v);
      persisted={version:1,trends:[...trends.values()],forecasts:[...forecasts.values()]};return clone(persisted);
    }
    if(cmd==='set_stock_settings')return args.settings;
    if(cmd==='stock_request'){
      const req=args.request;
      if(req.kind==='prices')return {data:{result:[{symbol:'AAPL',lastPrice:105,currency:'USD',timestamp:new Date(clock).toISOString()}]},fetchedAt:clock};
      if(req.kind==='names')return {data:{result:[{symbol:'AAPL',name:'Apple'}]},fetchedAt:clock};
      if(req.kind==='calendar')return {data:quoteCalendar,fetchedAt:clock};
      if(req.kind==='candles')return {data:req.count===3?dailyRaw(daily):req.adjusted===false?dailyRaw([{date:S.timestamp('2026-09-28','us'),price:106}]):raw(b),fetchedAt:clock};
      if(req.kind==='finnhubQuote')return {data:{c:105,pc:100,t:clock/1000},fetchedAt:clock};
      throw Error('Unexpected request '+req.kind);
    }
    throw Error('Unexpected IPC '+cmd);
  };
  const store=new S.Store({invoke,now:()=>clock,owner:true,listen:async(name,fn)=>{events.set(name,fn);return ()=>{};}});
  await store.init();while(store.ticking)await flush();
  assert.equal(store.settingsReady,true);assert.equal(store.settings.enabled,true,'async credential invalidation must not skip initial settings');near(S.changeRate(store.quotes.get('us:AAPL')),.05);
  assert.ok(!calls.some(c=>['accounts','holdings'].includes(c.args?.request?.kind)),'no account calls before opt-in');
  const quoteCalls=calls.filter(c=>c.cmd==='stock_request').length;await store.tick();assert.equal(calls.filter(c=>c.cmd==='stock_request').length,quoteCalls,'display/control tick uses native response cache');
  await store.loadChart({symbol:'AAPL',market:'us'},'10m');assert.ok(calls.some(c=>c.args?.request?.interval==='10m'&&c.args.request.count===1400));
  const chartCalls=calls.length;await store.loadChart({symbol:'AAPL',market:'us'},'10m');assert.equal(calls.length,chartCalls,'hover cache reused');
  await store.persist(history=>S.appendSamples(history,[r],false));assert.equal(persisted.trends.length,1);assert.equal(persisted.forecasts.length,0);
  clock=r.createdAt+60000;await store.persist(history=>S.appendSamples(history,[record(clock)],false));assert.equal(calls.filter(c=>c.cmd==='save_stock_history').at(-1).args.history.trends.length,1,'only new compact points transmitted');
  clock=r.createdAt+120000;persisted.forecasts=[resolved];await store.persist(history=>S.appendSamples(history,[record(clock)],false));assert.equal(store.history.forecasts[0].actualClose,106,'consume merged native union including unseen scored records');
  const reloaded=new S.Store({invoke,owner:true,now:()=>clock});await reloaded.loadHistory();assert.deepEqual(reloaded.history,store.history,'minute samples survive process/store restart');
  const disabled={...store.settings,enabled:false};store.configure(disabled);const disabledCount=calls.length;await store.tick();await store.loadChart({symbol:'AAPL',market:'us'});assert.equal(calls.length,disabledCount,'disabled does not issue requests');
  store.configure({...store.settings,enabled:true,provider:'finnhub',symbols:[{symbol:'005930',market:'kr',visible:true}]});while(store.ticking)await flush();const unsupportedCount=calls.length;await store.loadChart({symbol:'005930',market:'kr'});assert.equal(calls.length,unsupportedCount);
  await assert.rejects(store.request({kind:'accounts'}));await assert.rejects(store.request({kind:'candles'}));
  store.dispose();reloaded.dispose();

  let resolve;
  const stale=new S.Store({invoke:()=>new Promise(r=>resolve=r),now:()=>clock});stale.settingsReady=true;stale.settings=S.normalizeSettings({enabled:true,provider:'toss'});stale.credentials={toss:true,finnhub:true};
  const pending=stale.request({kind:'prices',symbols:['AAPL']});stale.configure({...stale.settings,enabled:false});resolve({data:{result:[]},fetchedAt:clock});await assert.rejects(pending,/Stale/);assert.equal(stale.quotes.size,0);stale.dispose();
  // Full opt-in loop: public-only history, official session, scheduled snapshot,
  // null-save success, next-local-day unadjusted reconciliation, no account replays.
  let portfolioNow=r.createdAt,portfolioQuoteLead=0,portfolioDisk=empty(),portfolioCalls=[];
  const portfolioIPC=async(cmd,args)=>{
    portfolioCalls.push({cmd,args:clone(args)});
    if(cmd==='save_stock_history'){
      S.validateHistory(args.history);
      const trends=new Map(portfolioDisk.trends.map(v=>[S.trendID(v),v])),forecasts=new Map(portfolioDisk.forecasts.map(v=>[S.forecastID(v),v]));
      for(const v of args.history.trends)trends.set(S.trendID(v),v);
      for(const v of args.history.forecasts)forecasts.set(S.forecastID(v),v);
      portfolioDisk={version:1,trends:[...trends.values()],forecasts:[...forecasts.values()]};return null;
    }
    if(cmd==='load_stock_history')return clone(portfolioDisk);
    if(cmd!=='stock_request')throw Error('Unexpected portfolio command '+cmd);
    const req=args.request;
    const results={accounts:{result:[{accountSeq:17,accountType:'BROKERAGE',accountNo:'PRIVATE-ACCOUNT-NUMBER'}]},holdings:{result:{items:[{symbol:'AAPL',marketCountry:'US',name:'Apple',currency:'USD',quantity:123,balance:9999}]}},calendar:{result:{today:{regularMarket:{startTime:new Date(start).toISOString(),endTime:new Date(end).toISOString()}},previousBusinessDay:{},nextBusinessDay:{}}},prices:{result:[{symbol:'AAPL',lastPrice:104,currency:'USD',timestamp:new Date(portfolioNow+portfolioQuoteLead).toISOString()}]}};
    return {data:req.kind==='candles'?(req.adjusted===false?dailyRaw([{date:S.timestamp('2026-09-28','us'),price:106}]):dailyRaw(closes)):results[req.kind],fetchedAt:portfolioNow};
  };
  const futurePortfolio=new S.Store({owner:true,invoke:portfolioIPC,now:()=>portfolioNow});
  futurePortfolio.settingsReady=true;futurePortfolio.credentials={toss:true};futurePortfolio.settings=S.normalizeSettings({enabled:true,forecastsEnabled:true,recordForecasts:true,accountSeq:17});futurePortfolio.history=empty();
  portfolioQuoteLead=60000;await futurePortfolio.refreshForecasts();assert.equal(futurePortfolio.candidates.length,0,'future quote must not advance the capture clock');assert.equal(portfolioDisk.trends.length,0);assert.equal(portfolioDisk.forecasts.length,0);assert.ok(!portfolioCalls.some(c=>c.cmd==='save_stock_history'));
  assert.equal(await futurePortfolio.persist(history=>S.appendSamples(history,[record(portfolioNow+60000)],true)),false,'durable boundary rejects future-created samples too');assert.equal(portfolioDisk.trends.length,0);futurePortfolio.dispose();portfolioQuoteLead=0;portfolioCalls=[];
  const portfolio=new S.Store({owner:true,invoke:portfolioIPC,now:()=>portfolioNow});
  portfolio.settingsReady=true;portfolio.credentials={toss:true};portfolio.settings=S.normalizeSettings({...S.DEFAULTS,enabled:true,forecastsEnabled:true,recordForecasts:true,accountSeq:17});portfolio.history=empty();
  await portfolio.refreshForecasts();assert.equal(portfolio.candidates.length,1);assert.equal(portfolio.history.trends.length,1);assert.equal(portfolio.history.forecasts.length,1);assert.equal(portfolio.history.forecasts[0].capture,'scheduled');
  assert.ok(portfolioCalls.some(c=>c.args?.request?.kind==='calendar'&&c.args.request.date==='2026-09-28'));
  assert.ok(!portfolioCalls.some(c=>c.cmd==='load_stock_history'),'null success does not force full archive reload');
  const diskText=JSON.stringify(portfolioDisk);for(const secret of ['accountSeq','accountNo','quantity','balance','PRIVATE-ACCOUNT-NUMBER'])assert.ok(!diskText.includes(secret));
  portfolioNow+=60000;await portfolio.refreshForecasts();assert.equal(portfolio.history.trends.length,2);assert.equal(portfolio.history.forecasts.length,1);assert.equal(portfolioCalls.filter(c=>c.args?.request?.kind==='accounts').length,0,'saved positive selection fetches holdings without automatic account lookup');
  const loadsBefore=portfolioCalls.length;await portfolio.reconcile();assert.equal(portfolioCalls.length,loadsBefore,'not scored on same local date');
  portfolioNow=S.timestamp('2026-09-29','us');await portfolio.reconcile();assert.equal(portfolio.history.forecasts[0].actualClose,106);assert.equal(portfolio.history.forecasts[0].evaluatedAt,portfolioNow);assert.equal(portfolio.history.trends.length,2,'scoring cannot alter traces');
  const scoring=portfolioCalls.find(c=>c.args?.request?.adjusted===false).args.request;assert.equal(scoring.count,2);assert.equal(scoring.before,new Date(end).toISOString());portfolio.dispose();
  // Public watchlist forecasts must never depend on discovering or reading accounts.
  portfolioNow=r.createdAt;portfolioCalls=[];
  const watched=new S.Store({invoke:portfolioIPC,now:()=>portfolioNow});watched.settingsReady=true;watched.credentials={toss:true};watched.settings=S.normalizeSettings({enabled:true,forecastsEnabled:true,accountSeq:0,symbols:[{symbol:'AAPL',market:'us',name:'Apple',visible:false}]});watched.history=empty();
  await watched.refreshForecasts();assert.equal(watched.candidates.length,1,'hidden watched stock still receives predictions');assert.equal(watched.candidates[0].expectedClose,104);assert.ok(!portfolioCalls.some(c=>['accounts','holdings'].includes(c.args?.request?.kind)),'zero account makes no private requests');await assert.rejects(watched.request({kind:'holdings',accountSeq:17}));
  await watched.loadAccounts();assert.equal(watched.accounts.length,1);assert.equal(watched.settings.accountSeq,0,'explicit lookup does not auto-select even one account');assert.equal(portfolioCalls.filter(c=>c.args?.request?.kind==='accounts').length,1);assert.ok(!portfolioCalls.some(c=>c.args?.request?.kind==='holdings'));watched.dispose();
  for(const privateMode of ['failure','empty','held']){
    portfolioCalls=[];const privateCalls=[];
    const optional=new S.Store({now:()=>portfolioNow,invoke:async(cmd,args)=>{if(['accounts','holdings'].includes(args?.request?.kind)){privateCalls.push(args.request.kind);if(privateMode==='failure')throw Error('Private access denied');if(privateMode==='empty'&&args.request.kind==='holdings')return {data:{result:{items:[]}},fetchedAt:portfolioNow};}return portfolioIPC(cmd,args);}});
    optional.settingsReady=true;optional.credentials={toss:true};optional.settings=S.normalizeSettings({...watched.settings,accountSeq:17});optional.history=empty();
    await optional.refreshForecasts();assert.equal(optional.candidates.length,1,privateMode+' holdings cannot block/duplicate watched forecast');assert.deepEqual(optional.forecastStocks.map(S.stockID),['us:AAPL']);assert.deepEqual(privateCalls,['holdings']);assert.equal(portfolioCalls.filter(c=>c.args?.request?.kind==='candles').length,1,'deduplicated public inputs fetched once');
    if(privateMode==='failure'){assert.ok(optional.accountError.includes('holdings'));await optional.loadAccounts();assert.ok(optional.accountError.includes('accounts'));await optional.refreshForecasts();assert.equal(optional.candidates.length,1,'failed explicit accounts discovery also leaves public forecasts working');}
    assert.equal(optional.forecastError,'');optional.dispose();
  }
  // Review regressions: cache failures retry in <=10m and successes retain native age.
  const activeStore=(invoke,now)=>{const result=new S.Store({invoke,now,owner:true});result.settingsReady=true;result.credentials={toss:true};result.settings=S.normalizeSettings({enabled:true,forecastsEnabled:true});result.history=empty();return result;};
  const dailyRequest={kind:'candles',symbol:'AAPL',market:'us',interval:'1d',count:200,adjusted:true};
  let reviewNow=r.createdAt,requestAttempts=0;
  const retryRequest=activeStore(async()=>{requestAttempts++;if(requestAttempts===1)throw Error('Temporary failure');return {data:raw(b),fetchedAt:reviewNow};},()=>reviewNow);
  await assert.rejects(retryRequest.request(dailyRequest,S.TTL['1d']));reviewNow+=599999;await assert.rejects(retryRequest.request(dailyRequest,S.TTL['1d']));assert.equal(requestAttempts,1);reviewNow++;await retryRequest.request(dailyRequest,S.TTL['1d']);assert.equal(requestAttempts,2,'daily request retries after ten minutes');retryRequest.dispose();
  let chartAttempts=0;reviewNow=r.createdAt;
  const retryChart=activeStore(async()=>{chartAttempts++;if(chartAttempts===1)throw Error('Temporary failure');return {data:raw(b),fetchedAt:reviewNow};},()=>reviewNow);
  await retryChart.loadChart({symbol:'AAPL',market:'us'},'1d');reviewNow+=599999;await retryChart.loadChart({symbol:'AAPL',market:'us'},'1d');assert.equal(chartAttempts,1);reviewNow++;await retryChart.loadChart({symbol:'AAPL',market:'us'},'1d');assert.equal(chartAttempts,2);assert.equal(retryChart.charts.get('us:AAPL|1d').error,'');retryChart.dispose();
  let malformedAttempts=0;const malformed=activeStore(async()=>({data:++malformedAttempts===1?{result:{candles:[{}]}}:raw(b),fetchedAt:reviewNow}),()=>reviewNow);
  await malformed.loadChart({symbol:'AAPL',market:'us'},'1d');assert.ok(malformed.charts.get('us:AAPL|1d').error);reviewNow+=600000;await malformed.loadChart({symbol:'AAPL',market:'us'},'1d');assert.equal(malformedAttempts,2,'invalid candle payload must not stay a successful daily cache entry');assert.equal(malformed.charts.get('us:AAPL|1d').error,'');malformed.dispose();
  for(const chart of [false,true]){
    reviewNow=r.createdAt;let attempts=0;const fetchedAt=reviewNow-23*3600000;
    const aged=activeStore(async()=>({data:raw(b),fetchedAt:++attempts===1?fetchedAt:reviewNow}),()=>reviewNow);
    const load=()=>chart?aged.loadChart({symbol:'AAPL',market:'us'},'1d'):aged.request(dailyRequest,S.TTL['1d']);
    await load();reviewNow+=3599999;await load();assert.equal(attempts,1);reviewNow++;await load();assert.equal(attempts,2,`${chart?'chart':'request'} must expire one hour after receiving a 23h-old native response`);aged.dispose();
  }
  const invalidFetched=activeStore(async()=>({data:raw(b),fetchedAt:reviewNow+60000}),()=>reviewNow);await assert.rejects(invalidFetched.request(dailyRequest,S.TTL['1d']),/response/);invalidFetched.dispose();
  const staleFetched=activeStore(async()=>({data:raw(b),fetchedAt:reviewNow-S.TTL['1d']}),()=>reviewNow);await assert.rejects(staleFetched.request(dailyRequest,S.TTL['1d']),/response/);staleFetched.dispose();

  reviewNow=S.timestamp('2026-09-29','us');const reconciliationRequests=[];
  const fair=activeStore(async(cmd,args)=>{if(cmd==='save_stock_history')return null;const req=args.request;reconciliationRequests.push(req.symbol);return {data:dailyRaw(req.symbol==='TK20'?[{date:S.timestamp('2026-09-28','us'),price:106}]:[]),fetchedAt:reviewNow};},()=>reviewNow);
  fair.history={version:1,trends:[],forecasts:Array.from({length:21},(_,i)=>record(r.createdAt,{stockID:'us:TK'+i,name:'TK'+i}))};S.validateHistory(fair.history);
  await fair.reconcile();assert.equal(reconciliationRequests.length,20);reviewNow+=60000;await fair.reconcile();assert.equal(reconciliationRequests.at(-1),'TK20','cooling first20 must not starve the next eligible group');assert.equal(reconciliationRequests.length,21);assert.equal(fair.history.forecasts[20].actualClose,106);assert.ok(fair.history.forecasts.slice(0,20).every(v=>v.actualClose===null));fair.dispose();
  let writes=0;
  const corrupt=new S.Store({owner:true,invoke:async cmd=>{if(cmd==='load_stock_history')return {version:7,trends:[],forecasts:[]};writes++;},now:()=>clock});await corrupt.loadHistory();await corrupt.persist(()=>h);assert.equal(writes,0,'unreadable archive must never reset or overwrite');assert.ok(corrupt.historyError);corrupt.dispose();

  const html=fs.readFileSync(path.join(__dirname,'../penguinnotch/ui/settings.html'),'utf8'),notch=fs.readFileSync(path.join(__dirname,'../penguinnotch/ui/notch.html'),'utf8');
  assert.match(html,/id="tab-stocks"/);assert.match(html,/id="pane-stocks"/);assert.match(notch,/open_network_settings/);
  assert.match(notch,/PenguinNotchStocks\.cells/);assert.match(notch,/PenguinNotchStocks\.bindCard/);
  console.log('PASS stock quote/session/bars/SMA/volume/GBM/history/privacy/cache/IPC regressions');
}
main().catch(error=>{console.error(error);process.exit(1);});
