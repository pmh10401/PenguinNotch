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
  if(!i.minutes.every((b,n)=>keys(b,BAR_FIELDS)&&time(b.end)&&b.end-60000>=i.sessionStart&&b.end<=i.cutoff&&(!n||i.minutes[n-1].end<b.end))||!S.validBars(i.minutes))return false;
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
    &&m.cases.every(e=>validEntry(e)&&m.symbols.includes(e.stockID)&&(m.status!=='completed'||e.status!=='pending'))
    &&['kr','us'].every(market=>new Set(m.cases.filter(e=>S.parseStock(e.stockID).market===market).map(e=>e.tradingDay)).size<=m.sessions);
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
// Key-only scan; JSON.parse below remains the grammar/value parser, never a repair step.
function rejectDuplicateKeys(body){
  const stack=[];
  for(let i=0;i<body.length;){
    const c=body[i];
    if(c==='{'||c==='['){if(stack.length>=512)throw Error('Invalid replay JSON depth');stack.push({opening:c,keys:new Set()});i++;}
    else if(c==='}'||c===']'){if(stack.pop()?.opening!==(c==='}'?'{':'['))throw Error('Invalid replay JSON');i++;}
    else if(c==='"'){
      const start=i++;
      while(i<body.length&&body[i]!=='"')i+=body[i]==='\\'?2:1;
      if(i>=body.length)throw Error('Invalid replay JSON');i++;
      let next=i;while(next<body.length&&/[\t\n\r ]/.test(body[next]))next++;
      if(body[next]===':'){
        const frame=stack.at(-1);if(frame?.opening!=='{')throw Error('Invalid replay JSON');
        const key=JSON.parse(body.slice(start,i));if(frame.keys.has(key))throw Error('Duplicate replay JSON key');frame.keys.add(key);
      }
    }else i++;
  }
  if(stack.length)throw Error('Invalid replay JSON');
}
function parsedBody(body,validator){
  if(typeof body!=='string'||utf8Size(body)>2*1024*1024)throw Error('Invalid replay body');
  rejectDuplicateKeys(body);
  const value=JSON.parse(body);if(!validator(value))throw Error('Invalid replay body');return value;
}
async function archive(action,payload={},invoke=root.__TAURI__?.core?.invoke){
  const fields={list:[],create:['manifest'],loadManifest:['runID'],saveCase:['runID','body'],loadCase:['runID','caseID'],
    saveResult:['runID','body'],loadResult:['runID','caseID'],updateProgress:['runID','entries','status']}[action];
  if(!fields||!keys(payload,fields)||Object.hasOwn(payload,'runID')&&!uuid(payload.runID)||Object.hasOwn(payload,'caseID')&&!safeCaseID(payload.caseID))throw Error('Invalid replay archive request');
  if(action==='create'&&!validManifest(payload.manifest))throw Error('Invalid replay manifest');
  if(action==='saveCase')parsedBody(payload.body,validCase);
  if(action==='saveResult')parsedBody(payload.body,validResult);
  if(action==='updateProgress'&&(!Array.isArray(payload.entries)||payload.entries.length>3600||!payload.entries.every(validEntry)||!['ready','running','paused','completed'].includes(payload.status)))throw Error('Invalid replay progress');
  if(typeof invoke!=='function')throw Error('Native replay archive unavailable');
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
class CollectionSkip extends Error {}
const fail=reason=>{throw new CollectionSkip(reason);};
const iso=n=>new Date(n).toISOString();
const BAR_FIELDS=['end','open','high','low','close','volume'];
const sameBar=(a,b)=>BAR_FIELDS.every(key=>a[key]===b[key]);
function checkedBars(values,before){
  if(!Array.isArray(values)||values.length>200)fail('invalid_candle_page');
  let direction=0;
  for(let n=0;n<values.length;n++){
    const b=values[n];
    if(!keys(b,BAR_FIELDS)||!time(b.end)||b.end>Date.parse(before)||!S.validBars([b]))fail('invalid_candle_page');
    if(n){const d=Math.sign(b.end-values[n-1].end);if(d&&direction&&d!==direction)fail('invalid_candle_order');if(d)direction=d;}
  }
  return values;
}
function regular(day,market){
  const r=market==='kr'?day?.integrated?.regularMarket:day?.regularMarket;
  if(!r)return null;
  if(!cursor(r.startTime)||!cursor(r.endTime))throw Error('Invalid calendar session');
  const start=Date.parse(r.startTime),end=Date.parse(r.endTime);
  if(!time(start)||!time(end)||end-start<=3600000||S.dayKey(start,market)!==S.dayKey(end-1,market))throw Error('Invalid calendar session');
  return {start,end};
}
// Native transport owns the shared credentials/token/retry bounds. Bypass the live display gate.
async function publicRequest(invoke,request){
  const native=request.type==='calendar'?{kind:'calendar',market:request.market,date:request.date}
    :{kind:'candles',symbol:request.stock.symbol,market:request.stock.market,interval:request.interval,before:request.before,count:request.count,adjusted:request.adjusted};
  const reply=await invoke('stock_request',{request:native});
  if(!time(reply?.fetchedAt))throw Error('Invalid public reply');
  if(request.type==='calendar')return {type:'calendar',value:reply.data?.result,requestedAt:reply.fetchedAt};
  const result=reply.data?.result;
  if(!Array.isArray(result?.candles)||!(result.nextBefore===null||cursor(result.nextBefore)))fail('invalid_candle_page');
  // Reuse the existing numeric/OHLC codec one row at a time to retain inclusive duplicates.
  const values=result.candles.map(row=>{
    if(!cursor(row?.timestamp))fail('invalid_candle_timestamp');
    try{return S.decodeCandles({result:{candles:[row]}},request.stock.market)[0];}catch(_){fail('invalid_candle_page');}
  });
  return {type:'candles',values,nextBefore:result.nextBefore,requestedAt:reply.fetchedAt};
}
class BacktestStore {
  constructor({invoke=root.__TAURI__?.core?.invoke,stockRequest,now=Date.now,sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms))}={}){
    this.invoke=invoke;this.stockRequest=stockRequest||((r)=>publicRequest(this.invoke,r));this.now=now;this.sleep=sleep;
    this.runs=[];this.activeRunID=null;this.progress={completed:0,total:0};this.errorMessage=null;
    this.listeners=new Set();this.generation=0;this.revision=0;this.provider='toss';this.busy=false;this.lastRequestAt=null;
    const generation=this.generation;
    this.ready=archive('list',{},this.invoke).then(r=>{if(this.generation===generation&&!this.busy){this.runs=r.manifests;this.emit();}})
      .catch(()=>{if(this.generation===generation&&!this.busy){this.errorMessage='archive_unavailable';this.emit();}});
  }
  subscribe(listener){this.listeners.add(listener);listener(this);return ()=>this.listeners.delete(listener);}
  emit(){for(const listener of this.listeners){try{listener(this);}catch(_){/* A consumer must not interrupt archive cleanup. */}}}
  cancel(){this.generation++;this.emit();}
  // Task6 calls this before applying provider/key revisions; watchlist/display edits do not change frozen symbols.
  configure({provider=this.provider,revision=this.revision}={}){
    if(provider!==this.provider||revision!==this.revision)this.cancel();
    this.provider=provider;this.revision=revision;
  }
  check(generation,revision){if(generation!==this.generation||revision!==this.revision||this.provider!=='toss')throw Error('collection_cancelled');}
  async request(request,generation,revision){
    this.check(generation,revision);
    if(this.lastRequestAt!==null){const wait=250-(this.now()-this.lastRequestAt);if(wait>0)await this.sleep(wait);}
    this.check(generation,revision);this.lastRequestAt=this.now();
    const reply=await this.stockRequest(request);this.check(generation,revision);
    if(reply?.type!==request.type||!time(reply.requestedAt)||reply.requestedAt>this.now())throw Error('Invalid public reply');
    return reply;
  }
  publish(m){const index=this.runs.findIndex(r=>r.runID===m.runID);if(index<0)this.runs.push(m);else this.runs[index]=m;
    this.progress={completed:m.cases.filter(e=>e.status!=='pending').length,total:m.cases.length};this.emit();}
  async start({symbols,sessions=60}){
    if(this.busy)throw Error('collection_already_running');
    const stocks=Array.isArray(symbols)?symbols.map(s=>S.parseStock(typeof s==='string'?s:S.stockID(s))):[];
    if(![20,60,120].includes(sessions)||!stocks.length||stocks.length>30||stocks.some(s=>!s||s.symbol.includes('..'))||!unique(stocks.map(S.stockID)))throw Error('Invalid collection inputs');
    if(this.provider!=='toss')throw Error('Toss provider required');
    this.busy=true;const generation=++this.generation,revision=this.revision,started=this.now();this.errorMessage=null;
    const runID=root.crypto.randomUUID();this.activeRunID=runID;this.progress={completed:0,total:stocks.length*sessions};this.emit();
    let m=null;
    try{
      const calendars=new Map(),dates=new Map();
      for(const market of [...new Set(stocks.map(s=>s.market))]){
        let date=S.dayKey(started,market);const days=[];
        for(let n=0;days.length<sessions&&n<sessions+1;n++){
          const reply=await this.request({type:'calendar',market,date},generation,revision),r=regular(reply.value?.today,market);
          if(r&&S.dayKey(r.start,market)!==date)throw Error('Calendar date mismatch');
          const previous=regular(reply.value?.previousBusinessDay,market);
          if(!previous||previous.end>started||S.dayKey(previous.start,market)>=date)throw Error('Invalid previous business day');
          if(r&&r.end<=started){days.push(date);calendars.set(market+'|'+date,{session:r,previousDay:S.dayKey(previous.start,market),requestedAt:reply.requestedAt});}
          if(days.length===sessions)break;
          date=S.dayKey(previous.start,market);
        }
        if(days.length!==sessions)throw Error('Incomplete calendar');dates.set(market,days);
      }
      this.check(generation,revision);
      m={version:1,runID,createdAt:started,collectionStartedAt:started,collectionCompletedAt:null,
        protocolVersion:'replay-v1',codeVersion:'1.25.0/r58',priceBasis:PRICE_BASIS,cutoffMinutes:60,sessions,
        symbols:stocks.map(S.stockID),models:[...MODELS],status:'ready',cases:stocks.flatMap(stock=>dates.get(stock.market).map(tradingDay=>({
          caseID:`${stock.market}_${stock.symbol}_${tradingDay}`,stockID:S.stockID(stock),tradingDay,status:'pending',inputSHA256:null,resultSHA256:null,reason:null}))) };
      await archive('create',{manifest:m},this.invoke);this.check(generation,revision);this.publish(m);
      await this.collect(m,calendars,generation,revision);
    }catch(error){this.errorMessage=String(error?.message??error)==='collection_cancelled'?'collection_cancelled':/401|403|credential/i.test(String(error?.message??error))?'authentication_paused':'collection_failed';
      if(m)await this.pause(m);throw error;
    }finally{this.activeRunID=null;this.busy=false;this.emit();}
  }
  async resume(runID){
    if(this.busy)throw Error('collection_already_running');if(!uuid(runID))throw Error('Invalid run ID');
    this.busy=true;const generation=++this.generation,revision=this.revision;this.errorMessage=null;this.activeRunID=runID;this.progress={completed:0,total:0};this.emit();let m=null;
    try{
      m=(await archive('loadManifest',{runID},this.invoke)).manifest;this.check(generation,revision);this.publish(m);
      if(m.status==='completed')return;
      await this.collect(m,new Map(),generation,revision,true);
    }catch(error){this.errorMessage=String(error?.message??error)==='collection_cancelled'?'collection_cancelled':/401|403|credential/i.test(String(error?.message??error))?'authentication_paused':'collection_failed';if(m)await this.pause(m);throw error;
    }finally{this.activeRunID=null;this.busy=false;this.emit();}
  }
  async pause(m){
    if(m.status==='completed')return;
    // A save already in flight can leave valid orphan bytes. Native resume reuses them without requests.
    try{await archive('updateProgress',{runID:m.runID,entries:m.cases,status:'paused'},this.invoke);m.status='paused';this.publish(m);}catch(_){this.errorMessage='archive_unavailable';}
  }
  async collect(m,calendars,generation,revision,recover=false){
    await archive('updateProgress',{runID:m.runID,entries:m.cases,status:'running'},this.invoke);this.check(generation,revision);m.status='running';this.publish(m);
    const existing=new Map();
    // Audit/load all existing cases and freeze every missing session before collection on resume.
    for(let n=0;recover&&n<m.cases.length;n++){
      const e=m.cases[n];this.check(generation,revision);if(e.status!=='pending')continue;
      let saved=null;
      try{saved=await archive('loadCase',{runID:m.runID,caseID:e.caseID},this.invoke);}catch(error){
        if(String(error?.message??error)!=='Invalid replay archive')throw error;
        // Native loadCase currently uses its strict archive error for absent uncommitted bodies.
        const audit=(await archive('loadManifest',{runID:m.runID},this.invoke)).manifest;
        if(audit.cases[n].status!=='pending'||audit.cases[n].inputSHA256!==null)throw error;
      }
      this.check(generation,revision);if(saved)existing.set(e.caseID,saved);
    }
    for(const e of m.cases){
      if(e.status!=='pending'||existing.has(e.caseID))continue;
      const stock=S.parseStock(e.stockID),key=stock.market+'|'+e.tradingDay;
      if(!calendars.has(key)){
        const reply=await this.request({type:'calendar',market:stock.market,date:e.tradingDay},generation,revision),session=regular(reply.value?.today,stock.market);
        if(!session||S.dayKey(session.start,stock.market)!==e.tradingDay||session.end>m.collectionStartedAt)throw Error('Calendar date mismatch');
        const previous=regular(reply.value?.previousBusinessDay,stock.market);
        if(!previous||previous.end>=session.start||S.dayKey(previous.start,stock.market)>=e.tradingDay)throw Error('Invalid previous business day');
        calendars.set(key,{session,previousDay:S.dayKey(previous.start,stock.market),requestedAt:reply.requestedAt});
      }
    }
    for(let n=0;n<m.cases.length;n++){
      const e=m.cases[n];this.check(generation,revision);if(e.status!=='pending')continue;
      const saved=existing.get(e.caseID);
      if(saved)m.cases[n]={...e,status:'saved',inputSHA256:saved.sha256};
      else{
        const stock=S.parseStock(e.stockID),key=stock.market+'|'+e.tradingDay;
        try{
          const c=await this.collectCase(stock,e,calendars.get(key),generation,revision);this.check(generation,revision);
          const receipt=await archive('saveCase',{runID:m.runID,body:JSON.stringify(c)},this.invoke);this.check(generation,revision);
          m.cases[n]={...e,status:'saved',inputSHA256:receipt.sha256};
        }catch(error){if(!(error instanceof CollectionSkip))throw error;this.check(generation,revision);m.cases[n]={...e,status:'skipped',reason:error.message};}
      }
      this.check(generation,revision);await archive('updateProgress',{runID:m.runID,entries:m.cases,status:'running'},this.invoke);this.check(generation,revision);this.publish(m);
    }
    this.check(generation,revision);await archive('updateProgress',{runID:m.runID,entries:m.cases,status:'completed'},this.invoke);Object.assign(m,(await archive('loadManifest',{runID:m.runID},this.invoke)).manifest);this.check(generation,revision);this.publish(m);
  }
  async collectCase(stock,e,calendar,generation,revision){
    const {start,end}=calendar.session,cutoff=end-3600000;
    const daily=await this.request({type:'candles',stock,interval:'1d',before:iso(end),count:200,adjusted:true},generation,revision);
    checkedBars(daily.values,iso(end));
    if(!(daily.nextBefore===null||cursor(daily.nextBefore)))fail('invalid_cursor');
    if(daily.nextBefore!==null&&(!daily.values.length||Date.parse(daily.nextBefore)>=end||Date.parse(daily.nextBefore)>Math.min(...daily.values.map(b=>b.end))))fail('repeated_cursor');
    const days=new Map();
    for(const b of daily.values){const day=S.dayKey(b.end,stock.market),old=days.get(day);
      if(old&&!sameBar(old,b))fail('conflicting_duplicate');days.set(day,b);}
    const target=days.get(e.tradingDay),closes=[...days].filter(([d])=>d<e.tradingDay).sort(([a],[b])=>b.localeCompare(a)).slice(0,61).map(([,b])=>({date:b.end,price:b.close}));
    if(!target)fail('session_target_mismatch');if(!closes.length||S.dayKey(closes[0].date,stock.market)!==calendar.previousDay)fail('missing_previous_close');
    let raw=0;const pages=[],all=new Map();
    const page=async(before,seen)=>{
      if(pages.length>=8||raw>1200)fail('collection_bounds');
      const reply=await this.request({type:'candles',stock,interval:'1m',before,count:200,adjusted:true},generation,revision);
      const bars=checkedBars(reply.values,before);raw+=bars.length;if(raw>1400)fail('collection_bounds');
      if(!(reply.nextBefore===null||cursor(reply.nextBefore)))fail('invalid_cursor');
      if(reply.nextBefore!==null){const next=Date.parse(reply.nextBefore);
        if(next>=Date.parse(before)||seen.has(next)||!bars.length||next>Math.min(...bars.map(b=>b.end)))fail('repeated_cursor');seen.add(next);}
      pages.push({before,nextBefore:reply.nextBefore,fetchedAt:reply.requestedAt});
      for(const b of bars){const old=all.get(b.end);if(old&&!sameBar(old,b))fail('conflicting_duplicate');all.set(b.end,b);}
      return reply;
    };
    const proofReply=await page(iso(end),new Set([end])),proof=all.get(end);
    if(!proof||Math.abs(proof.close-target.close)>target.close*1e-8)fail('session_target_mismatch');
    const inputs=new Map(),seen=new Set([cutoff]);let before=iso(cutoff);
    while(pages.length<8&&raw<=1200){
      const reply=await page(before,seen);
      for(const b of reply.values)if(b.end-60000>=start&&b.end<=cutoff)inputs.set(b.end,b);
      if(reply.values.some(b=>b.end<=start+60000)||reply.nextBefore===null)break;
      before=reply.nextBefore;
    }
    const minutes=[...inputs.values()].sort((a,b)=>a.end-b.end),last=minutes.at(-1);
    if(!last||cutoff-last.end>120000)fail('missing_cutoff_input');
    const c={version:1,input:{version:1,caseID:e.caseID,stockID:e.stockID,market:stock.market,currency:stock.market==='kr'?'KRW':'USD',tradingDay:e.tradingDay,
      sessionStart:start,sessionEnd:end,cutoff,inputBarEnd:last.end,inputPrice:last.close,previousClose:closes[0].price,priceBasis:PRICE_BASIS,dailyCloses:closes,minutes},
      target:{actualClose:target.close,candleAt:target.end,fetchedAt:daily.requestedAt},source:{provider:'toss',calendarFetchedAt:calendar.requestedAt,dailyFetchedAt:daily.requestedAt,minutePages:pages}};
    if(daily.requestedAt<end||proofReply.requestedAt<end||!validCase(c))fail('invalid_collected_case');return c;
  }
}
const api={PRICE_BASIS,validInput,validCase,predictReplay,validManifest,validResult,archive,BacktestStore};
if(typeof module!=='undefined'&&module.exports)module.exports=api;
root.PenguinNotchBacktests=api;
})(globalThis);
