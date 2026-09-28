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
