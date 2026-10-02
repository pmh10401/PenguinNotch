/* Public adjusted replay inputs and dedicated native archive IPC. */
(function(root){
'use strict';
const S=typeof module!=='undefined'&&module.exports?require('./stocks.js'):root.PenguinNotchStocks;
const PRICE_BASIS='provider-adjusted-as-fetched';
const keys=(o,names)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===names.length&&names.every(k=>Object.hasOwn(o,k));
const positive=n=>typeof n==='number'&&Number.isFinite(n)&&n>0;
const time=n=>Number.isSafeInteger(n)&&n>=0&&n<=253402300799000;
const cursor=s=>typeof s==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(s)&&Number.isFinite(Date.parse(s))&&new Date(s.slice(0,19)+'Z').toISOString().slice(0,19)===s.slice(0,19);
function validInput(i){
  if(!keys(i,['version','caseID','stockID','market','currency','tradingDay','sessionStart','sessionEnd','cutoff','inputBarEnd','inputPrice','previousClose','priceBasis','dailyCloses','minutes']))return false;
  const stock=S.parseStock(i.stockID);
  if(i.version!==1||!stock||S.stockID(stock)!==i.stockID||stock.market!==i.market||stock.symbol.includes('..')||i.currency!==(i.market==='kr'?'KRW':'USD')||i.caseID!==`${i.market}_${stock.symbol}_${i.tradingDay}`||i.priceBasis!==PRICE_BASIS)return false;
  if(![i.sessionStart,i.sessionEnd,i.cutoff,i.inputBarEnd].every(time)||i.sessionEnd-i.sessionStart<=3600000||i.cutoff!==i.sessionEnd-3600000||i.inputBarEnd>i.cutoff||i.cutoff-i.inputBarEnd>120000||!positive(i.inputPrice)||!positive(i.previousClose))return false;
  if(i.tradingDay!==S.dayKey(i.sessionStart,i.market)||S.dayKey(i.sessionEnd-1,i.market)!==i.tradingDay)return false;
  if(!Array.isArray(i.dailyCloses)||i.dailyCloses.length>61||!Array.isArray(i.minutes)||i.minutes.length>1400||!i.minutes.length)return false;
  if(!i.dailyCloses.every((c,n)=>keys(c,['date','price'])&&time(c.date)&&positive(c.price)&&S.dayKey(c.date,i.market)<i.tradingDay&&(!n||S.dayKey(i.dailyCloses[n-1].date,i.market)>S.dayKey(c.date,i.market))))return false;
  if(i.dailyCloses.length&&i.dailyCloses[0].price!==i.previousClose)return false;
  if(!i.minutes.every((b,n)=>keys(b,['end','open','high','low','close','volume'])&&time(b.end)&&b.end-60000>=i.sessionStart&&b.end<=i.cutoff&&(!n||i.minutes[n-1].end<b.end))||!S.validBars(i.minutes))return false;
  const last=i.minutes.at(-1);
  return last.end===i.inputBarEnd&&last.close===i.inputPrice;
}
function validCase(c){
  if(!keys(c,['version','input','target','source'])||c.version!==1||!validInput(c.input))return false;
  const t=c.target,s=c.source;
  return keys(t,['actualClose','candleAt','fetchedAt'])&&positive(t.actualClose)&&time(t.candleAt)&&time(t.fetchedAt)&&t.fetchedAt>=c.input.sessionEnd&&S.dayKey(t.candleAt,c.input.market)===c.input.tradingDay
    &&keys(s,['provider','calendarFetchedAt','dailyFetchedAt','minutePages'])&&s.provider==='toss'&&time(s.calendarFetchedAt)&&time(s.dailyFetchedAt)&&Array.isArray(s.minutePages)&&s.minutePages.length<=8
    &&s.minutePages.every(p=>keys(p,['before','nextBefore','fetchedAt'])&&cursor(p.before)&&(p.nextBefore===null||cursor(p.nextBefore))&&time(p.fetchedAt));
}
function predictReplay(input,interval){
  if(!['1m','10m','1d'].includes(interval))throw Error('Invalid replay interval');
  const model=`GBM ${interval==='1d'?'daily':interval} zero drift v1 / replay v1`;
  if(!validInput(input))return {model,status:'skipped',reason:'invalid_input',forecast:null};
  const trading={start:input.sessionStart,end:input.sessionEnd};
  const forecast=interval==='1d'?(input.dailyCloses.length===61?S.estimate(input.inputPrice,input.dailyCloses.map(c=>c.price),trading,input.cutoff):null)
    :S.intradayEstimate(input.inputPrice,input.previousClose,input.minutes,trading,input.cutoff,interval);
  return {model,status:forecast?'forecast':'skipped',reason:forecast?null:interval==='1d'?'insufficient_daily_history':'insufficient_intraday_history',forecast};
}

const MODELS=['GBM daily zero drift v1 / replay v1','GBM 1m zero drift v1 / replay v1','GBM 10m zero drift v1 / replay v1'];
const uuid=s=>typeof s==='string'&&/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(s);
const digest=s=>typeof s==='string'&&/^[0-9a-f]{64}$/.test(s);
const unique=a=>new Set(a).size===a.length;
function safeCaseID(id){
  if(typeof id!=='string'||id.includes('..'))return false;
  const m=/^(us_[A-Z][A-Z0-9.\-]{0,9}|kr_[A-Z0-9]{6})_(\d{4}-\d{2}-\d{2})$/.exec(id);
  return !!m&&Number.isFinite(Date.parse(m[2]+'T00:00:00Z'))&&new Date(m[2]+'T00:00:00Z').toISOString().slice(0,10)===m[2];
}
function validEntry(e){
  if(!keys(e,['caseID','stockID','tradingDay','status','inputSHA256','resultSHA256','reason']))return false;
  const stock=S.parseStock(e.stockID);
  if(!stock||S.stockID(stock)!==e.stockID||!safeCaseID(e.caseID)||e.caseID!==`${stock.market}_${stock.symbol}_${e.tradingDay}`
    ||!(e.inputSHA256===null||digest(e.inputSHA256))||!(e.resultSHA256===null||digest(e.resultSHA256)))return false;
  if(e.status==='pending')return e.inputSHA256===null&&e.resultSHA256===null&&e.reason===null;
  if(e.status==='saved')return digest(e.inputSHA256)&&e.reason===null;
  return e.status==='skipped'&&e.inputSHA256===null&&e.resultSHA256===null&&typeof e.reason==='string'&&e.reason.length>0&&utf8Size(e.reason)<=256;
}
function validManifest(m){
  return keys(m,['version','runID','createdAt','collectionStartedAt','collectionCompletedAt','protocolVersion','codeVersion','priceBasis','cutoffMinutes','sessions','symbols','models','status','cases'])
    &&m.version===1&&uuid(m.runID)&&time(m.createdAt)&&time(m.collectionStartedAt)&&m.createdAt<=m.collectionStartedAt
    &&(m.collectionCompletedAt===null||time(m.collectionCompletedAt)&&m.collectionCompletedAt>=m.collectionStartedAt)
    &&m.protocolVersion==='replay-v1'&&typeof m.codeVersion==='string'&&m.codeVersion.length>0&&utf8Size(m.codeVersion)<=128
    &&m.priceBasis===PRICE_BASIS&&m.cutoffMinutes===60&&[20,60,120].includes(m.sessions)
    &&Array.isArray(m.symbols)&&m.symbols.length>0&&m.symbols.length<=30&&unique(m.symbols)
    &&m.symbols.every(id=>S.parseStock(id)&&S.stockID(S.parseStock(id))===id&&!id.includes('..'))
    &&Array.isArray(m.models)&&m.models.length>0&&unique(m.models)&&m.models.every(model=>MODELS.includes(model))
    &&['ready','running','paused','completed'].includes(m.status)&&(m.status==='completed')===(m.collectionCompletedAt!==null)
    &&Array.isArray(m.cases)&&m.cases.length<=m.symbols.length*m.sessions&&unique(m.cases.map(e=>e?.caseID))
    &&new Set(m.cases.map(e=>e?.tradingDay)).size<=m.sessions&&m.cases.every(e=>validEntry(e)&&m.symbols.includes(e.stockID)&&(m.status!=='completed'||e.status!=='pending'));
}
function validResult(r){
  if(!keys(r,['version','caseID','inputSHA256','calculationVersion','computedAt','outcomes'])||r.version!==1||!safeCaseID(r.caseID)||!digest(r.inputSHA256)
    ||r.calculationVersion!=='replay-v1'||!time(r.computedAt)||!Array.isArray(r.outcomes)||!r.outcomes.length||r.outcomes.length>3||!unique(r.outcomes.map(o=>o?.model)))return false;
  return r.outcomes.every(o=>{
    if(!keys(o,['model','status','reason','forecast'])||!MODELS.includes(o.model))return false;
    if(o.status==='skipped')return o.forecast===null&&o.reason===(o.model.includes('daily')?'insufficient_daily_history':'insufficient_intraday_history');
    const f=o.forecast;
    return o.status==='forecast'&&o.reason===null&&keys(f,['expectedClose','lowerClose','upperClose','riseProbability','observations'])
      &&[f.expectedClose,f.lowerClose,f.upperClose].every(positive)&&f.lowerClose<=f.expectedClose&&f.expectedClose<=f.upperClose
      &&typeof f.riseProbability==='number'&&Number.isFinite(f.riseProbability)&&f.riseProbability>=0&&f.riseProbability<=1
      &&Number.isSafeInteger(f.observations)&&f.observations>=10&&f.observations<=1399&&(!o.model.includes('daily')||f.observations===60);
  });
}
function utf8Size(s){try{return encodeURIComponent(s).replace(/%[0-9A-F]{2}|[^%]/g,'x').length;}catch(_){return Infinity;}}
function parsedBody(body,validator){
  if(typeof body!=='string'||utf8Size(body)>2*1024*1024)throw Error('Invalid replay body');
  const value=JSON.parse(body);if(!validator(value))throw Error('Invalid replay body');return value;
}
async function archive(action,payload={}){
  const fields={list:[],create:['manifest'],loadManifest:['runID'],saveCase:['runID','body'],loadCase:['runID','caseID'],
    saveResult:['runID','body'],loadResult:['runID','caseID'],updateProgress:['runID','entries','status']}[action];
  if(!fields||!keys(payload,fields)||Object.hasOwn(payload,'runID')&&!uuid(payload.runID)||Object.hasOwn(payload,'caseID')&&!safeCaseID(payload.caseID))throw Error('Invalid replay archive request');
  if(action==='create'&&!validManifest(payload.manifest))throw Error('Invalid replay manifest');
  if(action==='saveCase')parsedBody(payload.body,validCase);
  if(action==='saveResult')parsedBody(payload.body,validResult);
  if(action==='updateProgress'&&(!Array.isArray(payload.entries)||payload.entries.length>3600||!payload.entries.every(validEntry)||!['ready','running','paused','completed'].includes(payload.status)))throw Error('Invalid replay progress');
  const invoke=root.__TAURI__?.core?.invoke;if(typeof invoke!=='function')throw Error('Native replay archive unavailable');
  const reply=await invoke('stock_backtest_archive',{request:{action,...payload}});
  let valid=false;
  if(action==='list')valid=keys(reply,['type','manifests'])&&reply.type==='manifests'&&Array.isArray(reply.manifests)&&reply.manifests.every(validManifest);
  else if(action==='loadManifest')valid=keys(reply,['type','manifest'])&&reply.type==='manifest'&&validManifest(reply.manifest)&&reply.manifest.runID.toLowerCase()===payload.runID.toLowerCase();
  else if(action==='saveCase'||action==='saveResult')valid=keys(reply,['type','sha256'])&&reply.type==='receipt'&&digest(reply.sha256);
  else if(action==='loadCase'||action==='loadResult'){
    valid=keys(reply,['type','body','sha256'])&&reply.type==='body';
    if(valid&&action==='loadResult'&&reply.body===null)valid=reply.sha256===null;
    else if(valid){const v=parsedBody(reply.body,action==='loadCase'?validCase:validResult);valid=digest(reply.sha256)&&(action==='loadCase'?v.input.caseID:v.caseID)===payload.caseID;}
  } else valid=keys(reply,['type'])&&reply.type==='empty';
  if(!valid)throw Error('Invalid replay archive reply');return reply;
}
const api={PRICE_BASIS,validInput,validCase,predictReplay,validManifest,validResult,archive};
if(typeof module!=='undefined'&&module.exports)module.exports=api;
root.PenguinNotchBacktests=api;
})(globalThis);
