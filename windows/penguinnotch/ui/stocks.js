/* Windows stock parity. Pure codecs/model below mirror Sources/Widgets/Stock*.swift.
   Native IPC owns credentials, HTTP, token/rate limits and atomic history storage. */
(function(root) {
'use strict';
const DEFAULTS={enabled:false,provider:'toss',symbols:[],displayInterval:3,chartInterval:'1m',candleCount:20,movingAverages:[5,20],showTechnical:true,forecastsEnabled:false,recordForecasts:false,accountSeq:0};
const TTL={'1m':60000,'10m':600000,'1d':86400000};
const MODEL='GBM zero drift v1';
const TREND_KEYS=['stockID','name','market','currency','model','createdAt','quoteAt','sessionStart','sessionEnd','inputPrice','expectedClose'];
const FORECAST_KEYS=[...TREND_KEYS,'previousClose','lowerClose','upperClose','riseProbability','observations','capture','evidence','actualClose','evaluatedAt'];
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const positive=n=>typeof n==='number'&&Number.isFinite(n)&&n>0;
const historyTime=n=>typeof n==='number'&&Number.isFinite(n)&&n>=0&&n<=253402300799000;
const publicText=(value,limit)=>typeof value==='string'&&value.trim().length>0&&Array.from(value).length<=limit&&!/[\x00-\x1f\x7f|]/.test(value);
const numeric=v=>(typeof v==='number'||typeof v==='string'&&v.trim())&&Number.isFinite(Number(v))?Number(v):NaN;
const zone=market=>market==='kr'?'Asia/Seoul':'America/New_York';
const dateFormats={};
function dayKey(time,market) {
  if(!Number.isFinite(time)) return '';
  const f=dateFormats[market]||(dateFormats[market]=new Intl.DateTimeFormat('en-CA',{timeZone:zone(market),year:'numeric',month:'2-digit',day:'2-digit'}));
  const p=Object.fromEntries(f.formatToParts(new Date(time)).map(v=>[v.type,v.value]));
  return `${p.year}-${p.month}-${p.day}`;
}
function timestamp(value,market='kr') {
  if(typeof value==='number') return Number.isFinite(value)?value:NaN;
  if(typeof value!=='string') return NaN;
  // Date-only daily bars mean midnight in the market, not UTC. Intl handles US DST.
  if(/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const nominal=Date.parse(value+'T00:00:00Z');
    if(!Number.isFinite(nominal)) return NaN;
    let t=nominal;
    for(let i=0;i<3;i++) {
      const parts=Object.fromEntries(new Intl.DateTimeFormat('en-GB',{timeZone:zone(market),year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(t).map(p=>[p.type,p.value]));
      t+=nominal-Date.UTC(+parts.year,+parts.month-1,+parts.day,+parts.hour,+parts.minute,+parts.second);
    }
    return t;
  }
  return /(?:Z|[+-]\d{2}:\d{2})$/.test(value)?Date.parse(value):NaN;
}
function parseStock(raw) {
  let text=String(raw||'').trim().toUpperCase(), market;
  if(!text||text.length>20) return null;
  if(/^(KR|US):/.test(text)){market=text.slice(0,2).toLowerCase();text=text.slice(3);}
  if(!/^[A-Z0-9][A-Z0-9.\-]{0,14}$/.test(text)) return null;
  market=market||(/^[0-9A-Z]{6}$/.test(text)&&/\d/.test(text)?'kr':'us');
  if(!(market==='kr'?/^[0-9A-Z]{6}$/:/^[A-Z][A-Z0-9.\-]{0,9}$/).test(text)) return null;
  return {symbol:text,market};
}
const stockID=s=>s.market+':'+s.symbol;
function normalizeSettings(s={}) {
  const seen=new Set();
  const symbols=(Array.isArray(s.symbols)?s.symbols:[]).flatMap(row=>{
    const stock=parseStock(`${row.market}:${row.symbol}`);
    if(!stock||seen.has(stockID(stock))) return [];
    seen.add(stockID(stock));
    const color=String(row.color||'').replace(/^#/,'');
    return [{...stock,...(typeof row.name==='string'&&row.name.trim()?{name:row.name.trim().normalize('NFC').slice(0,200)}:{}),visible:row.visible!==false,...(/^[a-f\d]{6}$/i.test(color)?{color}: {})}];
  }).slice(0,30);
  const integer=(v,min,max,fallback)=>Number.isInteger(v)?Math.max(min,Math.min(max,v)):fallback;
  return {enabled:s.enabled===true,provider:s.provider==='finnhub'?'finnhub':'toss',symbols,displayInterval:integer(s.displayInterval,1,10,3),chartInterval:TTL[s.chartInterval]?s.chartInterval:'1m',candleCount:integer(s.candleCount,1,20,20),movingAverages:[5,20,60,120].filter(n=>(s.movingAverages||[5,20]).includes(n)),showTechnical:s.showTechnical!==false,forecastsEnabled:s.forecastsEnabled===true,recordForecasts:s.recordForecasts===true,accountSeq:integer(s.accountSeq,0,Number.MAX_SAFE_INTEGER,0)};
}
function decodeQuotes(data) {
  if(!Array.isArray(data?.result)) throw Error('Invalid quote response');
  const quotes=new Map();
  for(const row of data.result) {
    const s=parseStock(row.symbol), price=numeric(row.lastPrice);
    if(s&&positive(price)&&row.currency===(s.market==='kr'?'KRW':'USD')) quotes.set(stockID(s),{price,currency:row.currency,quoteAt:typeof row.timestamp==='string'&&!/T.*(?:Z|[+-]\d{2}:\d{2})$/i.test(row.timestamp)?NaN:timestamp(row.timestamp,s.market)});
  }
  return quotes;
}
function decodeFinnhub(data) {
  const price=numeric(data?.c),previousClose=numeric(data?.pc),seconds=numeric(data?.t);
  if(!positive(price)||!positive(seconds)) throw Error('Invalid quote response');
  return {price,previousClose:positive(previousClose)?previousClose:null,quoteAt:seconds*1000,currency:'USD'};
}
function dailyCloses(data,market) {
  if(!Array.isArray(data?.result?.candles)) throw Error('Invalid candle response');
  return data.result.candles.map(row=>({date:timestamp(row.timestamp,market),price:numeric(row.closePrice)}));
}
function closeForDay(closes,day,market,sameDay=false) {
  if(!day||!Array.isArray(closes)||closes.some(c=>!positive(c.price)||!historyTime(c.date)))return null;
  return closes.slice().sort((a,b)=>b.date-a.date).find(c=>sameDay?dayKey(c.date,market)===day:dayKey(c.date,market)<day)||null;
}
function previousClose(closes,priceTime,market) {
  return historyTime(priceTime)?closeForDay(closes,dayKey(priceTime,market),market)?.price??null:null;
}
function quoteContext(data,quoteAt) {
  if(!historyTime(quoteAt))return null;
  const matches=new Map();
  for(const key of ['today','previousBusinessDay','nextBusinessDay']) {
    const day=data?.result?.[key],regularStart=timestamp(day?.regularMarket?.startTime,'us'),regularEnd=timestamp(day?.regularMarket?.endTime,'us');
    if(!historyTime(regularStart)||!historyTime(regularEnd)||regularEnd<=regularStart)continue;
    for(const phase of ['dayMarket','preMarket','regularMarket','afterMarket']) {
      const start=timestamp(day?.[phase]?.startTime,'us'),end=timestamp(day?.[phase]?.endTime,'us');
      if(!historyTime(start)||!historyTime(end)||!(start<=quoteAt&&quoteAt<end))continue;
      if(phase==='afterMarket'?start<regularEnd:phase!=='regularMarket'&&end>regularStart)continue;
      const context={phase,tradingDay:dayKey(regularStart,'us'),regularStart,regularEnd};
      matches.set(JSON.stringify(context),context);
    }
  }
  return matches.size===1?[...matches.values()][0]:null;
}
const changeRate=q=>{const rate=positive(q?.price)&&positive(q?.previousClose)?(q.price-q.previousClose)/q.previousClose:null;return Number.isFinite(rate)?rate:null;};
function decodeCandles(data,market) {
  if(!Array.isArray(data?.result?.candles)) throw Error('Invalid candle response');
  const bars=data.result.candles.map(r=>({end:timestamp(r.timestamp,market),open:numeric(r.openPrice),high:numeric(r.highPrice),low:numeric(r.lowPrice),close:numeric(r.closePrice),volume:numeric(r.volume)})).sort((a,b)=>a.end-b.end);
  if(!validBars(bars)) throw Error('Invalid candle response');
  return bars;
}
function validBars(bars) {
  return Array.isArray(bars)&&bars.every(b=>Number.isFinite(b.end)&&[b.open,b.high,b.low,b.close].every(positive)&&Number.isFinite(b.volume)&&b.volume>=0&&b.high>=Math.max(b.open,b.close)&&b.low<=Math.min(b.open,b.close))&&new Set(bars.map(b=>b.end)).size===bars.length;
}
function movingAverage(bars,period) {
  if(!(period>0)||!bars.every((b,i)=>positive(b.close)&&Number.isFinite(b.end)&&(!i||b.end>bars[i-1].end))) return bars.map(()=>null);
  let sum=0;
  return bars.map((b,i)=>{sum+=b.close;if(i>=period)sum-=bars[i-period].close;return i>=period-1?sum/period:null;});
}
function tenMinuteBars(minutes,strict=false) {
  const groups=new Map();
  for(const m of minutes.slice().sort((a,b)=>a.end-b.end)) {
    const end=Math.floor((m.end-1000)/600000)*600000+600000;
    if(!groups.has(end)) groups.set(end,[]);
    groups.get(end).push(m);
  }
  return [...groups].flatMap(([end,g])=>{
    if(strict&&(g.length!==10||g.some((m,i)=>Math.abs(m.end-end+(9-i)*60000)>=10))) return [];
    return [{end,open:g[0].open,high:Math.max(...g.map(b=>b.high)),low:Math.min(...g.map(b=>b.low)),close:g[g.length-1].close,volume:g.reduce((n,b)=>n+b.volume,0)}];
  });
}
function completedBars(bars,through,interval,session=null) {
  if(!validBars(bars)) return [];
  const minutes=bars.filter(b=>b.end<=through&&(!session||(b.end>session.start&&b.end<=session.end&&b.end-60000>=session.start))).sort((a,b)=>a.end-b.end);
  return interval==='10m'?tenMinuteBars(minutes,true):minutes;
}
function regularSession(data,market,now) {
  const days=data?.result;
  if(!days||typeof days!=='object') throw Error('Invalid calendar response');
  return ['today','previousBusinessDay','nextBusinessDay'].map(key=>{
    const s=market==='kr'?days[key]?.integrated?.regularMarket:days[key]?.regularMarket;
    return s?{start:timestamp(s.startTime,market),end:timestamp(s.endTime,market)}:null;
  }).find(s=>s&&s.start<=now&&now<s.end&&s.end>s.start)||null;
}
function dailyVariance(closes) {
  if(closes.length<21||!closes.every(positive)) return null;
  const returns=closes.slice(1).map((p,i)=>Math.log(closes[i])-Math.log(p));
  const mean=returns.reduce((n,r)=>n+r,0)/returns.length;
  const variance=returns.reduce((n,r)=>n+(r-mean)**2,0)/(returns.length-1);
  return Number.isFinite(variance)?variance:null;
}
// Abramowitz-Stegun erf approximation, max error 1.5e-7 (tested against Swift fixtures).
function erf(x) {
  const sign=x<0?-1:1,t=1/(1+0.3275911*Math.abs(x));
  return sign*(1-(((((1.061405429*t-1.453152027)*t)+1.421413741)*t-0.284496736)*t+0.254829592)*t*Math.exp(-x*x));
}
function distribution(price,previous,variance,observations) {
  const sigma=Math.sqrt(variance);
  if(!positive(price)||!positive(previous)||!positive(sigma)) return null;
  const z=(Math.log(price/previous)-variance/2)/sigma;
  const lowerClose=price*Math.exp(-variance/2-1.2815515655446004*sigma),upperClose=price*Math.exp(-variance/2+1.2815515655446004*sigma);
  if(!Number.isFinite(z)||!positive(lowerClose)||!positive(upperClose)) return null;
  return {expectedClose:price,lowerClose,upperClose,riseProbability:Math.max(0,Math.min(1,0.5*(1+erf(z/Math.SQRT2)))),observations};
}
function estimate(price,closes,session,now) {
  if(!session||!(session.start<=now&&now<session.end)) return null;
  const variance=dailyVariance(closes);
  return variance===null?null:distribution(price,closes[0],variance*(session.end-now)/(session.end-session.start),closes.length-1);
}
function chartEstimate(record,bars,interval,now) {
  if(!validForecast(record)||record.createdAt>now||now>=record.sessionEnd||now-record.quoteAt>120000) return null;
  const session={start:record.sessionStart,end:record.sessionEnd};
  if(interval==='1d') return estimate(record.inputPrice,record.evidence.closes.map(c=>c.price),session,record.quoteAt);
  const duration=interval==='1m'?60000:600000,completed=completedBars(bars,record.quoteAt,interval,session),last=completed.at(-1);
  if(!last||record.quoteAt-last.end>duration+120000) return null;
  const returns=[];
  for(let i=completed.length-1;i>0;i--){
    if(Math.abs(completed[i].end-completed[i-1].end-duration)>=10) break;
    returns.push(Math.log(completed[i].close/completed[i-1].close));
  }
  if(returns.length<10) return null;
  const mean=returns.reduce((n,r)=>n+r,0)/returns.length;
  const variance=returns.reduce((n,r)=>n+(r-mean)**2,0)/(returns.length-1);
  return distribution(record.inputPrice,record.previousClose,variance*(record.sessionEnd-record.quoteAt)/duration,returns.length);
}
function technical(bars,interval,market,fetchedAt,now,record=null) {
  if(!Number.isFinite(fetchedAt)||fetchedAt>now||now-fetchedAt>TTL[interval]+120000||!bars.length||!validBars(bars)) return null;
  let complete=interval==='1d'?bars.filter(b=>dayKey(b.end,market)<dayKey(Math.min(now,fetchedAt),market)).sort((a,b)=>a.end-b.end):completedBars(bars,Math.min(now,fetchedAt),interval);
  if(interval!=='1d') {
    const duration=interval==='1m'?60000:600000;
    let start=0;
    for(let i=1;i<complete.length;i++) if(dayKey(complete[i].end,market)===dayKey(complete[i-1].end,market)&&Math.abs(complete[i].end-complete[i-1].end-duration)>=10) start=i;
    complete=complete.slice(start);
  }
  if(complete.length<20) return null;
  complete=complete.slice(-20);
  const last=complete.at(-1),prior=complete.slice(-11,-1),volume=prior.reduce((n,b)=>n+b.volume,0)/10;
  if(!positive(volume)) return null;
  const ratio=last.volume/volume,fast=movingAverage(complete,5).at(-1),slow=movingAverage(complete,20).at(-1),high=Math.max(...prior.map(b=>b.high)),low=Math.min(...prior.map(b=>b.low));
  if(!Number.isFinite(ratio)) return null;
  const action=ratio>=1.5&&fast>slow&&last.close>high&&last.close>last.open?'buy':ratio>=1.5&&fast<slow&&last.close<low&&last.close<last.open?'sell':'wait';
  let live=false;
  if(record&&validForecast(record)&&record.market===market&&record.createdAt<=now&&now<record.sessionEnd&&now-record.quoteAt<=120000) {
    const age=record.quoteAt-last.end;
    const recent=interval==='1d'?dayKey(last.end,market)===dayKey(record.evidence.closes[0].date,market):age>=0&&age<=(interval==='1m'?60000:600000)+120000&&last.end>record.sessionStart;
    live=recent&&((action==='buy'&&record.inputPrice>high)||(action==='sell'&&record.inputPrice<low));
  }
  return {action,live,ratio,fast,slow,high,low,firstAt:complete[0].end,lastAt:last.end};
}
const onlyKeys=(o,keys)=>o&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).every(k=>keys.includes(k));
function validTrend(r,keys=TREND_KEYS) {
  const stock=r&&parseStock(r.stockID);
  return onlyKeys(r,keys)&&TREND_KEYS.every(k=>Object.hasOwn(r,k))&&stock&&stockID(stock)===r.stockID&&stock.market===r.market&&publicText(r.name,200)&&publicText(r.model,100)&&r.currency===(r.market==='kr'?'KRW':'USD')&&['createdAt','quoteAt','sessionStart','sessionEnd'].every(k=>historyTime(r[k]))&&r.sessionStart<=r.quoteAt&&r.quoteAt<=r.createdAt&&r.createdAt<r.sessionEnd&&r.createdAt-r.quoteAt<=120000&&positive(r.inputPrice)&&positive(r.expectedClose);
}
function validForecast(r) {
  if(!validTrend(r,FORECAST_KEYS)||!FORECAST_KEYS.every(k=>Object.hasOwn(r,k))||!['manual','scheduled'].includes(r.capture)||!['previousClose','lowerClose','upperClose'].every(k=>positive(r[k]))||r.lowerClose>r.upperClose||!Number.isFinite(r.riseProbability)||r.riseProbability<0||r.riseProbability>1||!Number.isInteger(r.observations)||r.observations<20||r.observations>60) return false;
  if(r.capture==='scheduled'&&(r.sessionEnd-r.createdAt<3300000||r.sessionEnd-r.createdAt>3600000)) return false;
  const e=r.evidence;
  if(!onlyKeys(e,['adjusted','closes'])||e.adjusted!==true||!Array.isArray(e.closes)||e.closes.length!==r.observations+1||e.closes[0]?.price!==r.previousClose||!positive(dailyVariance(e.closes.map(c=>c.price)))) return false;
  if(!e.closes.every((c,i)=>onlyKeys(c,['date','price'])&&historyTime(c.date)&&positive(c.price)&&dayKey(c.date,r.market)<dayKey(i?e.closes[i-1].date:r.sessionStart,r.market))) return false;
  return r.actualClose===null&&r.evaluatedAt===null||positive(r.actualClose)&&historyTime(r.evaluatedAt)&&r.evaluatedAt>=r.sessionEnd&&dayKey(r.evaluatedAt,r.market)>dayKey(r.sessionStart,r.market);
}
const groupID=r=>`${r.stockID}|${r.sessionStart}|${r.model}`;
const trendID=r=>`${groupID(r)}|${Math.floor(r.createdAt/60000)}`;
const forecastID=r=>`${groupID(r)}|${r.capture}`;
function validateHistory(h) {
  if(!onlyKeys(h,['version','trends','forecasts'])||h.version!==1||!Array.isArray(h.trends)||!Array.isArray(h.forecasts)||!h.trends.every(r=>validTrend(r))||!h.forecasts.every(validForecast)||new Set(h.trends.map(trendID)).size!==h.trends.length||new Set(h.forecasts.map(forecastID)).size!==h.forecasts.length) throw Error('History could not be read. Original records are preserved; writes are blocked.');
  const last=new Map();
  for(const r of h.trends.slice().sort((a,b)=>a.createdAt-b.createdAt)) {const prior=last.get(groupID(r));if(prior&&r.quoteAt<=prior.quoteAt) throw Error('History could not be read. Original records are preserved; writes are blocked.');last.set(groupID(r),r);}
  return h;
}
function appendSamples(history,records,scheduled) {
  const next={version:1,trends:history.trends.slice(),forecasts:history.forecasts.slice()},ids=new Set(next.forecasts.map(forecastID)),latest=new Map();
  for(const point of history.trends){const key=groupID(point);if(!latest.has(key)||latest.get(key).createdAt<point.createdAt)latest.set(key,point);}
  for(const r of records.filter(validForecast)) {
    const last=latest.get(groupID(r));
    if(!last||(r.quoteAt>last.quoteAt&&Math.floor(r.createdAt/60000)>Math.floor(last.createdAt/60000))){next.trends.push(Object.fromEntries(TREND_KEYS.map(k=>[k,r[k]])));latest.set(groupID(r),r);}
    const saved={...r,capture:'scheduled'};
    if(scheduled&&validForecast(saved)&&!ids.has(forecastID(saved))) {next.forecasts.push(saved);ids.add(forecastID(saved));}
  }
  return next;
}
function saveSnapshots(history,records,now) {
  const forecasts=history.forecasts.slice(),ids=new Set(forecasts.map(forecastID));
  for(const r of records) if(validForecast(r)&&r.createdAt<=now&&now-r.createdAt<=90000&&now<r.sessionEnd&&!ids.has(forecastID(r))){forecasts.push({...r});ids.add(forecastID(r));}
  return {...history,forecasts};
}
function score(records) {
  const done=records.filter(r=>positive(r.actualClose)),directions=done.filter(r=>r.actualClose!==r.previousClose&&r.riseProbability!==0.5);
  const avg=f=>done.length?done.reduce((s,r)=>s+f(r),0)/done.length:null;
  return {total:records.length,evaluated:done.length,directionCount:directions.length,accuracy:directions.length?directions.filter(r=>(r.riseProbability>0.5)===(r.actualClose>r.previousClose)).length/directions.length:null,mae:avg(r=>Math.abs(r.expectedClose-r.actualClose)),mape:avg(r=>Math.abs(r.expectedClose-r.actualClose)/r.actualClose*100),baseline:avg(r=>Math.abs(r.inputPrice-r.actualClose)/r.actualClose*100),range:avg(r=>+(r.lowerClose<=r.actualClose&&r.actualClose<=r.upperClose)),brier:avg(r=>(r.riseProbability-+(r.actualClose>r.previousClose))**2)};
}
function compareModels(records) {
  const valid=records.filter(validForecast),models=[...new Set(valid.map(r=>r.model))].sort(),groups=new Map();
  for(const r of valid.filter(r=>r.actualClose!==null)) {
    // Swift's comparison key excludes the model/output and capture clock, but
    // requires the exact quote, input prices, session and saved daily evidence.
    const key=JSON.stringify([r.stockID,r.currency,r.capture,r.quoteAt,r.sessionStart,r.sessionEnd,r.previousClose,r.inputPrice,r.observations,r.evidence.adjusted,r.evidence.closes.map(c=>[c.date,c.price])]);
    if(!groups.has(key))groups.set(key,[]);groups.get(key).push(r);
  }
  const matched=[...groups.values()].filter(rows=>rows.length===models.length&&new Set(rows.map(r=>r.model)).size===models.length&&new Set(rows.map(r=>r.actualClose)).size===1),paired=matched.flat();
  return {pairedCount:matched.length,baseline:score(matched.map(rows=>rows[0])).baseline,rows:models.map(model=>({model,available:score(valid.filter(r=>r.model===model)),paired:score(paired.filter(r=>r.model===model))}))};
}
function probabilityBins(records) {
  const groups=new Map();
  for(const r of records.filter(r=>validForecast(r)&&r.actualClose!==null)){const id=Math.min(9,Math.floor(r.riseProbability*10));if(!groups.has(id))groups.set(id,[]);groups.get(id).push(r);}
  return [...groups].sort(([a],[b])=>a-b).map(([id,rows])=>{
    const count=rows.length,rises=rows.filter(r=>r.actualClose>r.previousClose).length,observedRate=rises/count,z=1.959963984540054,denominator=1+z*z/count;
    const center=(observedRate+z*z/(2*count))/denominator,radius=z*Math.sqrt(observedRate*(1-observedRate)/count+z*z/(4*count*count))/denominator;
    return {id,count,rises,meanProbability:rows.reduce((sum,r)=>sum+r.riseProbability,0)/count,observedRate,lower:Math.max(0,center-radius),upper:Math.min(1,center+radius)};
  });
}
function filterHistory(history,filter) {
  const matches=r=>(!filter.stockID||r.stockID===filter.stockID)&&(!filter.day||dayKey(r.sessionStart,r.market)===filter.day);
  const cohort=history.forecasts.filter(r=>matches(r)&&(!filter.capture||r.capture===filter.capture));
  return {cohort,records:cohort.filter(r=>!filter.model||r.model===filter.model),traces:history.trends.filter(r=>matches(r)&&(!filter.model||r.model===filter.model))};
}
function csv(records,trace=false) {
  const keys=trace?TREND_KEYS:FORECAST_KEYS;
  const quote=value=>{let s=typeof value==='object'&&value!==null?JSON.stringify(value):String(value??'');if(/^[=+@-]/.test(s.trimStart()))s="'"+s;return '"'+s.replace(/"/g,'""')+'"';};
  return [keys.join(','),...records.map(r=>keys.map(k=>quote(r[k])).join(','))].join('\r\n')+'\r\n';
}
class Store {
  constructor({invoke,listen,emit=async()=>{},now=Date.now,owner=false,onChange=()=>{}}) {
    Object.assign(this,{invoke,listen,emit,now,owner,onChange,settings:normalizeSettings(),credentials:{toss:false,finnhub:false},quotes:new Map(),names:new Map(),charts:new Map(),cache:new Map(),accounts:[],holdings:[],forecastStocks:[],candidates:[],reasons:new Map(),history:null,historyError:'',error:'',forecastError:'',accountError:'',accountsBusy:false,revision:0,settingsReady:false,busy:false,activeStock:null,visible:false});
    this.writes=Promise.resolve();this.reconcileAttempts=new Map();this.quoteTimes=new Map();this.unlisten=[];
  }
  changed(){this.onChange(this);}
  async init() {
    if(this.listen) {
      this.unlisten.push(await this.listen('stock-settings',e=>this.configure(e.payload)));
      this.unlisten.push(await this.listen('stock-credentials',()=>this.reloadCredentials()));
      if(this.owner) this.unlisten.push(await this.listen('stock-view-state',e=>{this.visible=e.payload?.visible===true;void this.tick();}));
      if(this.owner) this.unlisten.push(await this.listen('stock-history-action',e=>{
        if(e.payload?.action==='snapshot') this.manualSnapshot().then(count=>this.emit('stock-history-updated',{requestID:e.payload.requestID,count,error:this.historyError})).catch(()=>{});
      }));
      else this.unlisten.push(await this.listen('stock-history-updated',()=>{if(this.visible)void this.loadHistory();else this.historyDirty=true;}));
    }
    await Promise.all([this.reloadCredentials(),this.loadHistory()]);
    const revision=this.revision;
    try{const settings=await this.invoke('get_stock_settings');if(revision===this.revision)this.configure(settings);}catch(_){this.error='Stock settings unavailable';this.changed();}
    this.timer=setInterval(()=>{if(!this.owner&&this.visible)void this.emit('stock-view-state',{visible:true}).catch(()=>{});void this.tick();},60000);
    await this.tick();
  }
  async reloadCredentials(){try{this.credentials=await this.invoke('get_stock_credential_status');this.invalidate();this.changed();await this.tick();}catch(_){this.error='Credential status unavailable';this.changed();}}
  invalidate(){this.revision++;this.cache.clear();this.quotes.clear();this.quoteTimes.clear();this.charts.clear();this.accounts=[];this.holdings=[];this.forecastStocks=[];this.candidates=[];this.reasons.clear();this.forecastError='';this.accountError='';this.reconciliationError='';}
  configure(value) {
    const next=normalizeSettings(value),prior=this.settings;
    this.settingsReady=true;
    if(JSON.stringify(prior)===JSON.stringify(next)){this.changed();return;}
    this.revision++;
    if(prior.provider!==next.provider||prior.enabled!==next.enabled||prior.forecastsEnabled!==next.forecastsEnabled||prior.accountSeq!==next.accountSeq){this.invalidate();}
    for(const [key,entry] of this.charts) if(entry.loading)this.charts.delete(key);
    this.settings=next;this.error='';this.changed();void this.tick();
  }
  async saveSettings(next){
    if(this.busy) return false;
    this.busy=true;this.changed();
    try{this.configure(await this.invoke('set_stock_settings',{settings:normalizeSettings(next)}));return true;}
    catch(_){this.error='Could not save stock settings';return false;}
    finally{this.busy=false;this.changed();}
  }
  active(){return this.settingsReady&&this.settings.enabled&&this.credentials[this.settings.provider];}
  canAcceptQuote(id,q) {
    return !(q.fetchedAt<this.quotes.get(id)?.fetchedAt)&&(Number.isFinite(q.quoteAt)?historyTime(q.quoteAt)&&q.quoteAt<=this.now()&&q.quoteAt>=(this.quoteTimes.get(id)??0):!this.quoteTimes.has(id));
  }
  setQuote(id,q) {
    if(!this.canAcceptQuote(id,q))return;
    if(Number.isFinite(q.quoteAt))this.quoteTimes.set(id,q.quoteAt);
    this.quotes.set(id,q);
  }
  async request(request,ttl=60000,scope='') {
    const s=this.settings;
    if(!this.active()||s.provider==='finnhub'&&request.kind!=='finnhubQuote'||s.provider==='toss'&&request.kind==='finnhubQuote'||['accounts','holdings'].includes(request.kind)&&!s.forecastsEnabled||request.kind==='holdings'&&(!(s.accountSeq>0)||(request.accountSeq??s.accountSeq)!==s.accountSeq)) throw Error('Stock requests are disabled');
    const key=JSON.stringify(request)+'|'+scope,now=this.now(),cached=this.cache.get(key);
    if(cached&&(cached.value||cached.revision===this.revision)&&(cached.pending||now>=cached.at&&now-cached.at<(cached.error?Math.min(ttl,600000):ttl))){if(cached.error)throw cached.error;return cached.value||cached.promise;}
    const revision=this.revision,entry={at:now,revision,pending:true};
    entry.promise=this.invoke('stock_request',{request}).then(result=>{
      if(revision!==this.revision||!this.active()) throw Error('Stale stock request');
      const receivedAt=this.now();
      if(!result||!historyTime(result.fetchedAt)||result.fetchedAt>receivedAt||receivedAt-result.fetchedAt>=ttl) throw Error('Invalid stock response');
      entry.at=result.fetchedAt;entry.pending=false;entry.value=result;return result;
    }).catch(e=>{entry.at=this.now();entry.pending=false;entry.error=e;throw e;});
    this.cache.set(key,entry);return entry.promise;
  }
  async refreshQuotes() {
    if(!this.active())return;
    const revision=this.revision,s=this.settings,stocks=s.symbols.filter(x=>x.visible&&(s.provider==='toss'||x.market==='us'));
    if(!stocks.length)return;
    try {
      if(s.provider==='finnhub') {
        for(const stock of stocks){const r=await this.request({kind:'finnhubQuote',symbol:stock.symbol});if(revision!==this.revision)return;this.setQuote(stockID(stock),{...decodeFinnhub(r.data),fetchedAt:r.fetchedAt});}
      } else {
        const symbols=stocks.map(x=>x.symbol),r=await this.request({kind:'prices',symbols}),quotes=decodeQuotes(r.data);
        for(const stock of stocks) {
          if(revision!==this.revision)return;
          const id=stockID(stock),q=quotes.get(id);if(!q)continue;
          q.fetchedAt=r.fetchedAt;if(!this.canAcceptQuote(id,q))continue;
          q.previousClose=null;q.basisDate=null;q.context=null;
          if(stock.market==='us'&&historyTime(q.quoteAt)) {
            try{const calendar=await this.request({kind:'calendar',market:'us',date:dayKey(q.quoteAt,'us')},60000);q.context=quoteContext(calendar.data,q.quoteAt);}catch(_){}
          }
          if(revision!==this.revision)return;
          const request={kind:'candles',symbol:stock.symbol,market:stock.market,interval:'1d',count:3,adjusted:true},prefix=JSON.stringify(request)+'|quote:';
          q.contextKey=q.context?JSON.stringify(q.context):stock.market==='kr'?dayKey(q.quoteAt,'kr'):'';
          if(this.quotes.get(id)?.contextKey!==q.contextKey)for(const key of this.cache.keys())if(key.startsWith(prefix))this.cache.delete(key);
          if(historyTime(q.quoteAt)&&(stock.market==='kr'||q.context)) {
            try{
              const daily=await this.request(request,60000,'quote:'+q.contextKey),after=q.context?.phase==='afterMarket';
              // A cached, still-open daily candle is not the official after-hours baseline.
              if(!after||daily.fetchedAt>=q.context.regularEnd) {
                const basis=closeForDay(dailyCloses(daily.data,stock.market),q.context?.tradingDay||dayKey(q.quoteAt,stock.market),stock.market,after);
                if(basis){q.previousClose=basis.price;q.basisDate=dayKey(basis.date,stock.market);}
              }
            }catch(_){}
          }
          if(revision!==this.revision)return;
          this.setQuote(id,q);
        }
        try{const names=await this.request({kind:'names',symbols},TTL['1d']);if(revision!==this.revision)return;for(const row of names.data?.result||[]){const stock=parseStock(row.symbol);if(stock&&typeof(row.name||row.englishName)==='string')this.names.set(stockID(stock),(row.name||row.englishName).normalize('NFC'));}}catch(_){}
      }
      if(revision===this.revision)this.error='';
    }catch(_){if(revision===this.revision)this.error='Quotes unavailable. Check saved keys, access and allowed IP.';}
    this.changed();
  }
  async loadChart(stock,interval=this.settings.chartInterval) {
    if(!this.active()||this.settings.provider!=='toss')return;
    const revision=this.revision,key=stockID(stock)+'|'+interval,entry=this.charts.get(key);
    if(entry?.loading||entry&&this.now()>=entry.at&&this.now()-entry.at<(entry.error?Math.min(TTL[interval],600000):TTL[interval])) return;
    this.charts.set(key,{...entry,at:this.now(),loading:true,error:''});
    this.changed();
    const request={kind:'candles',symbol:stock.symbol,market:stock.market,interval,count:interval==='10m'?1400:200,adjusted:true};let response;
    try{response=await this.request(request,TTL[interval]);const candles=decodeCandles(response.data,stock.market);if(revision===this.revision)this.charts.set(key,{candles,fetchedAt:response.fetchedAt,at:response.fetchedAt,loading:false,error:''});}
    catch(error){if(revision===this.revision){if(response)this.cache.set(JSON.stringify(request)+'|',{at:this.now(),revision,pending:false,error});this.charts.set(key,{...entry,at:this.now(),loading:false,error:'Chart unavailable'});}}
    this.changed();
  }
  async loadHistory() {
    try{const h=validateHistory(await this.invoke('load_stock_history'));this.history=h;this.historyError='';}
    catch(_){this.historyError='History could not be read. Original records are preserved; writes are blocked.';}
    this.changed();
  }
  persist(update) {
    const run=async()=>{
      if(!this.owner||!this.history||this.historyError.startsWith('History could not be read'))return false;
      const next=update(this.history);
      const oldTrends=new Set(this.history.trends.map(trendID)),oldForecasts=new Map(this.history.forecasts.map(r=>[forecastID(r),r]));
      const delta={version:1,trends:next.trends.filter(r=>!oldTrends.has(trendID(r))),forecasts:next.forecasts.filter(r=>{const old=oldForecasts.get(forecastID(r));return !old||old.actualClose!==r.actualClose||old.evaluatedAt!==r.evaluatedAt;})};
      if(!delta.trends.length&&!delta.forecasts.length)return true;
      try{validateHistory(delta);const now=this.now();if([...delta.trends,...delta.forecasts].some(r=>r.createdAt>now||r.quoteAt>now||r.evaluatedAt!==null&&r.evaluatedAt!==undefined&&r.evaluatedAt>now))throw Error('Future stock observation');const saved=await this.invoke('save_stock_history',{history:delta});
        if(saved)this.history=validateHistory(saved);
        else{for(const record of delta.forecasts)oldForecasts.set(forecastID(record),record);this.history={version:1,trends:[...this.history.trends,...delta.trends],forecasts:[...oldForecasts.values()]};}this.historyError='';this.changed();await this.emit('stock-history-updated',{});return true;}
      catch(_){this.historyError='Could not save history. Existing records are retained; check disk space and permissions.';this.changed();return false;}
    };
    this.writes=this.writes.then(run,run);return this.writes;
  }
  async manualSnapshot() {
    if(!this.active()||this.settings.provider!=='toss'||!this.settings.forecastsEnabled)return 0;
    let count=0;
    await this.persist(h=>{const next=saveSnapshots(h,this.candidates,this.now());count=next.forecasts.length-h.forecasts.length;return next;});
    return this.historyError?0:count;
  }
  async reconcile() {
    if(!this.owner||!this.history||!this.active()||this.settings.provider!=='toss'||!this.settings.forecastsEnabled)return;
    const revision=this.revision,now=this.now(),groups=new Map(),resolutions=new Map();let failed=false;
    for(const r of this.history.forecasts) if(r.actualClose===null&&dayKey(now,r.market)>dayKey(r.sessionStart,r.market))groups.set(r.stockID+'|'+r.sessionStart,r);
    for(const [key,r] of [...groups].filter(([key])=>!this.reconcileAttempts.has(key)||now-this.reconcileAttempts.get(key)>=3600000).slice(0,20)) {
      this.reconcileAttempts.set(key,now);
      try{const response=await this.request({kind:'candles',symbol:parseStock(r.stockID).symbol,market:r.market,interval:'1d',count:2,before:new Date(r.sessionEnd).toISOString(),adjusted:false},3600000);if(revision!==this.revision)return;const matches=dailyCloses(response.data,r.market).filter(c=>dayKey(c.date,r.market)===dayKey(r.sessionStart,r.market)&&positive(c.price));if(matches.length===1)resolutions.set(key,matches[0].price);else failed=true;}catch(_){failed=true;}
    }
    if(revision!==this.revision)return;
    if(resolutions.size) await this.persist(h=>({...h,forecasts:h.forecasts.map(r=>r.actualClose===null&&resolutions.has(r.stockID+'|'+r.sessionStart)?{...r,actualClose:resolutions.get(r.stockID+'|'+r.sessionStart),evaluatedAt:now}:r)}));
    this.reconciliationError=failed?'Some daily closes are unavailable. Pending forecasts will be retried.':'';
  }
  async loadAccounts() {
    if(this.accountsBusy||!this.active()||this.settings.provider!=='toss'||!this.settings.forecastsEnabled)return;
    const revision=this.revision;this.accountsBusy=true;this.accountError='';this.changed();
    try {
      const response=await this.request({kind:'accounts'},300000);if(revision!==this.revision)return;
      if(!Array.isArray(response.data?.result))throw Error('Invalid accounts');
      this.accounts=response.data.result.filter(a=>a.accountType==='BROKERAGE'&&Number.isInteger(a.accountSeq)&&a.accountSeq>0).map(a=>({accountSeq:a.accountSeq,label:'•••• '+String(a.accountNo||'').slice(-4)}));
      if(!this.accounts.length)this.accountError='No supported Toss account was found.';
    }catch(_){if(revision===this.revision)this.accountError='Could not load accounts. Watchlist forecasts remain available.';}
    finally{this.accountsBusy=false;this.changed();}
  }
  async refreshForecasts() {
    const s=this.settings;
    if(!this.active()||s.provider!=='toss'||!s.forecastsEnabled)return;
    const revision=this.revision,now=this.now();
    const ensure=()=>{if(revision!==this.revision)throw Error('Stale stock request');};
    try {
      await this.reconcile();ensure();
      this.holdings=[];
      if(s.accountSeq>0) {
        try {
          const holdingResponse=await this.request({kind:'holdings',accountSeq:s.accountSeq},300000);ensure();
          if(!Array.isArray(holdingResponse.data?.result?.items))throw Error('Invalid holdings');
          this.holdings=holdingResponse.data.result.items.flatMap(h=>{const stock=parseStock(String(h.marketCountry)+':'+h.symbol);return stock&&h.currency===(stock.market==='kr'?'KRW':'USD')?[{...stock,name:Array.from(String(h.name||stock.symbol)).slice(0,200).join(''),currency:h.currency}]:[];});
          this.accountError=this.holdings.length?'':'This account has no supported stock holdings.';
        }catch(_){ensure();this.accountError='Could not load holdings. Watchlist forecasts remain available.';}
      }
      const targets=new Map(s.symbols.map(stock=>[stockID(stock),{symbol:stock.symbol,market:stock.market,name:stock.name||this.names.get(stockID(stock))||stock.symbol,currency:stock.market==='kr'?'KRW':'USD'}]));
      for(const holding of this.holdings)if(!targets.has(stockID(holding)))targets.set(stockID(holding),holding);
      this.forecastStocks=[...targets.values()];
      const sessions=new Map();
      for(const market of [...new Set(this.forecastStocks.map(h=>h.market))]){const cal=await this.request({kind:'calendar',market,date:dayKey(now,market)},60000);ensure();sessions.set(market,regularSession(cal.data,market,now));}
      const active=this.forecastStocks.filter(h=>sessions.get(h.market));
      let quotes=new Map();
      for(let i=0;i<active.length;i+=200){const r=await this.request({kind:'prices',symbols:active.slice(i,i+200).map(h=>h.symbol)});ensure();for(const [id,q] of decodeQuotes(r.data))quotes.set(id,q);}
      const records=[],reasons=new Map();
      for(const h of this.forecastStocks) {
        ensure();const id=stockID(h),session=sessions.get(h.market),q=quotes.get(id),observedAt=this.now();
        if(!session){reasons.set(id,'Estimates run during the regular session only.');continue;}
        if(!q||!Number.isFinite(q.quoteAt)||q.quoteAt<session.start||q.quoteAt>=session.end||q.quoteAt>observedAt||observedAt-q.quoteAt>120000){reasons.set(id,'No recent trade price is available.');continue;}
        try {
          const response=await this.request({kind:'candles',symbol:h.symbol,market:h.market,interval:'1d',count:64,adjusted:true},TTL['1d'],String(session.start));ensure();
          const closes=dailyCloses(response.data,h.market).filter(c=>dayKey(c.date,h.market)<dayKey(session.start,h.market)).sort((a,b)=>b.date-a.date).slice(0,61);
          const estimateNow=this.now(),model=estimate(q.price,closes.map(c=>c.price),session,q.quoteAt);
          const record=model&&{stockID:id,name:h.name,market:h.market,currency:h.currency,model:MODEL,createdAt:estimateNow,quoteAt:q.quoteAt,sessionStart:session.start,sessionEnd:session.end,inputPrice:q.price,previousClose:closes[0].price,...model,capture:'manual',evidence:{adjusted:true,closes},actualClose:null,evaluatedAt:null};
          if(record&&validForecast(record))records.push(record);else reasons.set(id,'At least 20 valid completed daily returns and a fresh quote are required.');
        }catch(_){ensure();reasons.set(id,'Could not load daily prediction inputs. They will be retried.');}
      }
      ensure();this.candidates=records;this.reasons=reasons;this.forecastError=this.forecastStocks.length?'':'Add a watched stock to see forecasts.';
      if(this.owner)await this.persist(h=>appendSamples(h,records,s.recordForecasts));
    }catch(_){if(revision===this.revision){this.candidates=[];this.forecastError='Could not load estimates. Check saved keys, market data access and allowed IP.';}}
    this.changed();
  }
  async tick(){
    if(!this.active())return;
    if(this.ticking){this.tickAgain=true;return;}
    this.ticking=true;
    try{await this.refreshQuotes();if(this.activeStock)await this.loadChart(this.activeStock);if(this.settings.forecastsEnabled&&(this.visible||this.activeStock||this.owner&&this.settings.recordForecasts))await this.refreshForecasts();}
    finally{this.ticking=false;if(this.tickAgain){this.tickAgain=false;void this.tick();}}
  }
  dispose(){if(!this.owner)void this.emit('stock-view-state',{visible:false}).catch(()=>{});clearInterval(this.timer);this.revision++;this.unlisten.forEach(f=>f());}
}
const KO={
 'Quote session':'거래 시간대','Day market':'데이마켓','Pre-market':'프리마켓','Regular market':'정규장','After-market':'애프터마켓','Session unavailable':'거래 시간대 확인 불가','Trading day':'거래일','Change vs prior regular close':'직전 거래일 정규장 종가 대비','Change vs regular close':'당일 정규장 종가 대비','Prior regular close':'직전 거래일 정규장 종가','Regular close':'당일 정규장 종가','Quote basis unavailable':'등락률 기준 종가를 확인할 수 없습니다',
 'Stock forecasts':'주식 예측','Show forecasts for watched stocks':'관심 종목의 예측 표시','Watched stocks use public quotes and candles. Loading accounts is optional; select an account only to include its holdings.':'관심 종목은 공개 시세와 캔들로 예측합니다. 계좌 조회는 선택 사항이며, 계좌를 선택하면 해당 보유 종목도 포함합니다.','Load accounts (optional)':'계좌 불러오기(선택)','Watchlist only · no account access':'관심 종목만 · 계좌 조회 안 함','Saved account selection':'이전에 선택한 계좌','Add a watched stock to see forecasts.':'관심 종목을 추가하면 예측을 확인할 수 있습니다.','Could not load accounts. Watchlist forecasts remain available.':'계좌를 불러오지 못했습니다. 관심 종목은 계속 예측합니다.','Could not load holdings. Watchlist forecasts remain available.':'보유 종목을 불러오지 못했습니다. 관심 종목은 계속 예측합니다.','Could not load daily prediction inputs. They will be retried.':'예측에 필요한 일봉을 불러오지 못했습니다. 다시 시도합니다.','Could not load estimates. Check saved keys, market data access and allowed IP.':'추정치를 불러오지 못했습니다. 저장한 키, 시세 접근 권한, 허용 IP를 확인하세요.',
 'Stock':'종목','Prediction evidence':'예측 근거','Input price':'입력 가격','Quote time':'체결 시각','Prediction time':'예측 시각','Target regular close':'대상 정규장 마감','Source: Toss Securities · completed, adjusted daily closes':'출처: 토스증권 · 완료된 수정 일별 종가','Daily volatility':'일별 변동성','Past 5-session return':'최근 5거래일 수익률','Past 20-session return':'최근 20거래일 수익률','Completed daily closes':'완료된 일별 종가','Date':'날짜','Close':'종가','GBM assumes zero expected return from the input price to the close. Daily volatility sizes the price range; historical returns are context, not a trend prediction. No news or AI API is used.':'GBM은 입력 가격부터 마감까지 기대 수익률을 0으로 가정합니다. 일별 변동성으로 가격 구간을 계산하며, 과거 수익률은 추세 예측이 아닌 참고 정보입니다. 뉴스나 AI API는 사용하지 않습니다.','Evidence for the daily GBM model, independent of the selected chart interval.':'선택한 차트 간격과 별개인 일봉 GBM 모델의 근거입니다.',
 'Model comparison':'모델 비교','All recorded models in the stock, day and capture filters are compared, regardless of the model filter.':'모델 필터와 관계없이 종목·거래일·기록 방식 필터에 해당하는 모든 기록 모델을 비교합니다.','Only completed records shared by every listed model are compared. Stock, quote time, input prices, daily candles, regular session, and recording mode must match. Unpaired records are excluded from both error columns.':'표시된 모든 모델이 공유하는 평가 완료 기록만 비교합니다. 종목, 체결 시각, 입력 가격, 일봉 근거, 정규장, 기록 방식이 같아야 합니다. 짝이 없는 기록은 두 오차 열 모두에서 제외합니다.','Saved / pending':'저장 / 대기','Paired samples':'대응 표본 수','No completed records with matching inputs yet.':'입력이 일치하는 평가 완료 기록이 없습니다.','This version records local GBM predictions. Its expected close equals the input price, so its MAPE equals the price-hold baseline. Lower MAPE and Brier are better; these are not investment returns.':'이 버전은 로컬 GBM 예측을 기록합니다. 기대 종가가 입력 가격과 같아 MAPE도 현재가 유지 기준과 같습니다. MAPE와 Brier는 낮을수록 좋으며 투자 수익률이 아닙니다.','Export comparison CSV':'비교 CSV 내보내기',
 'Probability check':'확률 신뢰도','Probability band':'확률 구간','Samples':'표본 수','Mean predicted rise':'평균 예측 상승 확률','Observed rise rate':'실제 상승 비율','95% Wilson interval':'95% Wilson 구간','Waiting for evaluated predictions':'평가 완료 예측을 기다립니다','Only evaluated predictions are counted. An unchanged close counts as not rising; 50% predictions are included. Empty bands are omitted. These are descriptive 95% Wilson intervals; related stocks and dates can make uncertainty larger.':'평가 완료 예측만 집계합니다. 보합은 상승하지 않은 것으로 계산하고 50% 예측도 포함합니다. 빈 구간은 생략합니다. 95% Wilson 구간은 기술 통계이며, 종목·날짜 간 상관관계로 불확실성이 더 클 수 있습니다.','Observed frequencies do not change or train the model.':'관측 비율로 모델을 변경하거나 학습하지 않습니다.','Minute traces have no capture mode; the capture filter applies to saved forecasts only.':'분별 추이에는 기록 방식이 없으므로 기록 방식 필터는 저장한 예측에만 적용됩니다.',
 'Stocks':'주식','Show stocks in notch':'노치에 주식 표시','Quote provider':'시세 제공자','Toss Securities':'토스증권','Watchlist':'관심 종목','Add symbol':'종목 추가','Company name or symbol · 삼성전자, 005930, AAPL':'회사명 또는 종목 · 삼성전자, 005930, AAPL','Keep up to 30 Korean or US stocks. Turning this off keeps your list and keys.':'한국·미국 주식을 최대 30개 등록합니다. 꺼도 목록과 키는 보존됩니다.','Only the selected provider is used.':'선택한 제공자만 사용합니다.','Finnhub supports US quotes only. Candles and holdings are unavailable.':'Finnhub는 미국 시세만 지원합니다. 캔들·보유 종목은 지원하지 않습니다.',
 'Drag to reorder':'끌어서 순서 변경','Finnhub API keys stay in Windows Credential Manager.':'Finnhub API 키는 Windows 자격 증명 관리자에 보관됩니다.','API credentials':'API 인증 정보','Client ID':'Client ID','Client secret':'Client secret','Finnhub API key':'Finnhub API 키','Save keys':'키 저장','Remove keys':'키 삭제','Saved':'저장됨','Not saved':'저장되지 않음','Keys saved':'키를 저장했습니다','Keys removed':'키를 삭제했습니다','Credentials stay in native secure storage. Register this PC’s public IP in Toss WTS → Settings → Open API → Allowed IPs.':'인증 정보는 네이티브 보안 저장소에 보관됩니다. 토스 WTS → 설정 → Open API → 허용 IP에서 이 PC의 공인 IP를 등록하세요.',
 'Show':'표시','Hide':'숨기기','Up':'위로','Down':'아래로','Remove':'삭제','Color':'색상','Automatic color':'자동 색상','Not supported by Finnhub':'Finnhub 미지원','No stocks yet. Add a name, Korean code or US ticker.':'등록한 종목이 없습니다. 회사명, 한국 종목 코드 또는 미국 티커를 추가하세요.','Company not found. Select a Korean match or enter a US ticker.':'회사를 찾을 수 없습니다. 한국 종목 검색 결과를 선택하거나 미국 티커를 입력하세요.','This stock is already in your watchlist.':'이미 등록된 종목입니다.','The watchlist holds 30 symbols.':'관심 종목은 최대 30개입니다.','Korean stocks require Toss Securities.':'한국 종목은 토스증권이 필요합니다.','KRX lookup unavailable; codes and US tickers still work.':'KRX 검색을 불러오지 못했습니다. 종목 코드와 미국 티커는 입력할 수 있습니다.',
 'Notch quote display':'노치 시세 표시','Switch interval (seconds)':'전환 간격(초)','Hover chart':'호버 차트','Chart interval':'차트 간격','Candles (1–20)':'캔들 수(1–20)','Moving averages':'이동평균','Show technical analysis':'기술적 분석 표시','20 completed bars across trading days; volume ≥1.5× prior 10 bars, SMA5/20 and breakout must agree. No account access needed.':'이전 거래일을 포함한 완료 봉 20개를 분석합니다. 거래량 ≥ 직전 10봉의 1.5배, SMA5/20 추세, 돌파 조건이 일치해야 합니다. 계좌 조회는 필요하지 않습니다.','1m refreshes each minute; 10m every 10 minutes; 1d daily. SMA includes history before the visible candles.':'1분봉은 매분, 10분봉은 10분마다, 일봉은 매일 갱신됩니다. SMA는 화면에 보이지 않는 과거 봉도 포함합니다.',
 'Read-only account access is opt-in. Account numbers, quantities and balances are never saved in history.':'동의한 경우에만 계좌를 읽습니다. 계좌번호·수량·잔고는 이력에 저장하지 않습니다.','Select an account':'계좌 선택','Automatically record forecasts':'예측 자동 기록','One prediction per stock 55–60 minutes before regular close while this app is running. Missed predictions are not backfilled.':'앱 실행 중 정규장 마감 55~60분 전에 종목당 한 번 기록합니다. 놓친 예측을 소급 생성하지 않습니다.','Save current predictions':'현재 예측 저장','Refresh':'새로고침','Forecast history':'예측 이력','Observed minute traces':'실제로 관측한 분별 추이','Saved forecasts':'저장한 예측','Export forecast CSV':'예측 CSV 내보내기','Export trace CSV':'추이 CSV 내보내기','No saved forecasts.':'저장한 예측이 없습니다.','No observed samples. Past values are not reconstructed.':'관측한 값이 없습니다. 과거 값을 재구성하지 않습니다.','Direction accuracy':'방향 정확도','MAE':'평균 절대 오차','MAPE':'평균 절대 백분율 오차','Price-hold baseline MAPE':'현재가 유지 기준 MAPE','80% range coverage':'80% 구간 포함률','Brier score':'Brier 점수','Evaluated':'평가 완료','Pending':'평가 대기','Manual':'수동','Scheduled':'자동','Target day':'대상 거래일','Model':'모델','All':'전체','Capture':'기록 방식','Saved snapshots and minute traces are separate. Scoring starts on the next market-local calendar day using unadjusted closes.':'저장한 예측과 분별 추이는 별개입니다. 시장 현지 날짜가 다음 날이 된 뒤 비수정 종가로 평가합니다.',
 'Last price':'현재가','Change':'등락률','Previous close':'전일 종가','Previous close unavailable':'전일 종가를 확인할 수 없습니다','Quote timestamp unavailable':'체결 시각을 확인할 수 없습니다','Last trade':'최근 체결','Waiting for a quote':'시세 대기 중','Stock chart':'주가 차트','Chart unavailable':'차트를 불러올 수 없습니다','Loading chart history…':'차트 이력을 불러오는 중…','No recent candles':'최근 캔들이 없습니다','Updated':'갱신','Technical analysis':'기술적 분석','Consider buying':'매수 검토','Consider selling':'매도 검토','Bullish pattern · completed bars':'상승 패턴 · 완료 봉','Bearish pattern · completed bars':'하락 패턴 · 완료 봉','Wait · conditions do not agree':'관망 · 조건 불일치','Volume / prior 10 bars':'거래량 / 직전 10봉','Prior 10-bar high / low':'직전 10봉 고가 / 저가','20-bar window':'20봉 분석 기간','Current regular-session price confirms the pattern. Not backtested.':'현재 정규장 가격이 패턴을 확인했습니다. 백테스트되지 않았습니다.','Completed-bar analysis; no live price confirmation. Not backtested.':'완료 봉 분석이며 실시간 가격 확인이 없습니다. 백테스트되지 않았습니다.','Analysis needs a fresh download and 20 complete bars with valid volume. Gaps within a trading day break the window.':'최신 조회 자료와 유효한 거래량이 있는 완료 봉 20개가 필요합니다. 거래일 내 누락 봉은 분석 구간을 끊습니다.',
 "Today's regular close":"오늘 정규장 종가",'Expected close':'기대 종가','Rise':'상승','Fall':'하락','Model 80% range':'모델 80% 구간','Returns used':'사용 수익률 수','Uncalibrated GBM: expected close equals the current quote; odds are versus the previous close.':'보정되지 않은 GBM 모델입니다. 기대 종가는 현재 시세와 같으며, 확률은 전일 종가 대비입니다.','Close estimate history · daily GBM':'종가 추정 추이 · 일봉 GBM','Observed minute samples · saved across restarts · expected close = quote':'실제 분별 표본 · 재시작 후 보존 · 기대 종가 = 시세','Waiting for 10 complete consecutive regular-session returns and a fresh quote.':'완료된 연속 정규장 수익률 10개와 최신 시세를 기다립니다.','Estimates run during the regular session only.':'종가 추정은 정규장 중에만 실행됩니다.','No recent trade price is available.':'최근 체결 가격이 없습니다.','At least 20 valid completed daily returns and a fresh quote are required.':'유효한 완료 일별 수익률 20개 이상과 최신 시세가 필요합니다.','No supported Toss account was found.':'지원하는 토스 계좌가 없습니다.','This account has no supported stock holdings.':'이 계좌에 지원하는 보유 종목이 없습니다.',
 'Stock settings unavailable':'주식 설정을 불러올 수 없습니다','Credential status unavailable':'인증 정보 상태를 확인할 수 없습니다','Could not save stock settings':'주식 설정을 저장하지 못했습니다','Quotes unavailable. Check saved keys, access and allowed IP.':'시세를 불러올 수 없습니다. 저장한 키, 접근 권한, 허용 IP를 확인하세요.','History could not be read. Original records are preserved; writes are blocked.':'이력을 읽지 못했습니다. 원본을 보존하고 덮어쓰기를 중단했습니다.','Could not save history. Existing records are retained; check disk space and permissions.':'이력을 저장하지 못했습니다. 기존 기록은 보존됩니다. 디스크 여유 공간과 권한을 확인하세요.','Some daily closes are unavailable. Pending forecasts will be retried.':'일부 종가를 확인할 수 없습니다. 해당 예측은 평가 대기 상태로 재시도합니다.','Could not save credentials. Inputs have been cleared.':'인증 정보를 저장하지 못했습니다. 입력값은 지웠습니다.','Could not remove credentials.':'인증 정보를 삭제하지 못했습니다.','Enter all credential fields.':'인증 정보 입력란을 모두 채우세요.','Stock recording service did not respond. Open the notch and try again.':'주식 기록 서비스가 응답하지 않습니다. 노치를 열고 다시 시도하세요.','No new snapshots: already saved or no fresh estimate.':'새 기록이 없습니다. 이미 저장했거나 최신 추정치가 없습니다.','Snapshots saved':'예측을 저장했습니다','Chart controls':'차트 설정','Price axis fits visible candles; averages outside the range are clipped.':'가격축은 표시된 캔들에 맞춥니다. 범위 밖 이동평균선은 잘립니다.'
};
const t=(lang,key)=>lang==='ko'?(KO[key]||key):key;
const priceText=(price,currency,lang)=>positive(price)?(currency==='USD'?'$':'')+new Intl.NumberFormat(lang==='ko'?'ko-KR':'en-US',{minimumFractionDigits:currency==='KRW'?0:2,maximumFractionDigits:currency==='KRW'?0:2}).format(price):'—';
const percentText=rate=>rate===null||!Number.isFinite(rate)?'—':(rate>=0?'+':'')+(rate*100).toFixed(2)+'%';
function quotePercentText(quote,provider) {
  const rate=changeRate(quote);
  if(provider!=='toss')return percentText(rate);
  if(rate===null||!Number.isFinite(rate*10000))return '—';
  // Remove arithmetic roundoff at exact boundaries (100 -> 100.1 is +0.10%, not +0.09%).
  const roundoff=Number.EPSILON*40000*Math.max(1,quote.price/quote.previousClose);
  return (rate<0?'-':'+')+(Math.trunc(Math.abs(rate)*10000+roundoff)/100).toFixed(2)+'%';
}
const dateText=(time,market,lang,clock=true)=>Number.isFinite(time)?new Intl.DateTimeFormat(lang==='ko'?'ko-KR':'en-US',{timeZone:zone(market),month:'2-digit',day:'2-digit',...(clock?{hour:'2-digit',minute:'2-digit',hourCycle:'h23'}:{})}).format(time):'—';
function cells(store,lang,now=store.now()) {
  if(!store.settings.enabled)return [];
  return store.settings.symbols.filter(s=>s.visible).map(stock=>{
    const id=stockID(stock),q=store.quotes.get(id),rate=changeRate(q),col=rate>0?'var(--ample)':rate<0?'#FF453A':'var(--ink-dim)';
    const text=rate!==null&&Math.floor(now/(store.settings.displayInterval*1000))%2===0?quotePercentText(q,store.settings.provider):priceText(q?.price,q?.currency,lang);
    return {id:'widget-stock:'+id,base:'stocks',stock,name:stock.name||store.names.get(id)||stock.symbol,glyph:stock.market==='us'?stock.symbol:stock.name||store.names.get(id)||stock.symbol,meter:{kind:'stock',fraction:rate===null?null:Math.min(1,Math.abs(rate)/0.3),counterclockwise:rate<0,color:col,text,stale:!!store.error||!!q&&(!Number.isFinite(q.quoteAt)||q.quoteAt>now||now-q.quoteAt>120000)}};
  });
}
function domain(values){const lo=Math.min(...values),hi=Math.max(...values),pad=hi>lo?Math.max((hi-lo)*0.08,hi*Number.EPSILON*8):Math.max(hi*0.0005,1e-8);return [Math.max(0,lo-pad),hi+pad];}
function candleSVG(raw,stock,settings,lang) {
  const history=settings.chartInterval==='10m'?tenMinuteBars(raw):raw,bars=history.slice(-settings.candleCount);
  if(!bars.length)return `<p>${esc(t(lang,'No recent candles'))}</p>`;
  const width=230,height=255,left=45,right=5,top=12,bottom=30,[min,max]=domain(bars.flatMap(b=>[b.low,b.high]));
  const y=v=>top+(max-v)/(max-min)*(height-top-bottom),x=i=>left+(i+.5)*(width-left-right)/bars.length;
  let body='';
  for(let i=0;i<4;i++){const v=min+(max-min)*i/3,yy=y(v);body+=`<line x1="${left}" y1="${yy}" x2="225" y2="${yy}" class="stock-grid"/><text x="${left-3}" y="${yy+3}" text-anchor="end">${esc(priceText(v,stock.market==='kr'?'KRW':'USD',lang))}</text>`;}
  let plot='';
  bars.forEach((b,i)=>{
    const color=stock.market==='kr'?(b.close>=b.open?'#f06565':'#5795ff'):(b.close>=b.open?'#24bc85':'#f06565'),xx=x(i),bw=Math.min(6,(width-left-right)/bars.length*.65);
    plot+=`<g><title>${esc(dateText(b.end,stock.market,lang))} · O ${b.open} H ${b.high} L ${b.low} C ${b.close} V ${b.volume}</title><line x1="${xx}" x2="${xx}" y1="${y(b.high)}" y2="${y(b.low)}" stroke="${color}"/><rect x="${xx-bw/2}" y="${Math.min(y(b.open),y(b.close))}" width="${bw}" height="${Math.max(1,Math.abs(y(b.open)-y(b.close)))}" fill="${color}"/></g>`;
  });
  const colors={5:'#e2b326',20:'#26baca',60:'#b27ae2',120:'#e88d39'};
  let legend='';
  for(const period of settings.movingAverages){const average=movingAverage(history,period).slice(-bars.length);const points=average.flatMap((v,i)=>v===null?[]:[`${x(i)},${y(v)}`]).join(' ');if(points)plot+=`<polyline points="${points}" fill="none" stroke="${colors[period]}" stroke-width="1.3"/>`;legend+=`<span style="color:${colors[period]}">SMA${period}${average.at(-1)===null?' —':''}</span> `;}
  body+=`<svg x="${left}" y="${top}" width="${width-left-right}" height="${height-top-bottom}" viewBox="${left} ${top} ${width-left-right} ${height-top-bottom}" overflow="hidden">${plot}</svg>`;
  body+=`<text x="${left}" y="${height-9}">${esc(dateText(bars[0].end,stock.market,lang,settings.chartInterval!=='1d'))}</text><text x="225" y="${height-9}" text-anchor="end">${esc(dateText(bars.at(-1).end,stock.market,lang,settings.chartInterval!=='1d'))}</text>`;
  return `<div class="stock-small">${legend}</div><svg class="stock-chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="${esc(t(lang,'Stock chart'))}"><title>${esc(t(lang,'Price axis fits visible candles; averages outside the range are clipped.'))}</title>${body}</svg>`;
}
function traceSVG(points,market,lang) {
  if(!points.length)return `<p class="stock-small">${esc(t(lang,'No observed samples. Past values are not reconstructed.'))}</p>`;
  const [min,max]=domain(points.map(p=>p.expectedClose)),first=points[0].createdAt,last=points.at(-1).createdAt,x=p=>42+(p.createdAt-first)/Math.max(last-first,60000)*180,y=p=>8+(max-p.expectedClose)/(max-min)*68;
  let marks='',segment=[];
  const flush=()=>{if(segment.length>1)marks+=`<polyline points="${segment.join(' ')}" fill="none" stroke="#26baca" stroke-width="1.5"/>`;segment=[];};
  points.forEach((p,i)=>{if(i&&p.createdAt-points[i-1].createdAt>180000)flush();segment.push(`${x(p)},${y(p)}`);marks+=`<circle cx="${x(p)}" cy="${y(p)}" r="2" fill="#26baca"><title>${esc(dateText(p.createdAt,market,lang))}: ${p.expectedClose}</title></circle>`;});flush();
  return `<svg class="stock-trace" viewBox="0 0 230 100" role="img" aria-label="${esc(t(lang,'Close estimate history · daily GBM'))}"><text x="0" y="12">${max.toFixed(2)}</text><text x="0" y="76">${min.toFixed(2)}</text>${marks}<text x="42" y="95">${esc(dateText(first,market,lang))}</text><text x="225" y="95" text-anchor="end">${esc(dateText(last,market,lang))}</text></svg>`;
}
function forecastHTML(record,estimate,lang) {
  const tr=key=>esc(t(lang,key)),p=v=>esc(priceText(v,record.currency,lang));
  return `<p>${tr('Expected close')}: <b>${p(estimate.expectedClose)}</b></p><p>${tr('Rise')} ≈${(estimate.riseProbability*100).toFixed(1)}% · ${tr('Fall')} ≈${((1-estimate.riseProbability)*100).toFixed(1)}%</p><p>${tr('Model 80% range')}: ${p(estimate.lowerClose)} – ${p(estimate.upperClose)}</p><p class="stock-small">${esc(dateText(record.sessionEnd,record.market,lang))} (${zone(record.market)}) · ${estimate.observations} ${tr('Returns used')}</p>${record.model===MODEL?`<p class="stock-small">${tr('Uncalibrated GBM: expected close equals the current quote; odds are versus the previous close.')}</p>`:''}`;
}
function rememberDisclosures(element) {
  const selector='details[data-stock-disclosure]',open=new Set([...element.querySelectorAll(selector)].filter(node=>node.open).map(node=>node.dataset.stockDisclosure));
  return ()=>element.querySelectorAll(selector).forEach(node=>{node.open=open.has(node.dataset.stockDisclosure);});
}
function evidenceHTML(record,lang,key='evidence:'+forecastID(record)) {
  const tr=key=>esc(t(lang,key)),p=v=>esc(priceText(v,record.currency,lang)),closes=record.evidence.closes;
  const time=v=>esc(new Intl.DateTimeFormat(lang==='ko'?'ko-KR':'en-US',{timeZone:zone(record.market),year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23',timeZoneName:'short'}).format(v));
  const percent=v=>Number.isFinite(v)?(v*100).toFixed(2)+'%':'—',historical=n=>closes.length>n?closes[0].price/closes[n].price-1:NaN;
  return `<details class="stock-evidence" data-stock-disclosure="${esc(key)}"><summary>${tr('Prediction evidence')}</summary><dl class="stock-metrics"><dt>${tr('Model')}</dt><dd>${esc(record.model)}</dd><dt>${tr('Input price')}</dt><dd>${p(record.inputPrice)}</dd><dt>${tr('Previous close')}</dt><dd>${p(record.previousClose)}</dd><dt>${tr('Quote time')}</dt><dd>${time(record.quoteAt)}</dd><dt>${tr('Prediction time')}</dt><dd>${time(record.createdAt)}</dd><dt>${tr('Target regular close')}</dt><dd>${time(record.sessionEnd)}</dd></dl><p class="stock-small">${tr('Source: Toss Securities · completed, adjusted daily closes')}</p><dl class="stock-metrics"><dt>${tr('Daily volatility')}</dt><dd>${percent(Math.sqrt(dailyVariance(closes.map(c=>c.price))))}</dd><dt>${tr('Past 5-session return')}</dt><dd>${percent(historical(5))}</dd><dt>${tr('Past 20-session return')}</dt><dd>${percent(historical(20))}</dd></dl><details data-stock-disclosure="${esc(key)}|closes"><summary>${tr('Completed daily closes')} (${closes.length})</summary><div class="stock-table-wrap"><table class="stock-table"><thead><tr><th scope="col">${tr('Date')}</th><th scope="col">${tr('Close')}</th></tr></thead><tbody>${closes.map(c=>`<tr><th scope="row">${esc(dayKey(c.date,record.market))}</th><td>${p(c.price)}</td></tr>`).join('')}</tbody></table></div></details>${record.model===MODEL?`<p class="stock-small">${tr('GBM assumes zero expected return from the input price to the close. Daily volatility sizes the price range; historical returns are context, not a trend prediction. No news or AI API is used.')}</p>`:''}</details>`;
}
function comparisonHTML(records,lang) {
  const tr=key=>esc(t(lang,key)),comparison=compareModels(records),decimal=(v,suffix='')=>v===null?'—':v.toFixed(3)+suffix;
  return `<details data-stock-disclosure="comparison"><summary>${tr('Model comparison')}</summary><p class="stock-small">${tr('All recorded models in the stock, day and capture filters are compared, regardless of the model filter.')}</p><p class="stock-small">${tr('Only completed records shared by every listed model are compared. Stock, quote time, input prices, daily candles, regular session, and recording mode must match. Unpaired records are excluded from both error columns.')}</p><div class="stock-table-wrap"><table class="stock-table"><thead><tr>${['Model','Saved / pending','Paired samples','MAPE','Brier score'].map(key=>`<th scope="col">${tr(key)}</th>`).join('')}</tr></thead><tbody>${comparison.rows.map(row=>`<tr><th scope="row">${esc(row.model)}</th><td>${row.available.total} / ${row.available.total-row.available.evaluated}</td><td>${row.paired.evaluated}</td><td>${decimal(row.paired.mape,'%')}</td><td>${decimal(row.paired.brier)}</td></tr>`).join('')}</tbody></table></div><p>${tr('Price-hold baseline MAPE')}: ${decimal(comparison.baseline,'%')} · n=${comparison.pairedCount}</p>${comparison.pairedCount?'':`<p>${tr('No completed records with matching inputs yet.')}</p>`}<p class="stock-small">${tr('This version records local GBM predictions. Its expected close equals the input price, so its MAPE equals the price-hold baseline. Lower MAPE and Brier are better; these are not investment returns.')}</p><button id="stock-export-comparison" ${records.length?'':'disabled'}>${tr('Export comparison CSV')}</button></details>`;
}
function probabilityHTML(records,lang) {
  const tr=key=>esc(t(lang,key)),percent=v=>(v*100).toFixed(1)+'%',groups=new Map();
  for(const r of records){const key=JSON.stringify([r.model,r.capture]);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(r);}
  let html=`<details data-stock-disclosure="probability"><summary>${tr('Probability check')}</summary><p class="stock-small">${tr('Only evaluated predictions are counted. An unchanged close counts as not rising; 50% predictions are included. Empty bands are omitted. These are descriptive 95% Wilson intervals; related stocks and dates can make uncertainty larger.')}</p>`;
  if(!records.length)html+=`<p>${tr('Waiting for evaluated predictions')}</p>`;
  for(const rows of groups.values()) {
    const bins=probabilityBins(rows);html+=`<h3>${esc(rows[0].model)} · ${tr(rows[0].capture==='manual'?'Manual':'Scheduled')}</h3>`;
    html+=bins.length?`<div class="stock-table-wrap"><table class="stock-table"><thead><tr>${['Probability band','Samples','Mean predicted rise','Observed rise rate','95% Wilson interval'].map(key=>`<th scope="col">${tr(key)}</th>`).join('')}</tr></thead><tbody>${bins.map(bin=>`<tr><th scope="row">${bin.id===9?'90–100%':`${bin.id*10}–&lt;${(bin.id+1)*10}%`}</th><td>${bin.count}</td><td>${percent(bin.meanProbability)}</td><td>${percent(bin.observedRate)}</td><td>${percent(bin.lower)} – ${percent(bin.upper)}</td></tr>`).join('')}</tbody></table></div>`:`<p>${tr('Waiting for evaluated predictions')}</p>`;
  }
  return html+`<p class="stock-small">${tr('Observed frequencies do not change or train the model.')}</p></details>`;
}
function cardHTML(store,stock,lang) {
  const tr=key=>esc(t(lang,key)),s=store.settings,id=stockID(stock),q=store.quotes.get(id),now=store.now(),name=stock.name||store.names.get(id)||stock.symbol;
  let html=`<div class="stock-card"><div class="c-head"><span class="c-title">${esc(name)}</span></div><div class="stock-small">${esc(id)} · ${tr(s.provider==='toss'?'Toss Securities':'Finnhub')}</div>`;
  html+=`<p><b>${priceText(q?.price,q?.currency,lang)}</b> · ${quotePercentText(q,s.provider)}</p>`;
  if(s.provider==='toss'&&stock.market==='us') {
    const context=q?.context,after=context?.phase==='afterMarket',phase={dayMarket:'Day market',preMarket:'Pre-market',regularMarket:'Regular market',afterMarket:'After-market'}[context?.phase];
    html+=`<p class="stock-small">${tr('Quote session')}: ${tr(phase||'Session unavailable')}${context?' · '+tr('Trading day')+' '+esc(context.tradingDay):''}</p>`;
    if(context)html+=`<p class="stock-small">${tr(after?'Change vs regular close':'Change vs prior regular close')}: ${quotePercentText(q,s.provider)}</p><p class="stock-small">${tr(after?'Regular close':'Prior regular close')}: ${positive(q?.previousClose)?priceText(q.previousClose,q.currency,lang)+' · '+esc(q.basisDate)+' ET':tr('Quote basis unavailable')}</p>`;
  }else html+=`<p class="stock-small">${tr('Previous close')}: ${positive(q?.previousClose)?priceText(q.previousClose,q.currency,lang):tr('Previous close unavailable')}</p>`;
  html+=`<p class="stock-small">${Number.isFinite(q?.quoteAt)?tr('Last trade')+': '+esc(new Intl.DateTimeFormat(lang==='ko'?'ko-KR':'en-US',{timeZone:zone(stock.market),year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).format(q.quoteAt))+' '+(stock.market==='us'?'ET':'KST'):tr('Quote timestamp unavailable')}</p>`;
  if(store.error)html+=`<p class="stock-error">${tr(store.error)}</p>`;
  if(!q)html+=`<p>${tr('Waiting for a quote')}</p>`;
  const index=s.symbols.findIndex(x=>stockID(x)===id);
  html+=`<div class="stock-actions"><button data-stock-move="-1" ${index===0||store.busy?'disabled':''}>${tr('Up')}</button><button data-stock-move="1" ${index===s.symbols.length-1||store.busy?'disabled':''}>${tr('Down')}</button><button data-stock-hide ${store.busy?'disabled':''}>${tr('Hide')}</button><input type="color" data-stock-color value="#${stock.color||'36a8eb'}" aria-label="${tr('Color')}" ${store.busy?'disabled':''}><button data-stock-auto ${store.busy?'disabled':''}>${tr('Automatic color')}</button></div>`;
  if(s.provider==='finnhub')return html+`<p class="stock-small">${tr('Finnhub supports US quotes only. Candles and holdings are unavailable.')}</p></div>`;
  const entry=store.charts.get(id+'|'+s.chartInterval),record=store.candidates.find(r=>r.stockID===id);
  html+=`<section><h3>${tr('Stock chart')}</h3><div class="stock-actions" role="group" aria-label="${tr('Chart interval')}">${Object.keys(TTL).map(interval=>`<button data-stock-interval="${interval}" aria-pressed="${s.chartInterval===interval}" ${store.busy?'disabled':''}>${interval}</button>`).join('')}</div>`;
  html+=entry?.candles?.length?candleSVG(entry.candles,stock,s,lang):`<p>${tr(entry?.loading?'Loading chart history…':entry?.error||'No recent candles')}</p>`;
  if(entry?.error)html+=`<p class="stock-error">${tr(entry.error)}</p>`;
  if(entry?.fetchedAt)html+=`<p class="stock-small">${tr('Updated')} ${esc(dateText(entry.fetchedAt,stock.market,lang))} · ${s.chartInterval}</p>`;
  html+='</section>';
  if(s.showTechnical){
    const signal=entry?.candles&&!entry.error?technical(entry.candles,s.chartInterval,stock.market,entry.fetchedAt,now,record):null;
    html+=`<section><h3>${tr('Technical analysis')} · ${s.chartInterval}</h3>`;
    if(signal){const label=signal.action==='buy'?(signal.live?'Consider buying':'Bullish pattern · completed bars'):signal.action==='sell'?(signal.live?'Consider selling':'Bearish pattern · completed bars'):'Wait · conditions do not agree';html+=`<p><b>${tr(label)}</b></p><p>${tr('Volume / prior 10 bars')}: ${signal.ratio.toFixed(2)}×</p><p>SMA 5 / 20: ${priceText(signal.fast,q?.currency||(stock.market==='kr'?'KRW':'USD'),lang)} / ${priceText(signal.slow,q?.currency||(stock.market==='kr'?'KRW':'USD'),lang)}</p><p>${tr('Prior 10-bar high / low')}: ${signal.high.toFixed(2)} / ${signal.low.toFixed(2)}</p><p>${tr('20-bar window')}: ${esc(dateText(signal.firstAt,stock.market,lang))} – ${esc(dateText(signal.lastAt,stock.market,lang))}</p><p class="stock-small">${tr(signal.live?'Current regular-session price confirms the pattern. Not backtested.':'Completed-bar analysis; no live price confirmation. Not backtested.')}</p>`;}
    else html+=`<p>${tr('Analysis needs a fresh download and 20 complete bars with valid volume. Gaps within a trading day break the window.')}</p>`;
    html+='</section>';
  }
  if(s.forecastsEnabled){
    const forecast=record&&(s.chartInterval==='1d'||entry?.candles&&!entry.error)?chartEstimate(record,entry?.candles||[],s.chartInterval,now):null;
    html+=`<section><h3>${tr("Today's regular close")} · ${s.chartInterval}</h3>`;
    if(forecast)html+=forecastHTML(record,forecast,lang);
    else html+=`<p>${tr(store.forecastError||store.reasons.get(id)||(record?'Waiting for 10 complete consecutive regular-session returns and a fresh quote.':'Add a watched stock to see forecasts.'))}</p>`;
    const points=(store.history?.trends||[]).filter(p=>p.stockID===id&&p.model===MODEL&&dayKey(p.sessionStart,p.market)===dayKey(now,p.market)&&p.createdAt<=now).sort((a,b)=>a.createdAt-b.createdAt);
    html+=`<h3>${tr('Close estimate history · daily GBM')}</h3>${traceSVG(points,stock.market,lang)}<p class="stock-small">${tr('Observed minute samples · saved across restarts · expected close = quote')}</p>${record?`<p class="stock-small">${tr('Evidence for the daily GBM model, independent of the selected chart interval.')}</p>${evidenceHTML(record,lang)}`:''}</section>`;
  }
  if(store.historyError)html+=`<p class="stock-error">${tr(store.historyError)}</p>`;
  return html+'</div>';
}
function bindCard(element,store,stock) {
  const id=stockID(stock),saveStock=patch=>store.saveSettings({...store.settings,symbols:store.settings.symbols.map(s=>stockID(s)===id?{...s,...patch}:s)});
  element.querySelectorAll('[data-stock-interval]').forEach(b=>b.onclick=()=>store.saveSettings({...store.settings,chartInterval:b.dataset.stockInterval}));
  element.querySelectorAll('[data-stock-move]').forEach(b=>b.onclick=()=>moveStock(store,id,+b.dataset.stockMove));
  const hide=element.querySelector('[data-stock-hide]');if(hide)hide.onclick=()=>saveStock({visible:false});
  const color=element.querySelector('[data-stock-color]');if(color)color.onchange=()=>saveStock({color:color.value.slice(1)});
  const auto=element.querySelector('[data-stock-auto]');if(auto)auto.onclick=()=>saveStock({color:undefined});
}
function moveStock(store,id,offset) {
  const symbols=store.settings.symbols.slice(),at=symbols.findIndex(s=>stockID(s)===id),next=at+offset;
  if(at<0||next<0||next>=symbols.length)return Promise.resolve(false);
  [symbols[at],symbols[next]]=[symbols[next],symbols[at]];
  return store.saveSettings({...store.settings,symbols});
}
// Reorder visible stocks into their original slots: hidden rows do not migrate.
function reorderStocks(symbols,from,target) {
  const visible=symbols.filter(s=>s.visible!==false),ids=visible.map(stockID),a=ids.indexOf(from),b=ids.indexOf(target);
  if(a<0||b<0||a===b)return symbols;
  visible.splice(b,0,visible.splice(a,1)[0]);let index=0;
  return symbols.map(s=>s.visible===false?s:visible[index++]);
}
function dragStarted(press,event) {return !press.altKey&&Math.hypot(event.clientX-press.clientX,event.clientY-press.clientY)>=5;}
function bindStockDrag(element,store,onState=()=>{}) {
  const doc=element.ownerDocument;let press=null;
  const clear=()=>element.querySelectorAll('.stock-drag-source,.stock-drop-target').forEach(e=>e.classList.remove('stock-drag-source','stock-drop-target'));
  const finish=(commit=false)=>{
    if(!press)return;const current=press;press=null;
    if(element.hasPointerCapture?.(current.pointerId))element.releasePointerCapture(current.pointerId);
    clear();
    if(!current.active&&!commit)onState(false);
    if(current.active){onState(false);if(commit&&current.revision===store.revision&&current.target){const symbols=reorderStocks(store.settings.symbols,current.id,current.target);if(symbols!==store.settings.symbols)void store.saveSettings({...store.settings,symbols});}}
  };
  const down=e=>{
    if(e.button!==0||e.altKey||store.busy||e.target.closest('button,input,select,a'))return;
    const row=e.target.closest('[data-stock-drag]');if(!row||!element.contains(row))return;
    press={id:row.dataset.stockDrag,pointerId:e.pointerId,clientX:e.clientX,clientY:e.clientY,altKey:e.altKey,revision:store.revision,active:false,target:null};
    element.setPointerCapture?.(e.pointerId);
  };
  const move=e=>{
    if(!press||e.pointerId!==press.pointerId)return;
    if(!press.active&&!dragStarted(press,e))return;
    if(!press.active){press.active=true;onState(true);}
    e.preventDefault();clear();
    const over=doc.elementFromPoint(e.clientX,e.clientY)?.closest('[data-stock-drag]');
    press.target=over&&element.contains(over)?over.dataset.stockDrag:null;
    element.querySelectorAll('[data-stock-drag]').forEach(row=>{row.classList.toggle('stock-drag-source',row.dataset.stockDrag===press.id);row.classList.toggle('stock-drop-target',row.dataset.stockDrag===press.target&&press.target!==press.id);});
  };
  const up=e=>{if(press&&e.pointerId===press.pointerId)finish(true);};
  const cancel=()=>finish();
  const key=e=>{if(e.key==='Escape')finish();};
  element.addEventListener('pointerdown',down);doc.addEventListener('pointermove',move);doc.addEventListener('pointerup',up);doc.addEventListener('pointercancel',cancel);doc.addEventListener('keydown',key);doc.defaultView?.addEventListener('blur',cancel);
  return ()=>{finish();element.removeEventListener('pointerdown',down);doc.removeEventListener('pointermove',move);doc.removeEventListener('pointerup',up);doc.removeEventListener('pointercancel',cancel);doc.removeEventListener('keydown',key);doc.defaultView?.removeEventListener('blur',cancel);};
}
function parseDirectory(text) {
  return String(text).split(/\r?\n/).flatMap(line=>{if(line.startsWith('#'))return [];const [code,name,market,...extra]=line.split('\t');return !extra.length&&parseStock('KR:'+code)&&name?[{code,name,market}]:[];});
}
const nameKey=s=>String(s).trim().replace(/ /g,'').normalize('NFC').toLowerCase();
function findCompanies(directory,query) {
  const key=nameKey(query);if(!key)return [];
  return directory.filter(c=>nameKey(c.name).includes(key)||c.code.startsWith(query.trim().toUpperCase())).sort((a,b)=>(+nameKey(b.name).startsWith(key)-+nameKey(a.name).startsWith(key))||a.name.length-b.name.length||a.name.localeCompare(b.name)).slice(0,8);
}
function downloadCSV(records,trace) {
  const url=URL.createObjectURL(new Blob(['\ufeff'+csv(records,trace)],{type:'text/csv;charset=utf-8'})),a=document.createElement('a');
  a.href=url;a.download=trace?'penguinnotch-stock-traces.csv':'penguinnotch-stock-forecasts.csv';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
}
function mountSettings({element,store,language=()=> 'en'}) {
  let directory=[],message='',credentialMessage='',credentialError=false,snapshotMessage='',snapshotError=false,pendingSnapshot='',credentialBusy=false,snapshotBusy=false,historyFilter={stockID:'',day:'',model:'',capture:''},lastMarkup='',snapshotTimer;
  const tr=key=>esc(t(language(),key));
  const save=patch=>store.saveSettings({...store.settings,...patch});
  const status=()=>{const e=element.querySelector('#stock-message');if(e)e.textContent=t(language(),message);const service=element.querySelector('#stock-service-message');if(service)service.textContent=t(language(),store.error);const credentials=element.querySelector('#stock-credential-message');if(credentials){credentials.textContent=t(language(),credentialMessage);credentials.classList.toggle('stock-error',credentialError);}};
  function toggle(label,key,value,disabled=false){return `<label class="stock-row"><span>${tr(label)}</span><input type="checkbox" data-setting="${key}" ${value?'checked':''} ${disabled||store.busy?'disabled':''}></label>`;}
  function render() {
    const lang=language(),s=store.settings,active=document.activeElement,restoreDisclosures=rememberDisclosures(element);
    const focused=active&&element.contains(active)&&active.id?{id:active.id,value:active.value,start:active.selectionStart,end:active.selectionEnd}:null;
    // Quote ticks must not replace focused controls or retain credentials in JS.
    const sig=JSON.stringify([s,store.busy,store.credentials,store.accounts,store.accountsBusy,lang,credentialBusy]);
    if(sig!==lastMarkup){
      if(active?.type==='password'&&element.contains(active)&&!credentialBusy)return;
      lastMarkup=sig;
      element.innerHTML=`<div class="stock-settings"><section><h2>${tr('Stocks')}</h2><p id="stock-service-message" class="stock-error" role="status"></p>${toggle('Show stocks in notch','enabled',s.enabled)}<p class="stock-small">${tr('Keep up to 30 Korean or US stocks. Turning this off keeps your list and keys.')}</p><label class="stock-row">${tr('Quote provider')}<select id="stock-provider" aria-label="${tr('Quote provider')}" ${store.busy?'disabled':''}><option value="toss" ${s.provider==='toss'?'selected':''}>${tr('Toss Securities')}</option><option value="finnhub" ${s.provider==='finnhub'?'selected':''}>Finnhub</option></select></label><p class="stock-small">${tr('Only the selected provider is used.')}</p>${s.provider==='finnhub'?`<p class="stock-small">${tr('Finnhub supports US quotes only. Candles and holdings are unavailable.')}</p>`:''}</section>
      <section><h2>${tr('API credentials')} · ${tr(store.credentials[s.provider]?'Saved':'Not saved')}</h2><form id="stock-credentials" autocomplete="off"><fieldset ${credentialBusy?'disabled':''}>${s.provider==='toss'?`<label>${tr('Client ID')}<input id="stock-client-id" type="password" autocomplete="new-password" required></label><label>${tr('Client secret')}<input id="stock-client-secret" type="password" autocomplete="new-password" required></label>`:`<label>${tr('Finnhub API key')}<input id="stock-api-key" type="password" autocomplete="new-password" required></label>`}<div class="stock-actions"><button type="submit">${tr('Save keys')}</button><button id="stock-remove-keys" type="button">${tr('Remove keys')}</button></div></fieldset></form><p id="stock-credential-message" role="status"></p><p class="stock-small">${tr(s.provider==='toss'?'Credentials stay in native secure storage. Register this PC’s public IP in Toss WTS → Settings → Open API → Allowed IPs.':'Finnhub API keys stay in Windows Credential Manager.')}</p></section>
      <section><h2>${tr('Watchlist')} (${s.symbols.length}/30)</h2><form id="stock-add-form" class="stock-add"><label for="stock-symbol">${tr('Add symbol')}</label><div class="stock-actions"><input id="stock-symbol" placeholder="${tr('Company name or symbol · 삼성전자, 005930, AAPL')}" autocomplete="off" maxlength="100"><button type="submit" ${store.busy?'disabled':''}>${tr('Add symbol')}</button></div><div id="stock-matches"></div></form><p id="stock-message" role="status" class="stock-error"></p><div class="stock-watchlist">${s.symbols.length?s.symbols.map((stock,i)=>`<div class="stock-watch-row" ${stock.visible?`data-stock-drag="${esc(stockID(stock))}"`: ''}><span>${stock.visible?`<span class="stock-drag-handle" title="${tr('Drag to reorder')}" aria-hidden="true">⠿</span> `:''}<b>${esc(stock.name||store.names.get(stockID(stock))||stock.symbol)}</b><small>${esc(stockID(stock))}${s.provider==='finnhub'&&stock.market==='kr'?' · '+tr('Not supported by Finnhub'):''}</small></span><div class="stock-actions"><label title="${tr('Show')}"><input type="checkbox" data-visible="${i}" aria-label="${tr('Show')} ${esc(stock.symbol)}" ${stock.visible?'checked':''} ${store.busy?'disabled':''}>${tr('Show')}</label><input type="color" data-color="${i}" value="#${stock.color||'36a8eb'}" aria-label="${tr('Color')} ${esc(stock.symbol)}" ${store.busy?'disabled':''}><button data-auto="${i}" ${store.busy?'disabled':''}>${tr('Automatic color')}</button><button data-move="${i}" data-dir="-1" aria-label="${tr('Up')} ${esc(stock.symbol)}" ${!i||store.busy?'disabled':''}>↑</button><button data-move="${i}" data-dir="1" aria-label="${tr('Down')} ${esc(stock.symbol)}" ${i===s.symbols.length-1||store.busy?'disabled':''}>↓</button><button data-remove="${i}" aria-label="${tr('Remove')} ${esc(stock.symbol)}" ${store.busy?'disabled':''}>${tr('Remove')}</button></div></div>`).join(''):`<p>${tr('No stocks yet. Add a name, Korean code or US ticker.')}</p>`}</div></section>
      <section><h2>${tr('Notch quote display')}</h2><label class="stock-row">${tr('Switch interval (seconds)')}<input type="number" id="stock-display-interval" aria-label="${tr('Switch interval (seconds)')}" min="1" max="10" value="${s.displayInterval}" ${store.busy?'disabled':''}></label></section>
      ${s.provider==='toss'?`<section><h2>${tr('Hover chart')}</h2><label class="stock-row">${tr('Chart interval')}<select id="stock-chart-interval" aria-label="${tr('Chart interval')}" ${store.busy?'disabled':''}>${Object.keys(TTL).map(k=>`<option ${s.chartInterval===k?'selected':''}>${k}</option>`).join('')}</select></label><label class="stock-row">${tr('Candles (1–20)')}<input type="number" id="stock-candle-count" aria-label="${tr('Candles (1–20)')}" min="1" max="20" value="${s.candleCount}" ${store.busy?'disabled':''}></label><p>${tr('Moving averages')}</p><div class="stock-actions">${[5,20,60,120].map(n=>`<label><input type="checkbox" data-sma="${n}" ${s.movingAverages.includes(n)?'checked':''} ${store.busy?'disabled':''}> SMA ${n}</label>`).join('')}</div><p class="stock-small">${tr('1m refreshes each minute; 10m every 10 minutes; 1d daily. SMA includes history before the visible candles.')}</p>${toggle('Show technical analysis','showTechnical',s.showTechnical)}<p class="stock-small">${tr('20 completed bars across trading days; volume ≥1.5× prior 10 bars, SMA5/20 and breakout must agree. No account access needed.')}</p></section>
      <section><h2>${tr('Stock forecasts')}</h2>${toggle('Show forecasts for watched stocks','forecastsEnabled',s.forecastsEnabled)}<p class="stock-small">${tr('Watched stocks use public quotes and candles. Loading accounts is optional; select an account only to include its holdings.')}</p>${s.forecastsEnabled?`<div class="stock-actions"><button id="stock-load-accounts" ${!store.active()||store.accountsBusy||store.busy?'disabled':''}>${tr('Load accounts (optional)')}</button><label>${tr('Select an account')} <select id="stock-account" aria-label="${tr('Select an account')}" ${store.busy||store.accountsBusy?'disabled':''}><option value="0">${tr('Watchlist only · no account access')}</option>${s.accountSeq>0&&!store.accounts.some(a=>a.accountSeq===s.accountSeq)?`<option value="${s.accountSeq}" selected>${tr('Saved account selection')}</option>`:''}${store.accounts.map(a=>`<option value="${a.accountSeq}" ${a.accountSeq===s.accountSeq?'selected':''}>${esc(a.label)}</option>`).join('')}</select></label></div><p id="stock-account-message" role="status" class="stock-error"></p><p class="stock-small">${tr('Read-only account access is opt-in. Account numbers, quantities and balances are never saved in history.')}</p>${toggle('Automatically record forecasts','recordForecasts',s.recordForecasts)}<p class="stock-small">${tr('One prediction per stock 55–60 minutes before regular close while this app is running. Missed predictions are not backfilled.')}</p><div class="stock-actions"><button id="stock-snapshot">${tr('Save current predictions')}</button><button id="stock-refresh-holdings">${tr('Refresh')}</button></div><p id="stock-snapshot-status" role="status"></p><div id="stock-holdings"></div>`:''}</section>`:''}
      <section><h2>${tr('Forecast history')}</h2><p class="stock-small">${tr('Saved snapshots and minute traces are separate. Scoring starts on the next market-local calendar day using unadjusted closes.')}</p><div id="stock-history"></div></section></div>`;
      bind();
      if(focused&&focused.id==='stock-symbol'){const next=element.querySelector('#stock-symbol');next.value=focused.value;next.focus();next.setSelectionRange(focused.start,focused.end);search();}
      else if(focused&&active?.type!=='password'){element.querySelector('#'+focused.id)?.focus();}
    }
    status();renderPortfolio();renderHistory();restoreDisclosures();
  }
  function search(){const input=element.querySelector('#stock-symbol'),host=element.querySelector('#stock-matches');if(!input||!host)return;host.innerHTML='';if(store.settings.provider!=='toss')return;for(const c of findCompanies(directory,input.value)){const b=document.createElement('button');b.type='button';b.textContent=`${c.name} · ${c.code} (${c.market})`;b.onclick=()=>add(c.code);host.appendChild(b);}}
  async function add(raw) {
    const input=element.querySelector('#stock-symbol'),value=raw||input.value,company=directory.find(c=>nameKey(c.name)===nameKey(value)||c.code===value.trim().toUpperCase());
    const stock=company?parseStock('KR:'+company.code):parseStock(value);
    message=!stock?'Company not found. Select a Korean match or enter a US ticker.':stock.market==='kr'&&store.settings.provider==='finnhub'?'Korean stocks require Toss Securities.':store.settings.symbols.some(s=>stockID(s)===stockID(stock))?'This stock is already in your watchlist.':store.settings.symbols.length>=30?'The watchlist holds 30 symbols.':'';
    if(!message){const ok=await save({symbols:[...store.settings.symbols,{...stock,name:company?.name||'',visible:true}]});if(ok){const field=element.querySelector('#stock-symbol');if(field)field.value='';search();}}
    status();element.querySelector('#stock-symbol')?.focus();
  }
  function bind() {
    element.querySelectorAll('[data-setting]').forEach(e=>e.onchange=()=>save({[e.dataset.setting]:e.checked}));
    element.querySelector('#stock-provider').onchange=e=>save({provider:e.target.value});
    const number=(id,key)=>{const input=element.querySelector('#'+id);if(input)input.onchange=()=>{if(input.checkValidity())save({[key]:Number(input.value)});};};
    number('stock-display-interval','displayInterval');number('stock-candle-count','candleCount');
    const chart=element.querySelector('#stock-chart-interval');if(chart)chart.onchange=()=>save({chartInterval:chart.value});
    const loadAccounts=element.querySelector('#stock-load-accounts');if(loadAccounts)loadAccounts.onclick=()=>store.loadAccounts();
    const account=element.querySelector('#stock-account');if(account)account.onchange=()=>save({accountSeq:+account.value});
    element.querySelectorAll('[data-sma]').forEach(e=>e.onchange=()=>save({movingAverages:[...element.querySelectorAll('[data-sma]:checked')].map(n=>+n.dataset.sma)}));
    const mutate=(index,patch)=>save({symbols:store.settings.symbols.map((s,i)=>i===index?{...s,...patch}:s)});
    element.querySelectorAll('[data-visible]').forEach(e=>e.onchange=()=>mutate(+e.dataset.visible,{visible:e.checked}));
    element.querySelectorAll('[data-color]').forEach(e=>e.onchange=()=>mutate(+e.dataset.color,{color:e.value.slice(1)}));
    element.querySelectorAll('[data-auto]').forEach(e=>e.onclick=()=>mutate(+e.dataset.auto,{color:undefined}));
    element.querySelectorAll('[data-remove]').forEach(e=>e.onclick=()=>save({symbols:store.settings.symbols.filter((_,i)=>i!==+e.dataset.remove)}));
    element.querySelectorAll('[data-move]').forEach(e=>e.onclick=()=>moveStock(store,stockID(store.settings.symbols[+e.dataset.move]),+e.dataset.dir));
    element.querySelector('#stock-add-form').onsubmit=e=>{e.preventDefault();void add();};element.querySelector('#stock-symbol').oninput=search;
    element.querySelector('#stock-credentials').onsubmit=async e=>{
      e.preventDefault();if(credentialBusy)return;
      const provider=store.settings.provider,form=e.currentTarget;
      if(!form.reportValidity())return;
      credentialBusy=true;form.querySelector('fieldset').disabled=true;
      // Secrets exist only in the password inputs and this transient IPC argument.
      let args=provider==='toss'?{provider,clientId:form.querySelector('#stock-client-id').value.trim(),clientSecret:form.querySelector('#stock-client-secret').value.trim()}:{provider,apiKey:form.querySelector('#stock-api-key').value.trim()};
      form.querySelectorAll('input').forEach(input=>input.value='');
      try{store.credentials=await store.invoke('save_stock_credentials',args);credentialMessage='Keys saved';credentialError=false;store.invalidate();await store.emit('stock-credentials',{});void store.tick();}catch(_){credentialMessage='Could not save credentials. Inputs have been cleared.';credentialError=true;}finally{args=null;credentialBusy=false;lastMarkup='';render();}
    };
    element.querySelector('#stock-remove-keys').onclick=async()=>{if(credentialBusy)return;const provider=store.settings.provider;credentialBusy=true;render();try{store.credentials=await store.invoke('delete_stock_credentials',{provider});credentialMessage='Keys removed';credentialError=false;store.invalidate();await store.emit('stock-credentials',{});}catch(_){credentialMessage='Could not remove credentials.';credentialError=true;}finally{credentialBusy=false;lastMarkup='';render();}};
    const snapshot=element.querySelector('#stock-snapshot');if(snapshot)snapshot.onclick=async()=>{
      if(snapshotBusy)return;snapshotBusy=true;snapshotMessage='';snapshotError=false;pendingSnapshot=String(Date.now());renderPortfolio();
      const failed=()=>{snapshotBusy=false;snapshotMessage='Stock recording service did not respond. Open the notch and try again.';snapshotError=true;renderPortfolio();};
      snapshotTimer=setTimeout(failed,10000);
      try{await store.emit('stock-history-action',{action:'snapshot',requestID:pendingSnapshot});}catch(_){clearTimeout(snapshotTimer);failed();}
    };
    const refresh=element.querySelector('#stock-refresh-holdings');if(refresh)refresh.onclick=async()=>{refresh.disabled=true;try{await store.tick();}finally{refresh.disabled=false;}};
  }
  function renderPortfolio(){
    const host=element.querySelector('#stock-holdings');if(!host)return;const restoreDisclosures=rememberDisclosures(host);
    host.innerHTML=store.forecastError?`<p>${tr(store.forecastError)}</p>`:'';
    const accountMessage=element.querySelector('#stock-account-message');if(accountMessage)accountMessage.textContent=t(language(),store.accountError);
    for(const h of store.forecastStocks){const record=store.candidates.find(r=>r.stockID===stockID(h));host.innerHTML+=`<details data-stock-disclosure="current:${esc(stockID(h))}"><summary>${esc(h.name)} · ${esc(stockID(h))}</summary>${record?forecastHTML(record,record,language())+evidenceHTML(record,language(),'current-evidence:'+groupID(record)):`<p>${tr(store.reasons.get(stockID(h))||'No recent trade price is available.')}</p>`}</details>`;}
    restoreDisclosures();
    const b=element.querySelector('#stock-snapshot');if(b)b.disabled=snapshotBusy||!store.active()||!store.candidates.length||!!store.historyError;
    const messageHost=element.querySelector('#stock-snapshot-status');if(messageHost){messageHost.textContent=t(language(),snapshotMessage);messageHost.classList.toggle('stock-error',snapshotError);}
  }
  let historyRenderSignature='';
  function renderHistory() {
    const host=element.querySelector('#stock-history');if(!host)return;
    const h=store.history;
    const signature=JSON.stringify([language(),historyFilter,h?.trends.length,h?.forecasts.map(r=>r.actualClose),store.historyError,store.reconciliationError]);
    if(host.dataset.rendered==='true'&&signature===historyRenderSignature)return;
    const restoreDisclosures=rememberDisclosures(host);
    historyRenderSignature=signature;host.dataset.rendered='true';
    if(store.historyError){host.innerHTML=`<p class="stock-error" role="alert">${tr(store.historyError)}</p>`;return;}
    if(!h){host.textContent='…';return;}
    const all=[...h.forecasts,...h.trends],days=[...new Set(all.map(r=>dayKey(r.sessionStart,r.market)))].sort().reverse(),models=[...new Set(all.map(r=>r.model))],stocks=[...new Map(all.map(r=>[r.stockID,r.name])).entries()].sort(([a],[b])=>a.localeCompare(b));
    const option=(v,label,selected)=>`<option value="${esc(v)}" ${v===selected?'selected':''}>${esc(label)}</option>`;
    const select=(key,label,values)=>`<label>${tr(label)} <select data-history-filter="${key}" aria-label="${tr(label)}">${option('',t(language(),'All'),historyFilter[key])}${values.map(([value,name])=>option(value,name,historyFilter[key])).join('')}</select></label>`;
    host.innerHTML=`<div class="stock-actions">${select('stockID','Stock',stocks.map(([id,name])=>[id,`${name} · ${id}`]))}${select('day','Target day',days.map(d=>[d,d]))}${select('model','Model',models.map(m=>[m,m]))}${select('capture','Capture',[['manual',t(language(),'Manual')],['scheduled',t(language(),'Scheduled')]])}</div>`;
    const {records,traces,cohort}=filterHistory(h,historyFilter),groups=new Map();
    // Separate capture, model, currency and target day. Never pool daily traces into scores.
    for(const r of records){const key=[dayKey(r.sessionStart,r.market),r.model,r.capture,r.currency].join(' · ');if(!groups.has(key))groups.set(key,[]);groups.get(key).push(r);}
    host.innerHTML+=`<h3>${tr('Saved forecasts')} (${records.length})</h3>`;
    if(!records.length)host.innerHTML+=`<p>${tr('No saved forecasts.')}</p>`;
    const decimal=v=>v===null?'—':v.toFixed(3),percentage=v=>v===null?'—':(v*100).toFixed(1)+'%';
    for(const [key,rows] of groups){const sc=score(rows);host.innerHTML+=`<details data-stock-disclosure="history:${esc(key)}"><summary>${esc(key)} · ${sc.evaluated}/${sc.total} ${tr('Evaluated')}</summary><dl class="stock-metrics"><dt>${tr('Direction accuracy')} (${sc.directionCount})</dt><dd>${percentage(sc.accuracy)}</dd><dt>${tr('MAE')}</dt><dd>${decimal(sc.mae)}</dd><dt>${tr('MAPE')}</dt><dd>${decimal(sc.mape)}%</dd><dt>${tr('Price-hold baseline MAPE')}</dt><dd>${decimal(sc.baseline)}%</dd><dt>${tr('80% range coverage')}</dt><dd>${percentage(sc.range)}</dd><dt>${tr('Brier score')}</dt><dd>${decimal(sc.brier)}</dd></dl>${rows.map(r=>`<details data-stock-disclosure="record:${esc(forecastID(r))}"><summary>${esc(r.name||r.stockID)} · ${esc(dateText(r.createdAt,r.market,language()))}: ${priceText(r.expectedClose,r.currency,language())} → ${r.actualClose===null?tr('Pending'):priceText(r.actualClose,r.currency,language())}</summary>${forecastHTML(r,r,language())}${evidenceHTML(r,language(),'saved-evidence:'+forecastID(r))}</details>`).join('')}</details>`;}
    host.innerHTML+=comparisonHTML(cohort,language())+probabilityHTML(records,language());
    const traceGroups=new Map();for(const r of traces){const key=groupID(r);if(!traceGroups.has(key))traceGroups.set(key,[]);traceGroups.get(key).push(r);}
    host.innerHTML+=`<h3>${tr('Observed minute traces')} (${traces.length})</h3>`;
    if(historyFilter.capture)host.innerHTML+=`<p class="stock-small">${tr('Minute traces have no capture mode; the capture filter applies to saved forecasts only.')}</p>`;
    if(!traces.length)host.innerHTML+=`<p>${tr('No observed samples. Past values are not reconstructed.')}</p>`;
    for(const points of traceGroups.values()){points.sort((a,b)=>a.createdAt-b.createdAt);const r=points[0];host.innerHTML+=`<details data-stock-disclosure="trace:${esc(groupID(r))}"><summary>${esc(r.name||r.stockID)} · ${dayKey(r.sessionStart,r.market)} · ${esc(r.model)} (${points.length})</summary>${traceSVG(points,r.market,language())}</details>`;}
    if(store.reconciliationError)host.innerHTML+=`<p class="stock-error">${tr(store.reconciliationError)}</p>`;
    host.innerHTML+=`<div class="stock-actions"><button id="stock-export-forecasts">${tr('Export forecast CSV')}</button><button id="stock-export-traces">${tr('Export trace CSV')}</button><button id="stock-history-refresh">${tr('Refresh')}</button></div>`;
    restoreDisclosures();
    host.querySelectorAll('[data-history-filter]').forEach(e=>e.onchange=()=>{historyFilter[e.dataset.historyFilter]=e.value;renderHistory();});
    host.querySelector('#stock-export-forecasts').onclick=()=>downloadCSV(records,false);host.querySelector('#stock-export-traces').onclick=()=>downloadCSV(traces,true);host.querySelector('#stock-history-refresh').onclick=()=>store.loadHistory();
    host.querySelector('#stock-export-comparison').onclick=()=>downloadCSV(cohort,false);
  }
  store.listen?.('stock-history-updated',e=>{if(e.payload?.requestID&&e.payload.requestID===pendingSnapshot){clearTimeout(snapshotTimer);snapshotBusy=false;snapshotMessage=e.payload.error||(+e.payload.count>0?'Snapshots saved':'No new snapshots: already saved or no fresh estimate.');snapshotError=!!e.payload.error;renderPortfolio();}}).then(f=>store.unlisten.push(f)).catch(()=>{});
  fetch('krx-listed-companies.tsv').then(r=>{if(!r.ok)throw Error();return r.text();}).then(text=>{directory=parseDirectory(text);search();}).catch(()=>{message='KRX lookup unavailable; codes and US tickers still work.';status();});
  store.unlisten.push(bindStockDrag(element,store));
  render();
  return {render,show(visible){store.visible=visible;void store.emit('stock-view-state',{visible}).catch(()=>{});if(visible){if(store.historyDirty){store.historyDirty=false;void store.loadHistory();}render();requestAnimationFrame(()=>element.querySelector('#stock-symbol')?.focus());void store.tick();}}};
}
const api={DEFAULTS,TTL,MODEL,TREND_KEYS,FORECAST_KEYS,parseStock,stockID,normalizeSettings,dayKey,timestamp,decodeQuotes,decodeFinnhub,dailyCloses,previousClose,quoteContext,changeRate,decodeCandles,validBars,movingAverage,tenMinuteBars,completedBars,regularSession,dailyVariance,estimate,chartEstimate,technical,validTrend,validForecast,validateHistory,appendSamples,saveSnapshots,groupID,trendID,forecastID,score,compareModels,probabilityBins,filterHistory,csv,Store,t,esc,priceText,dateText,cells,candleSVG,traceSVG,forecastHTML,rememberDisclosures,evidenceHTML,comparisonHTML,probabilityHTML,cardHTML,bindCard,moveStock,reorderStocks,dragStarted,bindStockDrag,parseDirectory,findCompanies,mountSettings};
if(typeof module!=='undefined'&&module.exports)module.exports=api;
else root.PenguinNotchStocks=api;
})(typeof globalThis!=='undefined'?globalThis:this);
