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

function testForecastEvaluation() {
  const fixture=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../Tests/Fixtures/stock-forecast-evaluation-v1.json'),'utf8'));
  const rows=S.evaluationRows(fixture.records),comparison=S.evaluationComparison(rows,['A','B']);
  assert.equal(rows.length,3);assert.equal(comparison.pairedCount,1);
  assert.deepEqual(comparison.rows.map(r=>r.model),['A','B']);
  assert.ok(comparison.rows.every(r=>r.paired.evaluated===1));
  assert.equal(S.evaluationComparison(rows,['A','B','C']).pairedCount,0);
  const equivalent=S.evaluationComparison(fixture.rows,['A','B']);
  assert.equal(equivalent.pairedCount,1);assert.equal(equivalent.rows[0].available.evaluated,1);
  assert.equal(S.evaluationMetrics(fixture.rows.slice(0,2)).evaluated,1);
  assert.deepEqual(S.coalescedEvaluationRows(fixture.rows)[0].references.map(r=>r.source),['recorded','pairedCalculation']);
  const [a,paired,b]=fixture.rows;
  const conflict=S.evaluationComparison([a,{...paired,expectedClose:103},b],['A','B']);
  assert.equal(conflict.pairedCount,0);assert.equal(conflict.excludedConflicts,1);
  assert.equal(S.evaluationComparison([a,{...paired,riseProbability:paired.riseProbability+Number.EPSILON},b],['A','B']).pairedCount,0,'one representable output difference is a conflict');
  assert.equal(S.evaluationComparison([a,a,b],['A','B']).pairedCount,0);
  for(const patch of [{actualClose:106},{inputKey:'different-evidence'},{capture:'scheduled'},{currency:'KRW'},{inputPrice:103},{inputKey:null}]) {
    assert.equal(S.evaluationComparison([a,{...b,...patch}],['A','B']).pairedCount,0);
  }
  const legacy={...a,inputKey:null};
  assert.equal(S.evaluationMetrics([legacy]).evaluated,1);
  assert.equal(S.evaluationComparison([legacy],['A']).pairedCount,1);
  assert.equal(S.evaluationComparison([legacy,b],['A','B']).excludedMissingEvidence,1);
  assert.equal(S.evaluationComparison(rows,[]).pairedCount,0);
  for(const sample of fixture.metricCases) {
    const metrics=S.evaluationMetrics(sample.rows);
    for(const [key,wanted] of Object.entries(sample.expected)) {
      if(key==='maeByCurrency') {
        assert.deepEqual(Object.keys(metrics[key]).sort(),Object.keys(wanted).sort());
        for(const [currency,value] of Object.entries(wanted))near(metrics[key][currency],value,1e-6);
      } else if(wanted===null)assert.equal(metrics[key],null,sample.name+' '+key);
      else near(metrics[key],wanted,1e-6);
    }
  }
  const legacyRecord={...fixture.records[0],evidence:null};
  assert.equal(S.validForecast(legacyRecord),true);assert.equal(S.evaluationRows([legacyRecord])[0].inputKey,null);
  assert.equal(S.chartEstimate(legacyRecord,[],'1d',legacyRecord.createdAt),null,'legacy history has no candles to recompute');
  assert.equal(S.evidenceHTML(legacyRecord,'en'),'','legacy history cannot invent evidence');
  const legacySignal=S.technical(bars(),'1d','us',end,end,legacyRecord);
  assert.ok(legacySignal===null||legacySignal.live===false,'missing evidence cannot confirm a live signal');
  assert.equal(S.evaluationRows([{...legacyRecord,currency:'KRW'}]).length,0);
  const differentQuote={...fixture.records[1],quoteAt:fixture.records[1].quoteAt-.25};
  assert.equal(S.validForecast(differentQuote),true);
  const exactInputs=S.evaluationRows([fixture.records[0],differentQuote]);
  assert.equal(exactInputs.length,2,'valid old quote precision cannot be dropped');
  assert.notEqual(exactInputs[0].inputKey,exactInputs[1].inputKey);
  assert.equal(S.evaluationComparison(exactInputs,['A','B']).pairedCount,0);
  const nearestEarlier={...fixture.records[1],quoteAt:fixture.records[1].quoteAt-.000244140625};
  assert.notEqual(nearestEarlier.quoteAt,fixture.records[1].quoteAt);
  assert.equal(S.evaluationComparison(S.evaluationRows([fixture.records[0],nearestEarlier]),['A','B']).pairedCount,0);
  assert.equal(S.evaluationComparison([a,{...b,source:'replay'}],['A','B']).pairedCount,0,'replay never joins recorded captures');
  assert.equal(S.evaluationMetrics([a,{...paired,inputKey:'different-frozen-input'}]).evaluated,2,'same model on different inputs is not a duplicate');
  const huge={...a,inputPrice:1e-308,actualClose:1e-308,expectedClose:1e308,lowerClose:1e-308,upperClose:1e308};
  const overflow=S.evaluationMetrics([huge]);assert.equal(overflow.evaluated,1);assert.equal(overflow.mape,null);assert.equal(overflow.meanWidthPercent,null);
  assert.equal(S.evaluationMetrics([huge,a]).mape,null,'overflow cannot disappear from an aggregate');
  const baseline=S.evaluationMetrics([{...a,expectedClose:a.inputPrice,riseProbability:null,lowerClose:null,upperClose:null}]);
  assert.equal(baseline.brier,null);assert.equal(baseline.coverage,null);
  const old=S.score([fixture.records[0]]);near(old.mape,100/105);near(old.range,1);near(old.brier,.04);assert.equal(old.accuracy,1);
  assert.equal(S.compareModels(fixture.records,['A','B']).pairedCount,1);
  console.log('PASS shared evaluation fixture, selected cohorts, deduplication/provenance, units, pending/legacy/conflicts and overflow');
}

// Synthetic accounts only. No credentials, provider traffic or persistent viewer data.
const accountList=()=>({result:[{accountSeq:7,accountNo:'•••• 5678',accountType:'BROKERAGE'},{accountSeq:8,accountNo:'••••',accountType:'BROKERAGE'}]});
function overviewFixture(patch={}) {
  const price=(krw,usd)=>({krw,usd});
  const item={symbol:'AAPL',name:'Apple',marketCountry:'US',currency:'USD',quantity:'0.125000000000000000000001',lastPrice:'220.00',averagePurchasePrice:'200.00',marketValue:{purchaseAmount:'25.00',amount:'27.50',amountAfterCost:'27.25'},profitLoss:{amount:'2.50',amountAfterCost:'2.25',rate:'0.10',rateAfterCost:'0.09'},dailyProfitLoss:{amount:'-0.50',rate:'-0.017857'},cost:{commission:'0.25',tax:null}};
  return {result:{totalPurchaseAmount:price('9007199254740993','25.00'),marketValue:{amount:price('9007199254740994','27.50'),amountAfterCost:price('9007199254740994','27.25')},profitLoss:{amount:price('1','2.50'),amountAfterCost:price('1','2.25'),rate:'0.0001',rateAfterCost:'0.00009'},dailyProfitLoss:{amount:price('-100',null),rate:'-0.0125'},items:[item],...patch}};
}
async function testAccountViewer(){
  const parsed=S.decodeAccountOverview(overviewFixture());
  assert.equal(parsed.items[0].quantity,'0.125000000000000000000001');
  assert.equal(parsed.dailyProfitLoss.amount.usd,null);assert.equal(parsed.items[0].cost.tax,null);
  assert.equal(S.accountMoneyText('9007199254740993.25','USD','en'),'9,007,199,254,740,993.25 USD','money strings reach Intl without a Number conversion');
  assert.equal(S.accountMoneyText('0','KRW','en'),'0 KRW');assert.equal(S.accountMoneyText('-12.25','USD','en'),'-12.25 USD');assert.equal(S.accountMoneyText(null,'USD','ko'),'—');
  assert.equal(S.accountRateText('-0.0125'),'-1.25%');assert.equal(S.accountRateText('0.10005'),'+10.01%');assert.equal(S.accountRateText('-0.10005'),'-10.01%');assert.equal(S.accountRateText('0.10'),'+10.00%');assert.equal(S.accountRateText('0'),'+0.00%');
  assert.equal(S.accountRateText('9007199254740993.0001'),'+900719925474099300.01%','ratio is multiplied as a decimal string');
  assert.deepEqual(S.decodeAccounts({result:[{accountSeq:1,accountNo:'1234',accountType:'BROKERAGE'},{accountSeq:2,accountNo:'12345678',accountType:'BROKERAGE'},{accountSeq:3,accountNo:'•••• 5678',accountType:'BROKERAGE'},{accountSeq:4,accountNo:'5678',accountType:'FUTURE_TYPE'}]}),[{accountSeq:1,label:'••••'},{accountSeq:2,label:'•••• 5678'},{accountSeq:3,label:'•••• 5678'}]);
  for(const seq of [0,-1,1.5,Number.MAX_SAFE_INTEGER+1,'7',null])assert.throws(()=>S.decodeAccounts({result:[{accountSeq:seq,accountNo:'••••',accountType:'BROKERAGE'}]}));
  assert.throws(()=>S.decodeAccounts({result:[...accountList().result,accountList().result[0]]}));
  assert.throws(()=>S.decodeAccounts({result:[{accountSeq:1,accountNo:'',accountType:'BROKERAGE'}]}));
  for(const value of [null,undefined,12,'',' ','NaN','Infinity','1e3','0x10','1,000','1'.repeat(31),'--1','1\n','1\r','1\r\n','1\u2028','1\u2029']){
    const bad=overviewFixture();bad.result.items[0].averagePurchasePrice=value;assert.throws(()=>S.decodeAccountOverview(bad),undefined,'bad decimal rejects the whole overview');
  }
  const invalidMutations=[
    r=>r.items.push(clone(r.items[0])),r=>r.items.push({...clone(r.items[0]),symbol:'MSFT',quantity:'NaN'}),
    r=>r.items[0].currency='KRW',r=>r.items[0].currency='eur',r=>r.items[0].marketCountry='X'.repeat(21),r=>r.items[0].symbol='US:AAPL',
    r=>r.items[0].quantity='-0.5',r=>r.items[0].profitLoss.rate=null,r=>r.items[0].cost.tax='bogus',
    r=>r.totalPurchaseAmount.krw=null,r=>r.marketValue.amountAfterCost.usd='NaN',r=>r.profitLoss.rateAfterCost='bogus',
    r=>r.items=null,r=>delete r.items[0].dailyProfitLoss,r=>r.items[0].name=null
  ];
  for(const mutate of invalidMutations){const bad=overviewFixture();mutate(bad.result);assert.throws(()=>S.decodeAccountOverview(bad));}
  for(const name of ['', '   ']){const blankName=overviewFixture();blankName.result.items[0].name=name;assert.equal(S.decodeAccountOverview(blankName).items[0].name,'AAPL','blank names fall back to the symbol');}
  for(const ending of ['\n','\r','\r\n','\u2028','\u2029'])for(const field of ['marketCountry','currency','symbol']){
    const bad=overviewFixture();bad.result.items[0]={...bad.result.items[0],marketCountry:'JP',currency:'JPY',symbol:'7203'};bad.result.items[0][field]+=ending;assert.throws(()=>S.decodeAccountOverview(bad),'private metadata cannot end with a line separator');
  }
  const kr=overviewFixture();kr.result.items=[{...kr.result.items[0],symbol:'005930',name:'삼성전자',marketCountry:'KR',currency:'KRW',quantity:'1.5'}];assert.equal(S.decodeAccountOverview(kr).items[0].quantity,'1.5');
  const optionalNull=overviewFixture();delete optionalNull.result.totalPurchaseAmount.usd;delete optionalNull.result.items[0].cost.tax;assert.equal(S.decodeAccountOverview(optionalNull).totalPurchaseAmount.usd,null);assert.equal(S.decodeAccountOverview(optionalNull).items[0].cost.tax,null);
  for(const decoder of [S.decodeAccounts,S.decodeAccountOverview])assert.throws(()=>decoder({...decoder===S.decodeAccounts?accountList():overviewFixture(),error:{code:'FAILED'}}),'nonnull envelope.error always rejects');
  const unknown=overviewFixture();unknown.result.items[0]={...unknown.result.items[0],marketCountry:'JP',currency:'JPY',symbol:'7203',lastPrice:'9007199254740993.012345'};
  const unknownItem=S.decodeAccountOverview(unknown).items[0];assert.equal(unknownItem.unsupported,true);assert.equal(unknownItem.marketCountry,'JP');assert.equal(S.accountMoneyText(unknownItem.lastPrice,unknownItem.currency,'en'),'9007199254740993.012345 JPY');
  const unknownCurrency=overviewFixture();unknownCurrency.result.items[0].currency='EUR';assert.equal(S.decodeAccountOverview(unknownCurrency).items[0].unsupported,true,'known market/new currency is safely retained');

  let now=start,reply=overviewFixture(),failure=false;const calls=[];
  const viewer=new S.Store({now:()=>now,invoke:async(cmd,args)=>{
    calls.push({cmd,args:clone(args)});
    if(cmd==='get_stock_credential_status')return {toss:true,finnhub:true};
    if(cmd==='get_stock_settings')return {...S.DEFAULTS,accountSeq:17};
    if(cmd==='load_stock_history')return empty();
    if(cmd==='set_stock_settings')return args.settings;
    assert.equal(cmd,'stock_request');
    if(failure)throw Error('Synthetic unavailable');
    return {data:clone(args.request.kind==='accounts'?accountList():reply),fetchedAt:now};
  }});
  await viewer.init();assert.equal(calls.filter(c=>c.cmd==='stock_request').length,0,'no auto discovery or quotes with both flags off');
  assert.equal(viewer.viewerAvailable(),true);assert.equal(viewer.active(),false);
  for(const req of [{kind:'prices',symbols:['AAPL']},{kind:'candles',symbol:'AAPL'},{kind:'holdings',accountSeq:17},{kind:'accountOverview',accountSeq:7}])await assert.rejects(viewer.request(req));
  await viewer.loadViewerAccounts();assert.equal(viewer.viewerAccountSeq,0);assert.equal(viewer.viewerOverview,null);assert.equal(viewer.settings.accountSeq,17);assert.deepEqual(viewer.accounts,[],'viewer discovery does not feed the forecast picker');
  const privateCount=()=>calls.filter(c=>c.cmd==='stock_request').length;
  const count=privateCount();await viewer.tick();await viewer.refreshForecasts();assert.equal(privateCount(),count,'timer/forecasts never refresh the private viewer');
  for(const seq of [-1,1.5,Number.MAX_SAFE_INTEGER+1,'7',9]){await viewer.selectViewerAccount(seq);assert.equal(privateCount(),count,'invalid/undiscovered viewer sequences make no call');}
  for(const req of [{kind:'accounts',accountSeq:7},{kind:'accountOverview',accountSeq:7,symbol:'AAPL'},{kind:'accountOverview',accountSeq:7,market:'us'}])await assert.rejects(viewer.request(req));
  await viewer.selectViewerAccount(7);assert.deepEqual(calls.at(-1).args.request,{kind:'accountOverview',accountSeq:7});assert.equal(viewer.viewerOverview.items.length,1);assert.equal(viewer.settings.accountSeq,7);assert.deepEqual(viewer.holdings,[]);assert.deepEqual(viewer.forecastStocks,[]);assert.deepEqual(viewer.candidates,[]);assert.deepEqual(viewer.history,empty());
  const en=S.accountViewerHTML(viewer,'en'),ko=S.accountViewerHTML(viewer,'ko');
  assert.match(en,/My Toss account/);assert.match(ko,/내 토스 계좌/);assert.match(ko,/보유 수량/);assert.match(en,/0\.125000000000000000000001/);assert.match(en,/9,007,199,254,740,993 KRW/);assert.match(en,/-1\.25%/);assert.match(en,/API overall rates use KRW conversion/);assert.match(en,/>—<\/td>/);assert.ok(!en.includes('accountSeq')&&!en.includes('Export'));
  assert.ok(en.indexOf('Overall P&amp;L rate')>en.indexOf('</table>'),'overall ratio is outside currency rows');
  assert.match(en,/Cash\/bonds\/options excluded\./);assert.match(ko,/현금·채권·옵션은 포함하지 않습니다\./);
  assert.match(en,/data-stock-disclosure="account-costs:7"/);
  const positionDetails=en.match(/<details data-stock-disclosure="position-costs:7:us:AAPL">([\s\S]*?)<\/details>/)?.[1];
  assert.ok(positionDetails);assert.equal((positionDetails.match(/<dt>/g)||[]).length,5);
  assert.match(positionDetails,/<dt>Investment<\/dt><dd>25\.00 USD<\/dd>/);
  assert.match(positionDetails,/<dt>Market value after costs<\/dt><dd>27\.25 USD<\/dd>/);
  assert.match(positionDetails,/<dt>P&amp;L after costs<\/dt><dd>2\.25 USD · \+9\.00%<\/dd>/);
  assert.match(positionDetails,/<dt>Commission<\/dt><dd>0\.25 USD<\/dd>/);assert.match(positionDetails,/<dt>Tax<\/dt><dd>—<\/dd>/);
  assert.match(ko,/<dt>비용 공제 후 평가금액<\/dt>/);assert.match(ko,/<dt>비용 공제 후 평가손익<\/dt>/);assert.match(ko,/<dt>세금<\/dt><dd>—<\/dd>/);
  viewer.viewerOverview=S.decodeAccountOverview(unknown);assert.match(S.accountViewerHTML(viewer,'en'),/JP:7203/);assert.match(S.accountViewerHTML(viewer,'en'),/Unsupported market or currency/);assert.match(S.accountViewerHTML(viewer,'en'),/9007199254740993\.012345 JPY/);assert.deepEqual(viewer.forecastStocks,[]);
  reply.result.items[0].name='<img src=x onerror=alert(1)>';await viewer.selectViewerAccount(7);assert.match(S.accountViewerHTML(viewer,'en'),/&lt;img/);assert.ok(!S.accountViewerHTML(viewer,'en').includes('<img'));
  const noCacheCount=privateCount();await viewer.selectViewerAccount(7);assert.equal(privateCount(),noCacheCount+1,'same selection is a fresh explicit read');assert.equal(viewer.cache.size,0,'viewer success never enters shared JS cache');
  viewer.configure({...viewer.settings,accountSeq:99,chartInterval:'1d'});assert.equal(viewer.viewerAccountSeq,7);assert.ok(viewer.viewerOverview,'forecast selection changes do not alter the viewer');
  reply=overviewFixture({items:[]});await viewer.selectViewerAccount(8);assert.equal(viewer.viewerOverview.items.length,0);assert.match(S.accountViewerHTML(viewer,'en'),/No stock holdings/);
  failure=true;await viewer.selectViewerAccount(8);assert.equal(viewer.viewerOverview,null);assert.ok(viewer.viewerError);assert.equal(viewer.cache.size,0,'no private error cache');failure=false;
  reply=overviewFixture();reply.result.items.push({...reply.result.items[0],symbol:'MSFT',quantity:'invalid'});await viewer.selectViewerAccount(8);assert.equal(viewer.viewerOverview,null);assert.ok(viewer.viewerError,'one malformed position prevents partial financial display');
  viewer.clearViewer();assert.equal(viewer.viewerAccounts.length,0);assert.equal(viewer.viewerAccountSeq,0);assert.equal(viewer.viewerOverview,null);assert.equal(viewer.viewerFetchedAt,null);assert.ok(!S.accountViewerHTML(viewer,'en').includes('900719'));
  assert.ok(calls.every(c=>c.cmd!=='save_stock_history'),'viewer never writes private data to history');assert.deepEqual(calls.filter(c=>c.cmd==='set_stock_settings').map(c=>c.args.settings.accountSeq),[7,8],'only explicit choices update already-enabled holdings');viewer.dispose();

  const pending=[];let responseNow=start;
  const race=new S.Store({now:()=>responseNow,invoke:(cmd,args)=>cmd==='set_stock_settings'?Promise.resolve(args.settings):new Promise((resolve,reject)=>pending.push({request:args.request,resolve,reject}))});
  race.settingsReady=true;race.credentials={toss:true,finnhub:true};race.settings=S.normalizeSettings({accountSeq:17});
  const resolvePrivate=(p,data=overviewFixture())=>p.resolve({data,fetchedAt:responseNow});
  let task=race.loadViewerAccounts();resolvePrivate(pending.at(-1),accountList());await task;
  let first=race.selectViewerAccount(7);await flush();let firstPending=pending.at(-1),second=race.selectViewerAccount(8);await flush();let secondPending=pending.at(-1);
  resolvePrivate(secondPending,overviewFixture({items:[]}));await second;resolvePrivate(firstPending);await first;
  assert.equal(race.viewerAccountSeq,8);assert.equal(race.viewerOverview.items.length,0,'late account7 cannot overwrite account8');
  first=race.selectViewerAccount(7);await flush();firstPending=pending.at(-1);second=race.selectViewerAccount(8);await flush();secondPending=pending.at(-1);firstPending.reject(Error('late failure'));await first;assert.equal(race.viewerBusy,true);assert.equal(race.viewerError,'');resolvePrivate(secondPending);await second;
  task=race.selectViewerAccount(7);await flush();const hidden=pending.at(-1);race.clearViewer();resolvePrivate(hidden);await task;assert.equal(race.viewerOverview,null);assert.equal(race.viewerAccountSeq,0);assert.deepEqual(race.viewerAccounts,[]);
  first=race.loadViewerAccounts();firstPending=pending.at(-1);race.clearViewer();second=race.loadViewerAccounts();secondPending=pending.at(-1);resolvePrivate(firstPending,accountList());await first;assert.equal(race.viewerAccountsBusy,true,'hidden old lookup cannot finish the new lookup');assert.deepEqual(race.viewerAccounts,[]);resolvePrivate(secondPending,accountList());await second;
  task=race.selectViewerAccount(7);await flush();const toggled=pending.at(-1);race.configure({...race.settings,accountSeq:33,forecastsEnabled:true});resolvePrivate(toggled);await task;assert.ok(race.viewerOverview);assert.equal(race.viewerAccountSeq,7,'viewer is independent of forecast selection and flags');
  task=race.selectViewerAccount(8);await flush();const switched=pending.at(-1);race.configure({...race.settings,provider:'finnhub'});resolvePrivate(switched);await task;assert.equal(race.viewerOverview,null);assert.deepEqual(race.viewerAccounts,[]);
  race.configure({...race.settings,provider:'toss'});task=race.loadViewerAccounts();resolvePrivate(pending.at(-1),accountList());await task;
  task=race.selectViewerAccount(7);await flush();const credentialsPending=pending.at(-1);race.invalidate();resolvePrivate(credentialsPending);await task;assert.equal(race.viewerOverview,null);assert.deepEqual(race.viewerAccounts,[]);
  task=race.loadViewerAccounts();resolvePrivate(pending.at(-1),accountList());await task;task=race.selectViewerAccount(7);await flush();const closed=pending.at(-1);race.dispose();resolvePrivate(closed);await task;assert.equal(race.viewerOverview,null);assert.deepEqual(race.viewerAccounts,[]);assert.equal(race.viewerAvailable(),false);assert.equal(race.cache.size,0);
  console.log('PASS explicit Toss viewer gates, no auto selection/private persistence/cache/polling, decimal precision/currency/null validation and switch/hide/close races');
}

async function testAccountNotch(){
  assert.equal(S.DEFAULTS.accountNotchEnabled,false);assert.equal(S.DEFAULTS.accountNotchSeq,0);
  for(const seq of [0,-1,1.5,Number.MAX_SAFE_INTEGER+1,'7',null]){
    const settings=S.normalizeSettings({accountNotchEnabled:true,accountNotchSeq:seq,accountSeq:17});
    assert.equal(settings.accountNotchEnabled,false);assert.equal(settings.accountNotchSeq,0);assert.equal(settings.accountSeq,17);
  }
  let now=start,reply=overviewFixture(),failure=false,hold=false,held;const calls=[],timers=[],events=new Map();
  const oldInterval=global.setInterval,oldClear=global.clearInterval;
  global.setInterval=(fn,ms)=>{const timer={fn,ms};timers.push(timer);return timer;};global.clearInterval=timer=>timer.cleared=true;
  const owner=new S.Store({owner:true,now:()=>now,listen:async(name,fn)=>{events.set(name,fn);return ()=>events.delete(name);},invoke:async(cmd,args)=>{
    calls.push({cmd,args:clone(args)});
    if(cmd==='get_stock_credential_status')return {toss:true,finnhub:true};
    if(cmd==='get_stock_settings')return {...S.DEFAULTS,accountSeq:17};
    if(cmd==='load_stock_history')return empty();
    if(cmd==='set_stock_settings')return args.settings;
    assert.equal(cmd,'stock_request');
    if(hold)return new Promise(resolve=>held=resolve);
    if(failure)throw Error('Synthetic private failure');
    return {data:clone(args.request.kind==='accounts'?accountList():reply),fetchedAt:now};
  }});
  const requests=()=>calls.filter(c=>c.cmd==='stock_request');
  try{
    await owner.init();assert.equal(requests().length,0);assert.equal(timers[0].ms,60000);
    assert.equal(await owner.setAccountNotchEnabled(true),false,'cannot enable from an undiscovered/default account');
    await owner.loadViewerAccounts();assert.equal(owner.viewerAccountSeq,0,'one lookup never auto selects');
    assert.equal(await owner.setAccountNotchEnabled(true),false);await owner.selectViewerAccount(7);
    const beforeEnable=requests().length;
    assert.equal(await owner.setAccountNotchEnabled(true),true);await owner.tick();
    assert.equal(owner.active(),false,'account notch works with stock display disabled');
    assert.equal(requests().length,beforeEnable+2,'owner discovers the saved selection once before its overview');
    assert.deepEqual(requests().slice(-2).map(c=>c.args.request),[{kind:'accounts'},{kind:'accountOverview',accountSeq:7}]);
    assert.equal(owner.settings.accountSeq,7);assert.equal(owner.viewerAccountSeq,7);
    assert.deepEqual(Object.keys(owner.accountNotchSummary),['marketValue','dailyProfitLoss']);assert.ok(!('items' in owner.accountNotchSummary));
    assert.equal(owner.accountNotchSummary.marketValue.krw,'9007199254740994');assert.equal(owner.accountNotchSummary.dailyProfitLoss.amount.usd,null);
    const account=S.cells(owner,'en')[0];assert.equal(account.id,'widget-account');assert.equal(account.account,true);assert.ok(!account.stock);assert.equal(account.name,'Account');
    near(account.meter.fraction,.0125/.30);assert.equal(account.meter.counterclockwise,true);assert.equal(account.meter.color,'#FF453A');assert.equal(account.meter.text,'-1.25%');
    const card=S.accountCardHTML(owner,'en');assert.match(card,/9,007,199,254,740,994 KRW/);assert.match(card,/27\.50 USD/);assert.match(card,/-100 KRW/);assert.match(card,/>—<\/dd>/);assert.match(card,/Sep 28, 2026/);assert.match(card,/Cash\/bonds\/options excluded/);
    for(const forbidden of ['Stock chart','forecast','Investment','Exchange rate','Cash balance','9007199254740993','AAPL','0.125000000000000000000001'])assert.ok(!card.includes(forbidden),forbidden);
    for(const [rate,color,reverse,fraction] of [['0.075','var(--ample)',false,.25],['-0.15','#FF453A',true,.5],['0','var(--ink-dim)',false,0],['.45','var(--ample)',false,1]]){
      owner.accountNotchSummary.dailyProfitLoss.rate=rate;const meter=S.cells(owner,'en')[0].meter;assert.equal(meter.color,color);assert.equal(meter.counterclockwise,reverse);assert.equal(meter.fraction,fraction);
    }
    let count=requests().length;now+=59999;await owner.tick();assert.equal(requests().length,count);now++;timers[0].fn();await owner.tick();assert.equal(requests().length,count+1,'minute poll reuses discovery');
    const kept=owner.accountNotchSummary;now+=60000;hold=true;
    const first=owner.refreshAccountNotch(),second=owner.refreshAccountNotch(true);assert.equal(first,second,'clicks deduplicate with polling');
    count=requests().length;now+=120000;timers[0].fn();await flush();assert.equal(requests().length,count,'slow request cannot overlap');assert.equal(owner.accountNotchSummary,kept,'current rate remains while refreshing');
    held({data:reply,fetchedAt:now});hold=false;await first;
    const button={};S.bindAccountCard({querySelector:()=>button},owner);count=requests().length;await button.onclick();assert.equal(requests().length,count+1,'card refresh uses account path');
    now+=60000;failure=true;await owner.tick();assert.equal(owner.accountNotchSummary,null);assert.equal(owner.accountNotchFetchedAt,null);assert.equal(S.cells(owner,'en')[0].meter.text,'—');assert.match(S.accountCardHTML(owner,'en'),/Account unavailable/);assert.ok(!S.accountCardHTML(owner,'en').includes('9007199'));
    failure=false;hold=true;count=requests().length;const failedAt=owner.accountNotchAttemptAt,manualRetry=owner.refreshAccountNotch(true),repeatedRetry=owner.refreshAccountNotch(true);
    assert.equal(now,failedAt,'manual recovery needs no elapsed time or test-only attempt reset');assert.equal(requests().length,count+1,'forced refresh immediately retries after failure');assert.equal(manualRetry,repeatedRetry,'forced recovery still deduplicates pending requests');
    held({data:reply,fetchedAt:now});hold=false;await manualRetry;assert.ok(owner.accountNotchSummary);assert.equal(owner.accountNotchFetchedAt,now);assert.equal(owner.accountNotchError,'');assert.equal(S.cells(owner,'en')[0].meter.text,'-1.25%');
    now+=60000;failure=true;await owner.tick();assert.equal(owner.accountNotchSummary,null);
    count=requests().length;for(let i=0;i<20;i++)await owner.refreshAccountNotch();now+=59999;await owner.tick();assert.equal(requests().length,count,'automatic failure retry remains bounded to 60 seconds');
    failure=false;now++;await owner.tick();assert.equal(requests().length,count+1);
    reply=overviewFixture();reply.result.marketValue.amount.usd='not-a-decimal';now+=60000;await owner.tick();assert.equal(owner.accountNotchSummary,null,'malformed private values clear all amounts');reply=overviewFixture();now+=60000;await owner.tick();
    const summary=owner.accountNotchSummary;events.get('stock-view-state')({payload:{visible:false}});await owner.tick();assert.equal(owner.accountNotchSummary,summary,'closing Settings leaves notch ownership intact');
    assert.equal(owner.cache.size,0);assert.deepEqual(owner.history,empty());assert.deepEqual(owner.holdings,[]);assert.deepEqual(owner.candidates,[]);
    assert.ok(!S.csv(owner.history.forecasts,false).includes('9007199'));assert.ok(calls.every(c=>c.cmd!=='save_stock_history'));
    const privateRecord={...record(),accountNotchSummary:summary};assert.equal(S.validForecast(privateRecord),false);assert.throws(()=>S.validateHistory({version:1,trends:[],forecasts:[privateRecord]}));assert.ok(!S.csv([privateRecord],false).includes('9007199'),'CSV only projects public forecast columns');
    owner.configure({...owner.settings,forecastsEnabled:true,accountSeq:99});await owner.tick();assert.equal(owner.accountNotchSummary,summary,'forecast flags/selection do not change private epoch');
    await owner.setAccountNotchEnabled(false);count=requests().length;now+=600000;timers[0].fn();await owner.tick();assert.equal(requests().length,count);assert.equal(owner.accountNotchSummary,null);assert.deepEqual(S.cells(owner,'en'),[]);
  }finally{owner.dispose();global.setInterval=oldInterval;global.clearInterval=oldClear;}

  // Simulate native's credential-epoch discovery gate and late requests without provider traffic.
  const pending=[];let credentialEpoch=0,discoveredEpoch=-1;
  const race=new S.Store({owner:true,now:()=>now,invoke:(cmd,args)=>{
    if(cmd==='get_stock_credential_status')return Promise.resolve({toss:true,finnhub:true});
    assert.equal(cmd,'stock_request');
    if(args.request.kind==='accountOverview')assert.equal(discoveredEpoch,credentialEpoch,'new credentials require fresh discovery');
    return new Promise((resolve,reject)=>pending.push({request:args.request,resolve:data=>{if(args.request.kind==='accounts')discoveredEpoch=credentialEpoch;resolve({data,fetchedAt:now});},reject}));
  }});
  race.settingsReady=true;race.credentials={toss:true,finnhub:true};
  const enable=seq=>race.configure({...race.settings,provider:'toss',accountNotchEnabled:true,accountNotchSeq:seq});
  const discover=async()=>{assert.equal(pending.at(-1).request.kind,'accounts');pending.at(-1).resolve(accountList());await flush();assert.equal(pending.at(-1).request.kind,'accountOverview');};
  enable(7);await discover();let task=race.accountNotchPending,old=pending.at(-1),count=pending.length;
  race.configure({...race.settings,accountNotchSeq:8});assert.equal(pending.length,count,'account switch waits for old physical request');
  old.resolve(overviewFixture());await task;await flush();assert.equal(race.accountNotchSummary,null);await discover();pending.at(-1).resolve(overviewFixture({dailyProfitLoss:{amount:{krw:'200',usd:'1.25'},rate:'.075'}}));await race.accountNotchPending;assert.equal(race.accountNotchSummary.dailyProfitLoss.rate,'.075');
  now+=60000;task=race.refreshAccountNotch();old=pending.at(-1);race.configure({...race.settings,accountNotchEnabled:false});old.resolve(overviewFixture());await task;assert.equal(race.accountNotchSummary,null);
  enable(7);await discover();task=race.accountNotchPending;old=pending.at(-1);race.configure({...race.settings,provider:'finnhub'});old.resolve(overviewFixture());await task;assert.equal(race.accountNotchSummary,null);count=pending.length;await race.tick();assert.equal(pending.length,count);
  enable(7);await discover();task=race.accountNotchPending;old=pending.at(-1);credentialEpoch++;discoveredEpoch=-1;count=pending.length;const reload=race.reloadCredentials();await flush();assert.equal(race.credentials.toss,true);assert.equal(race.accountNotchSummary,null);assert.equal(pending.length,count,'credential change cannot overlap old overview');old.resolve(overviewFixture());await task;await flush();await discover();pending.at(-1).resolve(overviewFixture());await race.accountNotchPending;await reload;assert.ok(race.accountNotchSummary);
  now+=60000;task=race.refreshAccountNotch();old=pending.at(-1);count=pending.length;race.dispose();old.resolve(overviewFixture());await task;assert.equal(race.accountNotchSummary,null);assert.equal(pending.length,count,'dispose cannot restart polling');
  console.log('PASS account notch opt-in, 60s automatic polls/failure retry, immediate forced failure recovery without clock/reset changes, single pending request, summary-only privacy, Settings independence and account/provider/credential/disable cancellation');
}

// Parse the actual mounted markup and bind its controls without a browser/dependency.
function settingsDOM(){
  const doc={activeElement:null,scrolled:0,addEventListener(){},removeEventListener(){},defaultView:{addEventListener(){},removeEventListener(){}}};
  const decode=text=>text.replace(/&(amp|lt|gt|quot|#39);/g,(_,key)=>({amp:'&',lt:'<',gt:'>',quot:'"','#39':"'"}[key]));
  function node(tag='div',attrs={}){
    const n={tagName:tag.toUpperCase(),ownerDocument:doc,parentElement:null,children:[],dataset:{},attrs:{},writes:0,focusCount:0,scrollTop:0,value:'',selectionStart:0,selectionEnd:0,hidden:false,disabled:false,checked:false,open:false,
      [Symbol.for('nodejs.util.inspect.custom')](){return `<${this.tagName} id="${this.id||''}">`;},
      classList:{toggle(){},remove(){}},addEventListener(){},removeEventListener(){},
      setAttribute(key,value){this.attrs[key]=String(value);if(key.startsWith('data-'))this.dataset[key.slice(5).replace(/-([a-z])/g,(_,c)=>c.toUpperCase())]=String(value);else if(key==='tabindex')this.tabIndex=Number(value);else if(['hidden','disabled','checked','open'].includes(key))this[key]=true;else if(['id','type','value'].includes(key))this[key]=String(value);},
      getAttribute(key){return this.attrs[key]??null;},
      appendChild(child){child.parentElement=this;this.children.push(child);return child;},
      set innerHTML(html){
        this.writes++;this.html=html;this.children=[];const stack=[this];
        for(const token of html.match(/<[^>]*>|[^<]+/g)||[]){
          if(token.startsWith('</')){if(stack.length>1)stack.pop();continue;}
          if(token.startsWith('<')){
            const match=token.match(/^<([\w-]+)/);if(!match)continue;
            const child=node(match[1]);for(const attr of token.slice(match[0].length,-1).matchAll(/([\w-]+)(?:="([^"]*)")?/g))child.setAttribute(attr[1],decode(attr[2]??''));
            stack.at(-1).appendChild(child);if(!/^(input|br|hr|img|meta|link)$/i.test(match[1])&&!token.endsWith('/>'))stack.push(child);
          }else stack.at(-1).children.push(decode(token));
        }
        for(const select of this.querySelectorAll('select')){const options=select.querySelectorAll('option');select.value=(options.find(o=>o.attrs.selected!==undefined)||options[0])?.value||'';}
      },
      get innerHTML(){return this.html||'';},
      set textContent(text){this.children=[String(text)];this.html=String(text);},
      get textContent(){return this.children.map(child=>typeof child==='string'?child:child.textContent).join('');},
      matches(selector){
        return selector.split(',').some(part=>{
          part=part.trim();const id=part.match(/#([\w-]+)/)?.[1],tag=part.match(/^[\w-]+/)?.[0],cls=part.match(/\.([\w-]+)/)?.[1];
          if(id&&this.id!==id||tag&&this.tagName!==tag.toUpperCase()||cls&&!String(this.attrs.class||'').split(' ').includes(cls)||part.endsWith(':checked')&&!this.checked)return false;
          return [...part.matchAll(/\[([\w-]+)(?:="?([^"\]]+)"?)?\]/g)].every(([,key,value])=>this.attrs[key]!==undefined&&(value===undefined||this.attrs[key]===value));
        });
      },
      querySelectorAll(selector){return this.children.flatMap(child=>typeof child==='string'?[]:[...(child.matches(selector)?[child]:[]),...child.querySelectorAll(selector)]);},
      querySelector(selector){return this.querySelectorAll(selector)[0]||null;},
      contains(other){return other===this||this.children.some(child=>typeof child!=='string'&&child.contains(other));},
      closest(selector){return this.matches(selector)?this:this.parentElement?.closest(selector)||null;},
      focus(options){this.focusCount++;this.focusOptions=options;doc.activeElement=this;if(!options?.preventScroll)doc.scrolled++;},
      setSelectionRange(start,end){this.selectionStart=start;this.selectionEnd=end;},
      reportValidity(){return this.querySelectorAll('input[required]').every(input=>input.value.trim());},
      checkValidity(){return this.type!=='number'||Number.isFinite(Number(this.value))&&Number(this.value)>=Number(this.attrs.min)&&Number(this.value)<=Number(this.attrs.max);},
      get details(){return this.querySelectorAll('details[data-stock-disclosure]');}
    };
    for(const [key,value] of Object.entries(attrs))n.setAttribute(key,value);
    return n;
  }
  doc.createElement=tag=>node(tag);
  return {doc,element:node()};
}
async function testViewerMemo(){
  const {doc,element}=settingsDOM();let lang='en',privateCalls=0,saves=0,overviewFails=false;
  const oldDocument=global.document,oldFetch=global.fetch,oldRAF=global.requestAnimationFrame;
  global.document=doc;global.fetch=async()=>({ok:true,text:async()=>''});global.requestAnimationFrame=fn=>fn();
  const store=new S.Store({now:()=>start,invoke:async(cmd,args)=>{if(cmd==='set_stock_settings'){saves++;return args.settings;}assert.equal(cmd,'stock_request');privateCalls++;if(overviewFails&&args.request.kind==='accountOverview')throw Error('Synthetic viewer failure');return {data:args.request.kind==='accounts'?accountList():overviewFixture(),fetchedAt:start};}});
  store.settingsReady=true;store.credentials={toss:true,finnhub:true};
  try{
    const settings=S.mountSettings({element,store,language:()=>lang});store.onChange=()=>settings.render();
    element.querySelector('#stock-tab-account').onclick();
    assert.match(S.accountViewerHTML(store,'en'),/id="stock-account-notch" type="checkbox"\s+disabled/);
    await store.loadViewerAccounts();assert.equal(store.viewerAccountSeq,0);assert.equal(await store.setAccountNotchEnabled(true),false);assert.equal(saves,0);
    overviewFails=true;await store.selectViewerAccount(7);assert.equal(store.viewerOverview,null);assert.match(S.accountViewerHTML(store,'en'),/id="stock-account-notch" type="checkbox"\s+disabled/);assert.equal(await store.setAccountNotchEnabled(true),false);assert.equal(saves,0);overviewFails=false;
    await store.selectViewerAccount(7);let host=element.querySelector('#stock-account-viewer'),select=host.querySelector('#stock-viewer-account');select.focus();host.details[0].open=true;
    const writes=host.writes,focusCount=select.focusCount,started=performance.now();
    for(let i=0;i<1000;i++){store.quotes.set('us:AAPL',{price:i,fetchedAt:i});store.changed();}
    const elapsed=performance.now()-started;assert.equal(host.writes,writes,'1000 public quote updates cause zero private HTML rebuilds');assert.equal(select.focusCount,focusCount);assert.equal(doc.activeElement,select);assert.equal(host.details[0].open,true);
    store.viewerError='Could not load account information.';store.changed();assert.equal(host.writes,writes+1,'private change invalidates memo');assert.equal(host.details[0].open,true);assert.equal(doc.activeElement.id,'stock-viewer-account');
    assert.equal(await store.setAccountNotchEnabled(true),false,'failed viewer cannot enable the notch');store.viewerError='';store.changed();
    const calls=privateCalls;
    host.querySelector('#stock-account-notch').focus();host.details[0].open=true;
    host.querySelector('#stock-account-notch').checked=true;await host.querySelector('#stock-account-notch').onchange();assert.equal(store.settings.accountNotchEnabled,true);assert.equal(store.settings.accountNotchSeq,7);assert.equal(privateCalls,calls,'nonowner enable never polls');
    host=element.querySelector('#stock-account-viewer');assert.equal(host.writes,1,'outer host replacement resets viewer memo');
    assert.equal(doc.activeElement,host.querySelector('#stock-account-notch'),'focus survives outer host replacement');assert.equal(host.details[0].open,true,'disclosure survives outer host replacement');
    settings.show(false,false);assert.equal(store.viewerOverview,null);assert.equal(store.settings.accountNotchEnabled,true);assert.equal(store.accountNotchSummary,null);assert.equal(privateCalls,calls);assert.match(S.accountViewerHTML(store,'en'),/Saved account selection/);
    lang='ko';settings.show(true,false);host=element.querySelector('#stock-account-viewer');assert.equal(host.writes,1);assert.match(host.innerHTML,/내 토스 계좌/);
    store.configure({...store.settings,provider:'finnhub'});host=element.querySelector('#stock-account-viewer');assert.ok(host,'saved account state remains available for disabling after provider switch');
    host.querySelector('#stock-account-notch').checked=false;await host.querySelector('#stock-account-notch').onchange();assert.equal(store.settings.accountNotchEnabled,false);assert.equal(privateCalls,calls,'can disable without loading');
    console.log(`PASS Settings viewer memo: 1000 public updates, 0 private innerHTML writes (${elapsed.toFixed(1)}ms); focus/disclosures, host/language invalidation, manual selection and disable without loading`);
  }finally{store.dispose();global.document=oldDocument;global.fetch=oldFetch;global.requestAnimationFrame=oldRAF;}
}

function testAccountCardLayout(){
  const store=new S.Store({owner:true,now:()=>start,invoke:()=>assert.fail('no private request for account card rendering')});store.settingsReady=true;store.credentials.toss=true;store.settings=S.normalizeSettings({accountNotchEnabled:true,accountNotchSeq:7});
  const overview=S.decodeAccountOverview(overviewFixture());store.accountNotchSummary={marketValue:overview.marketValue.amount,dailyProfitLoss:overview.dailyProfitLoss};store.accountNotchFetchedAt=start;
  for(const [lang,title,label,market,daily,scope,updated,api] of [['en','Stock assets','Account','Market value','Daily P&amp;L','Cash/bonds/options excluded.','Updated','API overall rates use KRW conversion.'],['ko','주식 자산','계좌','평가금액','일간 손익','현금·채권·옵션은 포함하지 않습니다.','갱신','전체 손익률은 API의 원화 환산 기준입니다.']]){
    assert.equal(S.cells(store,lang)[0].name,label);assert.equal(S.cells(store,lang)[0].glyph,label);
    const html=S.accountCardHTML(store,lang);assert.ok(html.includes(`<h3>${title}</h3>`));assert.ok(!/<table|stock-table-wrap|tabindex="0"/.test(html),'narrow account hover has no table or horizontal scroll region');
    const rows=[...html.matchAll(/<dt>(.*?)<\/dt><dd>(.*?)<\/dd>/g)].map(row=>row.slice(1));
    assert.deepEqual(rows,[[market+' · KRW','9,007,199,254,740,994 KRW'],[market+' · USD','27.50 USD'],[daily+' · KRW','-100 KRW'],[daily+' · USD','—']]);
    for(const text of [scope,updated,api,'-1.25%'])assert.ok(html.includes(text));
  }
  store.accountNotchSummary.marketValue.krw='123456789012345678901234567.12';store.accountNotchSummary.marketValue.usd='9007199254740993.012345';store.accountNotchSummary.dailyProfitLoss.amount.usd='-9007199254740993.012345';store.accountNotchSummary.dailyProfitLoss.rate='0.075';
  for(const lang of ['en','ko']){const html=S.accountCardHTML(store,lang);assert.match(html,/123,456,789,012,345,678,901,234,567 KRW/);assert.match(html,/>9,007,199,254,740,993\.01 USD<\/dd>/);assert.match(html,/>-9,007,199,254,740,993\.01 USD<\/dd>/);assert.match(html,/\+7\.50%/);}
  const css=fs.readFileSync(path.join(__dirname,'../penguinnotch/ui/stocks.css'),'utf8');
  const bar=css.match(/\.cell\.account-cell\.meter-bar \.bar-name\{([^}]+)\}/)?.[1];assert.ok(bar);assert.match(bar,/font-size:11px/);assert.match(bar,/white-space:nowrap/);assert.match(bar,/display:block/);
  assert.match(css,/\.account-card \.stock-kv\{grid-template-columns:minmax\(0,1fr\) minmax\(0,1\.25fr\)\}/);assert.match(css,/\.account-card \.stock-kv dd\{min-width:0;overflow-wrap:anywhere\}/);assert.match(css,/\.account-card \.stock-kv dd\{[^}]*white-space:normal/);assert.ok(!css.includes('.account-card .stock-table'));
  store.dispose();console.log('PASS account card EN/KO titles/cell labels, four currency metric rows, exact money/null/rate formatting and scoped narrow-card/bar wrapping rules');
}

function testAccountNotchRendering(){
  const source=fs.readFileSync(path.join(__dirname,'../penguinnotch/ui/notch.html'),'utf8');
  const {element:card,doc}=settingsDOM();card.style={};card.scrollTop=0;card.getBoundingClientRect=()=>({width:270,height:220});
  const classes=()=>{const values=new Set();return {contains:key=>values.has(key),add:key=>values.add(key),remove:key=>values.delete(key),toggle:(key,on)=>on?values.add(key):values.delete(key)};};
  card.classList=classes();card.classList.add('show');
  const children=Object.fromEntries(['svg.ring','svg.reading','svg.activity','.pct','.glyph','.ringwrap'].map(key=>[key,{innerHTML:'',style:{},classList:classes(),getBoundingClientRect:()=>({left:context.cellRect.left,top:context.cellRect.top,width:56,height:56})}]));
  const cell={dataset:{},classList:classes(),querySelector:key=>children[key],getBoundingClientRect:()=>context.cellRect};
  const pill={dataset:{cells:'widget-account:-'},querySelector:()=>cell,getBoundingClientRect:()=>context.pillRect};
  doc.getElementById=()=>card;doc.documentElement={style:{zoom:'1'}};
  const store=new S.Store({owner:true,now:()=>start,invoke:()=>assert.fail('no native call from account hover')});store.settingsReady=true;store.credentials={toss:true,finnhub:true};store.settings=S.normalizeSettings({accountNotchEnabled:true,accountNotchSeq:7});
  const overview=S.decodeAccountOverview(overviewFixture());store.accountNotchSummary={marketValue:overview.marketValue.amount,dailyProfitLoss:overview.dailyProfitLoss};store.accountNotchFetchedAt=start;
  let refreshes=0,stockCalls=0,hidden=0;store.tick=()=>stockCalls++;store.loadChart=()=>stockCalls++;store.refreshAccountNotch=()=>{refreshes++;return Promise.resolve();};
  const context={PenguinNotchStocks:{...S,cardHTML:()=>assert.fail('account is not a stock card'),bindCard:()=>assert.fail('account is not a stock card')},stockStore:store,providers:()=>S.cells(store,context.uiLang),pill,cells:{},card,document:doc,uiLang:'en',hoverId:'widget-account',lastStockCardHTML:'',glyphs:{},glyphHtml:p=>S.esc(p.glyph),esc:S.esc,meterStyle:'ring',TRACK:'#222',HOLE:'#000',tail:{style:{}},insets:[0,0,0,0],hoverTextScale:1,innerWidth:1280,innerHeight:900,notchEdge:'right',syncScrollHover(){},reportHot(){},armWatchdog(){},hideCard(){hidden++;card.classList.remove('show');},edgeIsVertical:()=>['left','right'].includes(context.notchEdge)};
  vm.createContext(context);
  const pick=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
  vm.runInContext(pick('function svgArc(','function applyMeterStyle(')+pick('function renderRing(){','function resetCopy(')+pick('function renderCard(){','function renderMeterCard(')+pick('function refreshRing(id){','// The reading has a layer'),context);
  const ownerStart=source.indexOf('owner:true,onChange:')+'owner:true,onChange:'.length;
  vm.runInContext('var ownerChanged='+source.slice(ownerStart,source.indexOf('\n}});',ownerStart)+2),context);
  for(const lang of ['en','ko'])for(const edge of ['left','right','top','bottom']){
    context.uiLang=lang;
    context.notchEdge=edge;
    context.pillRect=edge==='left'?{left:8,right:88,top:300,bottom:500}:edge==='right'?{left:1192,right:1272,top:300,bottom:500}:edge==='top'?{left:500,right:780,top:8,bottom:88}:{left:500,right:780,top:812,bottom:892};
    context.cellRect={left:context.pillRect.left,top:context.pillRect.top,width:80,height:80};
    for(const shape of ['ring','bar'])for(const rate of ['0.075','-0.075','0']){
      context.meterStyle=shape;store.accountNotchSummary.dailyProfitLoss.rate=rate;context.renderRing();
      assert.equal(cell.classList.contains('stock-cell'),false);assert.equal(cell.classList.contains('account-cell'),true);assert.equal(cell.dataset.stockDrag,undefined);
      assert.equal(children['.glyph'].innerHTML,shape==='bar'?`<span class="bar-name">${S.t(lang,'Account')}</span>`:S.t(lang,'Account'));
      assert.equal(children['.pct'].textContent,S.accountRateText(rate));
      const reading=children['svg.reading'].innerHTML;
      if(rate==='0')assert.equal(reading,'');else if(shape==='ring')assert.equal(reading.includes('scale(-1 1)'),rate.startsWith('-'));else assert.match(reading,/width="12.5"/);
      assert.equal(children['.pct'].style.color,rate==='0'?'var(--ink-dim)':rate.startsWith('-')?'#FF453A':'var(--ample)');
      store.activeStock={symbol:'AAPL',market:'us'};context.renderCard();assert.equal(store.activeStock,null);assert.equal(stockCalls,0);
      const left=parseFloat(card.style.left),top=parseFloat(card.style.top);assert.ok(left>=8&&left+270<=1272,edge+' horizontal bounds');assert.ok(top>=8&&top+220<=892,edge+' vertical bounds');
      if(edge==='left')assert.ok(left>=context.pillRect.right+30);if(edge==='right')assert.ok(left+270<=context.pillRect.left-30);if(edge==='top')assert.ok(top>=context.pillRect.bottom+30);if(edge==='bottom')assert.ok(top+220<=context.pillRect.top-30);
      assert.equal(card.dataset.stock,'widget-account');assert.match(card.innerHTML,/account-card/);assert.ok(card.innerHTML.includes(`<h3>${S.t(lang,'Stock assets')}</h3>`));assert.equal((card.innerHTML.match(/<dt>/g)||[]).length,4);card.querySelector('#account-notch-refresh').onclick();
    }
  }
  assert.equal(refreshes,48);context.refreshRing('widget-account');assert.equal(refreshes,49,'ring click routes directly to account refresh');
  card.classList.remove('show');store.accountNotchSummary=null;context.ownerChanged();assert.equal(card.innerHTML,'','failure clears hidden private card markup');assert.equal(context.lastStockCardHTML,'','failure clears memoized private amounts');
  card.classList.add('show');store.settings.provider='finnhub';context.ownerChanged();assert.equal(hidden,1,'provider switch hides removed account card');assert.deepEqual(S.cells(store,'en'),[]);
  card.classList.add('show');store.settings.provider='toss';store.settings.accountNotchEnabled=false;context.ownerChanged();assert.equal(hidden,2,'disable hides removed account card');assert.equal(stockCalls,0);
  console.log('PASS actual notch account render/card/bind/click mock paths: EN/KO ring + bar, signed/zero API rates, all four edges (48 states), no stock drag/chart/forecast and hidden failure cleanup');
}

async function testAccountReviewFixes(){
  let now=start,calls=0,failure=false;
  const clock=new S.Store({owner:true,now:()=>now,invoke:async(cmd,args)=>{assert.equal(cmd,'stock_request');assert.equal(args.request.kind,'accountOverview');calls++;if(failure)throw Error('Synthetic unavailable');return {data:overviewFixture(),fetchedAt:now};}});
  clock.settingsReady=true;clock.credentials={toss:true,finnhub:false};clock.settings=S.normalizeSettings({accountNotchEnabled:true,accountNotchSeq:7});clock.accountNotchDiscovered=true;clock.accountNotchAttemptAt=now;
  await clock.tick();assert.equal(calls,0);now--;await clock.tick();assert.equal(calls,1,'clock rollback bypasses a future successful-attempt timestamp');assert.equal(clock.accountNotchFetchedAt,now);
  failure=true;now+=60000;await clock.tick();assert.equal(clock.accountNotchSummary,null);failure=false;now-=60000;await clock.tick();assert.equal(calls,3,'clock rollback also recovers from failed-attempt cooldown');assert.equal(clock.accountNotchFetchedAt,now);
  clock.configure({...clock.settings,provider:'finnhub'});await clock.tick();assert.equal(calls,3);assert.deepEqual(S.cells(clock,'en'),[],'saved account selection is hidden for another provider');assert.equal(clock.accountNotchSummary,null);clock.dispose();

  let privateCalls=0,reply;
  const unavailable=new S.Store({owner:true,now:()=>start,invoke:async(cmd)=>{if(cmd==='get_stock_credential_status')return {toss:false,finnhub:false};assert.equal(cmd,'stock_request');privateCalls++;return new Promise(resolve=>reply=resolve);}});
  unavailable.settingsReady=true;unavailable.settings=S.normalizeSettings({accountNotchEnabled:true,accountNotchSeq:7});
  await unavailable.tick();assert.equal(privateCalls,0,'saved-enabled account without credentials makes no private request');
  for(const lang of ['en','ko']){const html=S.accountCardHTML(unavailable,lang);assert.ok(html.includes(S.t(lang,'Account unavailable.')));assert.ok(!html.includes(S.t(lang,'Loading account information…')));}
  unavailable.credentials.toss=true;unavailable.accountNotchDiscovered=true;const pending=unavailable.refreshAccountNotch();await unavailable.reloadCredentials();assert.ok(unavailable.accountNotchPending,'old physical request is still pending after credential removal');
  for(const lang of ['en','ko']){const html=S.accountCardHTML(unavailable,lang);assert.ok(html.includes(S.t(lang,'Account unavailable.')));assert.ok(!html.includes(S.t(lang,'Loading account information…')));assert.ok(!html.includes('9007199'));}
  reply({data:overviewFixture(),fetchedAt:start});await pending;assert.equal(unavailable.accountNotchSummary,null);assert.equal(unavailable.accountNotchFetchedAt,null);assert.equal(privateCalls,1);unavailable.dispose();

  const {doc,element}=settingsDOM(),oldDocument=global.document,oldFetch=global.fetch,oldRAF=global.requestAnimationFrame;
  global.document=doc;global.fetch=async()=>({ok:true,text:async()=>''});global.requestAnimationFrame=fn=>fn();
  const owner=new S.Store({owner:true,now:()=>start,invoke:()=>assert.fail('Hide must not read the owner account')});
  owner.settingsReady=true;owner.credentials.toss=true;owner.settings=S.normalizeSettings({accountNotchEnabled:true,accountNotchSeq:7});owner.accountNotchAttemptAt=start;
  const overview=S.decodeAccountOverview(overviewFixture());owner.accountNotchSummary={marketValue:overview.marketValue.amount,dailyProfitLoss:overview.dailyProfitLoss};owner.accountNotchFetchedAt=start;
  let save,saves=0;
  const viewer=new S.Store({now:()=>start,invoke:async(cmd,args)=>{
    if(cmd==='set_stock_settings'){saves++;return new Promise((resolve,reject)=>save={args,resolve:()=>{owner.configure(args.settings);resolve(args.settings);},reject});}
    assert.equal(cmd,'stock_request');return {data:args.request.kind==='accounts'?accountList():overviewFixture(),fetchedAt:start};
  }});
  viewer.settingsReady=true;viewer.credentials.toss=true;viewer.settings=S.normalizeSettings({accountNotchEnabled:true,accountNotchSeq:7});
  try{
    const view=S.mountSettings({element,store:viewer});viewer.onChange=()=>view.render();
    element.querySelector('#stock-tab-account').onclick();
    await viewer.loadViewerAccounts();await viewer.selectViewerAccount(7);const original=viewer.viewerOverview,ownerSummary=owner.accountNotchSummary;
    const hide=()=>element.querySelector('#stock-account-viewer').querySelector('#stock-viewer-hide').onclick();
    let task=hide();assert.equal(save.args.settings.accountNotchEnabled,false);assert.equal(viewer.busy,true);assert.match(S.accountViewerHTML(viewer,'en'),/id="stock-viewer-hide" disabled/);assert.equal(viewer.viewerOverview,original,'viewer is retained until disable save succeeds');assert.equal(owner.accountNotchSummary,ownerSummary);
    assert.equal(await viewer.hideAccountInformation(),false);assert.equal(saves,1,'busy Hide cannot overlap a settings save');save.reject(Error('Synthetic private save detail'));assert.equal(await task,false);
    assert.equal(viewer.settings.accountNotchEnabled,true);assert.equal(owner.settings.accountNotchEnabled,true);assert.equal(viewer.viewerOverview,original);assert.match(S.accountViewerHTML(viewer,'en'),/Could not save stock settings/);assert.ok(!S.accountViewerHTML(viewer,'en').includes('Synthetic private save detail'));
    task=hide();save.resolve();assert.equal(await task,true);assert.equal(viewer.settings.accountNotchEnabled,false);assert.equal(viewer.viewerOverview,null);assert.deepEqual(viewer.viewerAccounts,[]);assert.equal(owner.accountNotchSummary,null);assert.equal(owner.accountNotchFetchedAt,null);assert.deepEqual(S.cells(owner,'en'),[]);
    // Hide also disables a saved notch when the manual viewer is already closed.
    viewer.settings={...viewer.settings,accountNotchEnabled:true};viewer.changed();assert.ok(!S.accountViewerHTML(viewer,'en').match(/id="stock-viewer-hide" disabled/));task=hide();save.reject(Error('Synthetic failure'));assert.equal(await task,false);assert.match(S.accountViewerHTML(viewer,'en'),/Could not save stock settings/);assert.equal(viewer.viewerOpen,false);
    task=hide();save.resolve();assert.equal(await task,true);assert.equal(viewer.settings.accountNotchEnabled,false);
    // When the notch is already off, Hide cancels the manual read without a redundant settings write.
    viewer.viewerOpen=true;viewer.viewerAccounts=S.decodeAccounts(accountList());let late;viewer.invoke=async(cmd)=>{assert.equal(cmd,'stock_request');return new Promise(resolve=>late=resolve);};task=viewer.selectViewerAccount(7);const saved=saves;assert.equal(await hide(),true);late({data:overviewFixture(),fetchedAt:start});await task;assert.equal(viewer.viewerOverview,null);assert.equal(viewer.viewerAccountSeq,0);assert.equal(saves,saved);
  }finally{viewer.dispose();owner.dispose();global.document=oldDocument;global.fetch=oldFetch;global.requestAnimationFrame=oldRAF;}
  console.log('PASS parent review: Toss-only cell, Hide disables before clearing with busy/failure/late-read handling, backward-clock polling and unavailable credentials including stale pending replies');
}

async function testNotchViewerSelection(){
  const {doc,element}=settingsDOM(),oldDocument=global.document,oldFetch=global.fetch,oldRAF=global.requestAnimationFrame;
  global.document=doc;global.fetch=async()=>({ok:true,text:async()=>''});global.requestAnimationFrame=fn=>fn();
  const requests=[];let save,saves=0;
  const store=new S.Store({now:()=>start,invoke:async(cmd,args)=>{
    if(cmd==='set_stock_settings'){saves++;return new Promise((resolve,reject)=>save={settings:args.settings,resolve:()=>resolve(args.settings),reject});}
    assert.equal(cmd,'stock_request');requests.push(args.request);return {data:args.request.kind==='accounts'?accountList():overviewFixture(),fetchedAt:start};
  }});
  store.settingsReady=true;store.credentials.toss=true;store.settings=S.normalizeSettings({accountSeq:17,accountNotchEnabled:true,accountNotchSeq:7});
  try{
    const view=S.mountSettings({element,store});store.onChange=()=>view.render();
    element.querySelector('#stock-tab-account').onclick();
    await store.loadViewerAccounts();assert.equal(store.viewerAccountSeq,0);assert.equal(saves,0,'discovery never changes the notch selection');let initial=store.selectViewerAccount(7);assert.equal(save.settings.accountSeq,7);assert.equal(store.settings.accountSeq,17,'saved mismatch changes only on explicit selection/save');save.resolve();await initial;assert.equal(saves,1);assert.equal(store.settings.forecastsEnabled,false);
    const select=seq=>{const input=element.querySelector('#stock-account-viewer').querySelector('#stock-viewer-account');input.value=String(seq);return input.onchange();};
    let count=requests.length,task=select(8);assert.equal(save.settings.accountNotchSeq,8);assert.equal(save.settings.accountNotchEnabled,true);assert.equal(save.settings.accountSeq,8);assert.equal(requests.length,count,'changed account is saved before its overview request');assert.match(S.accountViewerHTML(store,'en'),/id="stock-viewer-account"[^>]*disabled/);
    save.resolve();await task;assert.equal(store.settings.accountNotchSeq,8);assert.equal(store.viewerAccountSeq,8);assert.deepEqual(requests.at(-1),{kind:'accountOverview',accountSeq:8});assert.ok(store.viewerOverview);assert.equal(store.settings.accountSeq,8);
    count=requests.length;task=select(0);assert.equal(save.settings.accountNotchSeq,0);assert.equal(save.settings.accountNotchEnabled,false);assert.equal(save.settings.accountSeq,0);save.resolve();await task;assert.equal(store.settings.accountNotchEnabled,false);assert.equal(store.settings.accountNotchSeq,0);assert.equal(store.viewerAccountSeq,0);assert.equal(store.viewerOverview,null);assert.equal(store.viewerFetchedAt,null);assert.equal(requests.length,count,'zero selection disables without a private request');
    const saved=saves;await select(7);assert.equal(saves,saved,'manual viewer selection with notch off is unchanged');assert.equal(store.settings.accountNotchSeq,0);assert.equal(store.settings.accountSeq,0);
    store.configure({...store.settings,accountSeq:17,accountNotchEnabled:true,accountNotchSeq:7});count=requests.length;task=select(8);save.reject(Error('Synthetic private save detail'));await task;assert.equal(requests.length,count,'failed selection save blocks private fetch');assert.equal(store.settings.accountNotchSeq,7);assert.equal(store.viewerAccountSeq,0);assert.equal(store.viewerOverview,null);assert.match(S.accountViewerHTML(store,'en'),/Could not save stock settings/);assert.ok(!S.accountViewerHTML(store,'en').includes('Synthetic private save detail'));
    task=select(8);store.clearViewer();save.resolve();await task;assert.equal(requests.length,count,'generation change while saving prevents a late overview request');assert.equal(store.viewerAccountSeq,0);assert.equal(store.viewerOverview,null);assert.equal(store.viewerOpen,false);
    await store.loadViewerAccounts();count=requests.length;task=select(0);save.reject(Error('Synthetic save rejected'));await task;assert.equal(store.settings.accountNotchEnabled,true);assert.equal(store.settings.accountNotchSeq,8);assert.equal(requests.length,count);assert.match(S.accountViewerHTML(store,'en'),/Could not save stock settings/);
    const beforeInvalid=saves;for(const seq of [-1,1.5,Number.MAX_SAFE_INTEGER+1,'8',9])await store.selectViewerAccount(seq);assert.equal(saves,beforeInvalid);assert.equal(requests.length,count,'invalid/undiscovered selection never saves or reads');assert.equal(store.settings.accountSeq,8);
  }finally{store.dispose();global.document=oldDocument;global.fetch=oldFetch;global.requestAnimationFrame=oldRAF;}
  console.log('PASS notch viewer picker onchange: selected account saved before fetch, zero disables/clears, enabled holdings follow, independent forecasts, manual-off unchanged and save-failure/generation gates');
}

async function testStockSettingsTabs(){
  const {doc,element}=settingsDOM(),oldDocument=global.document,oldFetch=global.fetch,oldRAF=global.requestAnimationFrame,oldURL=global.URL;
  global.document=doc;global.fetch=async()=>({ok:true,text:async()=>''});global.requestAnimationFrame=fn=>fn();
  const exports=[],downloads=[],calls=[],events=new Map();let lang='en',failOverview=false,failCredentials=false,failSnapshot=false,noAccounts=false;
  doc.createElement=(create=>tag=>{const node=create(tag);if(tag==='a')node.click=()=>downloads.push(node.download);return node;})(doc.createElement);
  global.URL={createObjectURL:blob=>{exports.push(blob);return 'blob:stock-test';},revokeObjectURL(){}};
  const store=new S.Store({now:()=>start,listen:async(name,fn)=>{events.set(name,fn);return ()=>events.delete(name);},emit:async(name,payload)=>{
    if(name==='stock-history-action'){if(failSnapshot)throw Error('Synthetic service error');events.get('stock-history-updated')({payload:{requestID:payload.requestID,count:1}});}
  },invoke:async(cmd,args)=>{
    calls.push({cmd,args:clone(args)});
    if(cmd==='set_stock_settings')return args.settings;
    if(cmd==='load_stock_history')return clone(archive);
    if(cmd==='save_stock_credentials'){if(failCredentials)throw Error('Synthetic credential error');return {toss:true,finnhub:false};}
    assert.equal(cmd,'stock_request');
    if(args.request.kind==='accountOverview'&&failOverview)throw Error('Synthetic private error');
    assert.ok(['accounts','accountOverview'].includes(args.request.kind));
    return {data:args.request.kind==='accounts'?(noAccounts?{result:[]}:accountList()):overviewFixture(),fetchedAt:start};
  }});
  const saved=S.normalizeSettings({accountSeq:17,accountNotchSeq:8,accountNotchEnabled:true,forecastsEnabled:false,symbols:[{market:'us',symbol:'AAPL',visible:true}]}),archive={version:1,trends:[Object.fromEntries(S.TREND_KEYS.map(key=>[key,record()[key]]))],forecasts:[record()]};
  store.settingsReady=true;store.credentials={toss:true,finnhub:false};store.settings=clone(saved);store.history=clone(archive);
  const privateCount=()=>calls.filter(c=>c.cmd==='stock_request').length,writes=()=>calls.filter(c=>c.cmd==='set_stock_settings').length;
  const tab=key=>element.querySelector('#stock-tab-'+key),panel=key=>element.querySelector('#stock-panel-'+key),clickTab=key=>tab(key).onclick();
  const selected=key=>{assert.equal(tab(key).getAttribute('aria-selected'),'true');assert.equal(tab(key).tabIndex,0);for(const other of ['watchlist','account','analysis','history'])assert.equal(panel(other).hidden,other!==key);};
  try{
    const view=S.mountSettings({element,store,language:()=>lang});store.onChange=()=>view.render();await flush();
    const tabs=element.querySelectorAll('[data-stock-tab]');assert.deepEqual(tabs.map(node=>node.textContent),['Watchlist','My account','Analysis','History']);assert.equal(tabs.length,4);
    for(const button of tabs){assert.equal(button.getAttribute('role'),'tab');const controlled=element.querySelector('#'+button.getAttribute('aria-controls'));assert.equal(controlled.getAttribute('role'),'tabpanel');assert.equal(controlled.getAttribute('aria-labelledby'),button.id);}
    selected('watchlist');assert.equal(element.querySelector('#stock-account-viewer').innerHTML,'');assert.equal(element.querySelector('#stock-history').innerHTML,'');
    assert.ok(panel('watchlist').contains(element.querySelector('#stock-setting-enabled')));assert.ok(!panel('watchlist').querySelectorAll('h2').some(node=>node.textContent==='Stocks'));assert.ok(panel('watchlist').contains(element.querySelector('#stock-add-form')));assert.ok(panel('watchlist').contains(element.querySelector('#stock-provider')));
    assert.ok(panel('analysis').contains(element.querySelector('#stock-setting-forecastsEnabled')));assert.ok(panel('analysis').contains(element.querySelector('#stock-chart-interval')));
    assert.equal(element.querySelector('#stock-load-accounts'),null);assert.equal(element.querySelector('#stock-account'),null);
    assert.ok(element.details.every(details=>!details.open));assert.ok(element.innerHTML.indexOf('stock-add-form')<element.innerHTML.indexOf('stock-connection'));
    const averages=element.querySelector('[data-stock-disclosure="moving-averages"]');assert.ok(panel('analysis').contains(averages));assert.equal(averages.open,false);assert.equal(averages.querySelector('summary').textContent,'Moving averages');assert.equal(averages.querySelectorAll('[data-sma]').length,4);
    view.show(true);assert.equal(doc.activeElement,tab('watchlist'));assert.equal(doc.scrolled,0,'initial entry never scrolls to the add-symbol form');
    panel('watchlist').scrollTop=140;element.querySelector('#stock-connection').open=true;
    const secret=element.querySelector('#stock-client-secret');secret.value='synthetic-secret';element.querySelector('#stock-client-id').value='synthetic-id';secret.focus({preventScroll:true});
    clickTab('analysis');selected('analysis');assert.equal(secret.value,'');assert.equal(element.querySelector('#stock-client-id').value,'');assert.equal(element.querySelector('#stock-account-viewer').innerHTML,'');
    panel('analysis').scrollTop=35;
    element.querySelector('#stock-manage-accounts').onclick();selected('account');assert.equal(privateCount(),0);assert.equal(writes(),0);assert.deepEqual(store.settings,saved);
    assert.match(element.querySelector('#stock-account-viewer').innerHTML,/Saved selections differ/);assert.ok(!element.querySelector('#stock-account-viewer').textContent.includes('17'));
    assert.equal(element.querySelector('#stock-account-holdings').disabled,false,'positive saved holdings can be disabled without discovery');
    for(const key of ['history','watchlist','account','analysis'])clickTab(key);
    assert.equal(privateCount(),0,'local tabs make zero accounts/holdings/overview requests');assert.equal(writes(),0);assert.deepEqual(store.settings,saved);assert.deepEqual(store.history,archive);
    assert.equal(panel('analysis').scrollTop,35);clickTab('watchlist');assert.equal(panel('watchlist').scrollTop,140);assert.equal(element.querySelector('#stock-connection').open,true);
    let prevented=0;const keydown=(button,key)=>button.onkeydown({key,preventDefault(){prevented++;}});
    keydown(tab('watchlist'),'ArrowLeft');selected('history');keydown(tab('history'),'Home');selected('watchlist');keydown(tab('watchlist'),'End');selected('history');keydown(tab('history'),'ArrowRight');selected('watchlist');keydown(tab('watchlist'),'ArrowDown');selected('account');assert.equal(prevented,5);assert.equal(doc.activeElement,tab('account'));assert.equal(doc.scrolled,0);
    const disable=element.querySelector('#stock-account-holdings');disable.checked=false;await disable.onchange();assert.equal(store.settings.accountSeq,0);assert.equal(store.settings.accountNotchSeq,8);assert.equal(store.settings.accountNotchEnabled,true);assert.equal(store.settings.forecastsEnabled,false);assert.equal(privateCount(),0);
    store.configure(saved);const beforeDiscovery=writes();noAccounts=true;await element.querySelector('#stock-viewer-load').onclick();assert.equal(store.viewerAccountSeq,0);assert.deepEqual(store.settings,saved);assert.equal(writes(),beforeDiscovery);assert.match(element.querySelector('#stock-account-viewer').textContent,/No supported Toss account/);
    noAccounts=false;await element.querySelector('#stock-viewer-load').onclick();assert.equal(store.viewerAccountSeq,0);assert.deepEqual(store.settings,saved);assert.equal(writes(),beforeDiscovery);
    let picker=element.querySelector('#stock-viewer-account');picker.value='7';await picker.onchange();assert.equal(store.settings.accountSeq,7);assert.equal(store.settings.accountNotchSeq,7);assert.equal(store.settings.forecastsEnabled,false);
    let host=element.querySelector('#stock-account-viewer');assert.equal(host.querySelectorAll('details[data-stock-disclosure]').every(node=>!node.open),true);
    const investment=host.querySelectorAll('th').find(node=>node.textContent==='Investment');assert.ok(investment.closest('details'));assert.equal(investment.closest('details').open,false);
    assert.ok(host.querySelectorAll('table').every(table=>table.closest('details')),'both summary details and holdings tables are collapsed');
    assert.match(host.innerHTML,/9,007,199,254,740,994 KRW/);assert.match(host.innerHTML,/\-1\.25%/);
    let notch=element.querySelector('#stock-account-notch');notch.checked=false;await notch.onchange();let holdings=element.querySelector('#stock-account-holdings');holdings.checked=false;await holdings.onchange();
    holdings=element.querySelector('#stock-account-holdings');holdings.checked=true;await holdings.onchange();assert.equal(store.settings.accountSeq,7);assert.equal(store.settings.accountNotchEnabled,false);assert.equal(store.settings.forecastsEnabled,false);
    notch=element.querySelector('#stock-account-notch');notch.checked=true;await notch.onchange();assert.equal(store.settings.forecastsEnabled,false);assert.equal(store.settings.accountSeq,7);
    picker=element.querySelector('#stock-viewer-account');picker.value='0';const beforeZero=privateCount();await picker.onchange();assert.equal(privateCount(),beforeZero);assert.equal(store.settings.accountSeq,0);assert.equal(store.settings.accountNotchSeq,0);assert.equal(store.settings.accountNotchEnabled,false);
    picker=element.querySelector('#stock-viewer-account');picker.value='8';const beforeManual=writes();await picker.onchange();assert.equal(writes(),beforeManual);assert.equal(store.settings.accountSeq,0);assert.equal(store.settings.accountNotchEnabled,false);assert.equal(store.settings.forecastsEnabled,false);
    failOverview=true;await element.querySelector('#stock-viewer-refresh').onclick();assert.equal(store.viewerOverview,null);assert.match(element.querySelector('#stock-account-viewer').textContent,/Could not load account information/);assert.ok(!element.querySelector('#stock-account-viewer').textContent.includes('Synthetic private error'));
    failOverview=false;await element.querySelector('#stock-viewer-refresh').onclick();assert.ok(store.viewerOverview);notch=element.querySelector('#stock-account-notch');notch.checked=true;await notch.onchange();
    const persisted=clone(store.settings),beforeLeaving=privateCount();clickTab('analysis');assert.equal(store.viewerOverview,null);assert.equal(store.viewerAccountSeq,0);assert.deepEqual(store.viewerAccounts,[]);assert.equal(element.querySelector('#stock-account-viewer').innerHTML,'');assert.deepEqual(store.settings,persisted);assert.equal(privateCount(),beforeLeaving);
    // UI fixtures retain the actual handlers while avoiding public provider work in this settings-only check.
    store.tick=async()=>{};
    let forecasts=element.querySelector('#stock-setting-forecastsEnabled');forecasts.checked=true;await forecasts.onchange();assert.equal(store.settings.accountSeq,0);assert.equal(store.settings.accountNotchEnabled,true);
    store.accountError='Could not load holdings. Watchlist forecasts remain available.';store.forecastError='Could not load estimates. Check saved keys, market data access and allowed IP.';store.historyError='Could not save history. Existing records are retained; check disk space and permissions.';store.changed();
    for(const id of ['stock-account-message','stock-forecast-status','stock-analysis-history-status']){const node=element.querySelector('#'+id);assert.ok(node.textContent);assert.equal(node.closest('details'),null,'action failures remain outside disclosures');}
    store.accountError='';store.forecastError='';store.historyError='';store.candidates=[record()];store.settings={...store.settings,enabled:true};store.changed();
    failSnapshot=true;await element.querySelector('#stock-snapshot').onclick();assert.match(element.querySelector('#stock-snapshot-status').textContent,/did not respond/);assert.equal(element.querySelector('#stock-snapshot-status').closest('details'),null);
    failSnapshot=false;await element.querySelector('#stock-snapshot').onclick();assert.equal(element.querySelector('#stock-snapshot-status').textContent,'Snapshots saved');
    clickTab('history');let history=element.querySelector('#stock-history');history.details.find(node=>node.dataset.stockDisclosure==='comparison').open=true;
    const filter=element.querySelector('#stock-history-filter-capture');filter.value='scheduled';filter.focus({preventScroll:true});filter.onchange();assert.equal(doc.activeElement.id,'stock-history-filter-capture');assert.equal(doc.activeElement.value,'scheduled');assert.match(history.innerHTML,/No saved forecasts/);
    const writesBefore=history.writes;clickTab('analysis');for(let i=0;i<10;i++)store.changed();assert.equal(history.writes,writesBefore,'inactive history skips rendering');clickTab('history');assert.equal(history.writes,writesBefore,'unchanged cached history survives tab switches');assert.equal(history.details.find(node=>node.dataset.stockDisclosure==='comparison').open,true);
    lang='ko';view.render();selected('history');assert.deepEqual(element.querySelectorAll('[data-stock-tab]').map(node=>node.textContent),['관심 종목','내 계좌','분석','기록']);assert.equal(element.querySelector('#stock-history-filter-capture').value,'scheduled');
    const allCapture=element.querySelector('#stock-history-filter-capture');allCapture.value='';allCapture.onchange();element.querySelector('#stock-export-forecasts').onclick();element.querySelector('#stock-export-traces').onclick();element.querySelector('#stock-export-comparison').onclick();
    assert.deepEqual(downloads,['penguinnotch-stock-forecasts.csv','penguinnotch-stock-traces.csv','penguinnotch-stock-forecasts.csv']);assert.equal(exports.length,3);assert.ok((await exports[0].text()).includes(S.MODEL));assert.ok(!(await exports[0].text()).includes('9007199'));assert.deepEqual(store.history,archive);
    store.historyError='History could not be read. Original records are preserved; writes are blocked.';store.changed();assert.match(element.querySelector('#stock-history').textContent,/원본을 보존/);await element.querySelector('#stock-history-refresh').onclick();assert.deepEqual(store.history,archive);
    clickTab('account');assert.match(element.querySelector('#stock-account-viewer').textContent,/노치에 계좌 표시/);assert.match(element.querySelector('#stock-account-viewer').textContent,/노치 계좌/);assert.ok(!element.querySelector('#stock-account-viewer').textContent.includes('Show account in notch'));
    store.configure({...store.settings,provider:'finnhub'});assert.ok(element.querySelector('#stock-viewer-load').disabled);element.querySelector('#stock-manage-connection').onclick();selected('watchlist');assert.equal(element.querySelector('#stock-connection').open,true);assert.equal(element.querySelector('#stock-provider').disabled,false);assert.ok(element.querySelector('#stock-api-key'));assert.equal(element.querySelector('#stock-client-secret'),null);
    const apiKey=element.querySelector('#stock-api-key');apiKey.value='synthetic-key';clickTab('account');assert.equal(apiKey.value,'');clickTab('watchlist');view.show(false,false);assert.equal(element.querySelector('#stock-api-key').value,'');
    view.show(true,false);store.configure({...store.settings,provider:'toss'});failCredentials=true;let form=element.querySelector('#stock-credentials');form.querySelector('#stock-client-id').value='synthetic-id';form.querySelector('#stock-client-secret').value='synthetic-secret';await form.onsubmit({preventDefault(){},currentTarget:form});
    assert.match(element.querySelector('#stock-credential-message').textContent,/입력값은 지웠습니다/);assert.equal(element.querySelector('#stock-credential-message').closest('details'),null);assert.equal(element.querySelector('#stock-client-secret').value,'');
    clickTab('analysis');const priorAverages=clone(store.settings),beforeAverages=privateCount();
    element.querySelector('[data-stock-disclosure="moving-averages"]').open=true;
    const sma=element.querySelector('#stock-sma-60');sma.checked=true;sma.focus({preventScroll:true});await sma.onchange();
    assert.deepEqual(store.settings,{...priorAverages,movingAverages:[5,20,60]});assert.equal(privateCount(),beforeAverages);
    assert.equal(element.querySelector('[data-stock-disclosure="moving-averages"]').open,true);assert.equal(doc.activeElement.id,'stock-sma-60');
    lang='en';view.render();assert.equal(element.querySelector('[data-stock-disclosure="moving-averages"]').querySelector('summary').textContent,'Moving averages');
    lang='ko';view.render();assert.equal(element.querySelector('[data-stock-disclosure="moving-averages"]').querySelector('summary').textContent,'이동평균');assert.equal(element.querySelector('[data-stock-disclosure="moving-averages"]').open,true);
    element.querySelector('[data-stock-disclosure="moving-averages"]').open=false;store.changed();assert.equal(element.querySelector('[data-stock-disclosure="moving-averages"]').open,false);
    console.log('PASS actual Settings mount/handlers: four EN/KO tabs/default/grouping, migration/no discovery/selection, independent opt-ins, explicit selector follows, private clearing/errors, collapsed details, preventScroll/focus, panel scroll/disclosures/language persistence, cached History/filters/CSV and snapshot/credential failures');
  }finally{store.dispose();global.document=oldDocument;global.fetch=oldFetch;global.requestAnimationFrame=oldRAF;global.URL=oldURL;}
}

async function main(){
  testForecastEvaluation();
  await testAccountViewer();
  await testAccountNotch();
  await testViewerMemo();
  testAccountCardLayout();
  testAccountNotchRendering();
  await testAccountReviewFixes();
  await testNotchViewerSelection();
  await testStockSettingsTabs();
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
    return {dataset:{},contains(){return false;},get innerHTML(){return html;},set innerHTML(value){html=value;nodes=[...value.matchAll(/<details\b([^>]*)>/g)].map(([,attrs])=>({open:false,dataset:{stockDisclosure:attrs.match(/data-stock-disclosure="([^"]*)"/)?.[1]}}));},querySelectorAll(selector){return selector==='details[data-stock-disclosure]'?nodes.filter(node=>node.dataset.stockDisclosure):[];},querySelector(){return {};}};
  };
  const disclosureHosts={'#stock-holdings':disclosureHost(),'#stock-history':disclosureHost()},disclosureElement={querySelector:selector=>disclosureHosts[selector]||null,querySelectorAll:selector=>Object.values(disclosureHosts).flatMap(host=>host.querySelectorAll(selector))};
  const disclosureStore={forecastStocks:[{symbol:'AAPL',market:'us',name:'Apple'},{symbol:'MSFT',market:'us',name:'Microsoft'}],candidates:[r,unpaired],forecastError:'',accountError:'',historyError:'',reasons:new Map(),history:clone(filterSource)};
  const uiSource=fs.readFileSync(path.join(__dirname,'../penguinnotch/ui/stocks.js'),'utf8'),sectionCode=uiSource.slice(uiSource.indexOf('  function renderPortfolio(){'),uiSource.indexOf("  store.listen?.('stock-history-updated'"));
  const disclosureContext=vm.createContext({...S,element:disclosureElement,store:disclosureStore,language:()=> 'en',tr:key=>S.esc(key),document:{activeElement:null},activeTab:'analysis',settingsHidden:false,captureFocus:()=>null,restoreFocus(){},historyFilter:{stockID:'',day:'',model:'',capture:''}});
  vm.runInContext(sectionCode+";const portfolioPanel=renderPortfolio,historyPanel=renderHistory;renderPortfolio=()=>{activeTab='analysis';portfolioPanel();};renderHistory=()=>{activeTab='history';historyPanel();};renderPortfolio();renderHistory();",disclosureContext);
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
