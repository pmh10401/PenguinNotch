const {readFileSync} = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {test} = require('node:test');

// Exercise the page's actual lookup and formatters without a WebView or Tauri.
const html = readFileSync(path.join(__dirname, '../penguinnotch/ui/notch.html'), 'utf8');
const source = html.slice(html.indexOf("let uiLang='en';"), html.indexOf('function setUiLanguage'));
function card(lang) {
  return vm.runInNewContext(source + `; uiLang=${JSON.stringify(lang)}; ({textCopy, ui:ui()})`);
}

test('Korean card keeps numbers, plan names and unknown vendor messages', () => {
  const {textCopy, ui} = card('ko');
  assert.equal(textCopy('Current session'), '현재 세션');
  assert.equal(textCopy('Sign in'), '로그인');
  assert.equal(textCopy('Rate limited — retrying in 30s'), '요청 제한 — 30초 후 재시도');
  assert.equal(textCopy('5h limit'), '5시간 제한');
  assert.equal(textCopy('Unlimited on the Pro plan — nothing to meter'),
    'Pro 요금제는 무제한입니다 — 측정할 사용량이 없습니다');
  assert.equal(textCopy('Working in example-repo'), '작업 위치: example-repo');
  assert.equal(textCopy('New vendor message'), 'New vendor message');
  assert.equal(ui.locale, 'ko-KR');
  assert.equal(ui.usedLeft('0.6', '99.4'), '0.6% 사용 · 99.4% 남음');
  assert.equal(ui.resetsIn(51), '51분 후 재설정');
  assert.equal(ui.resetsAt('14:30'), '14:30에 재설정');
  assert.equal(ui.resetsOn('9월 28일', '14:30'), '9월 28일 14:30에 재설정');
  assert.equal(ui.ago(120), '2시간 전');
  assert.equal(ui.updated(ui.ago(20)), '20분 전에 마지막 업데이트됨');
  assert.equal(ui.andMore(3), '외 3개');
});

test('an unsupported card language still uses English', () => {
  const {textCopy, ui} = card('xx');
  assert.equal(textCopy('Current session'), 'Current session');
  assert.equal(ui.resetsIn(51), 'Resets in 51 min');
  assert.equal(ui.updated('20m ago'), 'Updated 20m ago');
});

test('hover text size is localized, saved independently, resettable and restored after IPC failure', async () => {
  const settings = readFileSync(path.join(__dirname, '../penguinnotch/ui/settings.html'), 'utf8');
  const korean = vm.runInNewContext(settings.slice(settings.indexOf('const KO_STATIC'), settings.indexOf('const UK_STATIC')) + '; KO_STATIC');
  assert.equal(korean['Hover text size'], '호버 글자 크기');
  assert.equal(korean['Reset hover text size to 100%'], '호버 글자 크기를 100%로 초기화');
  assert.match(settings, /<label for="hover-text-scale">Hover text size<\/label>/);
  const elements = new Map(), calls = [], errors = [];
  let fail = false;
  const get = id => {
    if (!elements.has(id)) elements.set(id, {addEventListener(name, fn){this[name] = fn;}});
    return elements.get(id);
  };
  const source = settings.slice(settings.indexOf('function normalizeHoverTextScale'), settings.indexOf('/* ---- Appearance: edge and screen'));
  const context = vm.createContext({document:{getElementById:get}, window:{__TAURI__:{event:{listen(){}}}},
    invoke:async(cmd,args)=>{calls.push([cmd,args.scale]); if(fail) throw Error('test failure'); return args.scale;},
    toast(){}, strip:message=>errors.push(message), errText:String});
  vm.runInContext(source + '; renderHoverTextScale();', context);
  assert.equal(get('hover-text-scale').value, '1');
  assert.equal(get('reset-hover-text-scale').disabled, true);
  const pending = get('hover-text-scale').change({target:{value:'1.5'}});
  assert.equal(get('hover-text-scale').disabled, true);
  await pending;
  assert.equal(get('hover-text-scale').value, '1.5');
  assert.equal(get('hover-text-scale').disabled, false);
  fail = true;
  await get('hover-text-scale').change({target:{value:'0.8'}});
  assert.equal(get('hover-text-scale').value, '1.5');
  assert.match(errors[0], /test failure/);
  fail = false;
  await get('reset-hover-text-scale').click();
  assert.equal(get('hover-text-scale').value, '1');
  assert.equal(get('reset-hover-text-scale').disabled, true);
  assert.deepEqual(calls, [['set_hover_text_scale',1.5], ['set_hover_text_scale',0.8], ['set_hover_text_scale',1]]);
});

test('custom size preserves presets, coalesces slider requests and restores native state after failure', async () => {
  const settings=readFileSync(path.join(__dirname,'../penguinnotch/ui/settings.html'),'utf8');
  const elements=new Map(),calls=[];let fail=false,release;
  let persisted={preset:0.8,custom:1.137,uses_custom:false};
  const get=id=>{if(!elements.has(id))elements.set(id,{addEventListener(name,fn){this[name]=fn;}});return elements.get(id);};
  const context=vm.createContext({document:{getElementById:get,querySelectorAll:()=>[]},ui:(_,text)=>text,toast(){},strip(){},errText:String,
    call:async()=>persisted,
    invoke:async(cmd,args)=>{
      assert.equal(cmd,'set_custom_notch_scale');calls.push({...args});
      if(fail)throw Error('fixture failure');
      if(calls.length===1) await new Promise(resolve=>release=resolve);
      persisted={...persisted,custom:args.scale,uses_custom:args.enabled};return persisted;
    }});
  vm.runInContext(settings.slice(settings.indexOf('const SIZE_WHY'),settings.indexOf('/* ---- Appearance: meter style')),context);
  context.readSizePrefs(persisted);context.renderSize();
  assert.equal(get('row-custom-size').hidden,true);
  const first=context.saveCustomSize(true,1.137);
  context.saveCustomSize(true,1.18);context.saveCustomSize(true,1.2345);
  assert.equal(calls.length,1,'one native resize in flight');
  release();await first;
  assert.equal(calls.length,2,'intermediate slider values coalesced');
  assert.equal(persisted.custom,1.2345);assert.equal(persisted.preset,0.8);
  assert.equal(get('custom-notch-scale').value,'1.2345');
  await context.saveCustomSize(false,1.2345);
  assert.equal(persisted.uses_custom,false);assert.equal(persisted.custom,1.2345);
  fail=true;await context.saveCustomSize(true,0.75);
  assert.equal(get('row-custom-size').hidden,true);assert.equal(get('custom-notch-scale').value,'1.2345');
  for(const bad of [NaN,Infinity,-Infinity,null,{},'1.2'])assert.equal(context.normalizeCustomScale(bad),1);
  assert.equal(context.normalizeCustomScale(-1),0.75);assert.equal(context.normalizeCustomScale(2),1.5);
});

test('Show notch now uses its own IPC and retains the returned hover mode; failure leaves controls usable', async()=>{
  const settings=readFileSync(path.join(__dirname,'../penguinnotch/ui/settings.html'),'utf8');
  const elements=new Map(),calls=[];let fail=false;
  const get=id=>{if(!elements.has(id))elements.set(id,{addEventListener(name,fn){this[name]=fn;}});return elements.get(id);};
  const context=vm.createContext({document:{getElementById:get,querySelectorAll:()=>[]},window:{__TAURI__:{event:{listen(){}}}},ui:(_,text)=>text,toast(){},strip(){},errText:String,
    invoke:async(cmd,args)=>{calls.push([cmd,args]);if(fail)throw Error('failed');return {notch_visible:true,notch_on_hover:true,tray_visible:true};}});
  vm.runInContext(settings.slice(settings.indexOf('const SHOW_WHY'),settings.indexOf('/* ---- Appearance: size')),context);
  vm.runInContext('flags={notch:false,hover:true,tray:true};renderFlags();',context);
  const first=get('show-notch-now').click();assert.equal(get('show-notch-now').disabled,true);await first;
  assert.equal(context.showMode(),'hover');assert.equal(get('show-notch-now').disabled,false);
  fail=true;await get('show-notch-now').click();assert.equal(context.showMode(),'hover');assert.equal(get('show-notch-now').disabled,false);
  assert.deepEqual(calls,[['show_notch_now',undefined],['show_notch_now',undefined]]);
});

test('account toggle preserves the selected order and does not replace a custom full list with automatic order',async()=>{
  const settings=readFileSync(path.join(__dirname,'../penguinnotch/ui/settings.html'),'utf8');
  const saved=[];
  const context=vm.createContext({notchSlots:[{provider:'grok'},{provider:'claude'},{provider:'codex'}],providerList:()=>['claude','codex','grok'].map(id=>({id})),
    renderAccounts(){},toast(){},strip(){},errText:String,invoke:async(cmd,args)=>{assert.equal(cmd,'set_notch_slots');saved.push(args.slots);}});
  vm.runInContext(settings.slice(settings.indexOf('function notchOn()'),settings.indexOf('function agSelect('))+settings.slice(settings.indexOf('function saveNotch('),settings.indexOf('const accountsPane')),context);
  context.toggleNotch('claude');await Promise.resolve();assert.deepEqual(Array.from(saved[0],s=>s.provider),['grok','codex']);
  context.toggleNotch('claude');await Promise.resolve();assert.deepEqual(Array.from(saved[1],s=>s.provider),['grok','codex','claude']);
  assert.ok(saved[1],'full custom list is not reset to automatic');
});

test('Task6 replay warning and selection labels have exact Korean copy on both platforms',()=>{
  const S=require('../penguinnotch/ui/stocks.js'),B=require('../penguinnotch/ui/backtests.js');
  const strings=JSON.parse(readFileSync(path.join(__dirname,'../../Sources/Localizable.xcstrings'),'utf8')).strings;
  const warning='현재 조회 자료로 재구성; 당시 정보만 사용한 검증을 보장하지 않음';
  assert.equal(S.t('ko',B.REPLAY_WARNING),warning);
  assert.equal(strings[B.REPLAY_WARNING].localizations.ko.stringUnit.value,warning);
  for(const key of ['Forecast history and evaluation','Saved predictions','Historical replay','Completed trading days','Watched symbols (including hidden)','Export evaluation CSV']){
    assert.notEqual(S.t('ko',key),key);
    assert.equal(strings[key].localizations.ko.stringUnit.value,S.t('ko',key));
  }
});


test('final forecast comparison controls and short-session reasons preserve EN/KO meanings',()=>{
 const S=require('../penguinnotch/ui/stocks.js');
 for(const key of ['Comparison models','session_too_short','Excluded conflicts / missing evidence','Previous','Next']){
  assert.notEqual(S.t('ko',key),key,key);assert.equal(S.t('en',key),key);
 }
 const controls=S.comparisonControls(['A','B','C'],['A','B'],'ko');
 assert.match(controls,/비교 모델/);assert.match(controls,/value="A" checked/);assert.match(controls,/value="B" checked/);assert.doesNotMatch(controls,/value="C" checked/);
});
