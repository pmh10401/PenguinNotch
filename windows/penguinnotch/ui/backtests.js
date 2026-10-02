/* Public adjusted replay inputs; no transport, account access or archive writes. */
(function(root){
'use strict';
const S=typeof module!=='undefined'&&module.exports?require('./stocks.js'):root.PenguinNotchStocks;
const PRICE_BASIS='provider-adjusted-as-fetched';
const keys=(o,names)=>o!==null&&typeof o==='object'&&!Array.isArray(o)&&Object.keys(o).length===names.length&&names.every(k=>Object.hasOwn(o,k));
const positive=n=>typeof n==='number'&&Number.isFinite(n)&&n>0;
const time=n=>Number.isSafeInteger(n)&&n>=0&&n<=253402300799000;
const cursor=s=>typeof s==='string'&&/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(s)&&Number.isFinite(Date.parse(s));
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
const api={PRICE_BASIS,validInput,validCase,predictReplay};
if(typeof module!=='undefined'&&module.exports)module.exports=api;
root.PenguinNotchBacktests=api;
})(globalThis);
