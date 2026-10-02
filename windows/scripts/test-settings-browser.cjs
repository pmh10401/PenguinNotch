'use strict';
// Run with an installed Playwright on NODE_PATH. Native calls use public synthetic fixtures only.
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const {chromium} = require('playwright');
const root = path.join(__dirname, '../penguinnotch/ui');

function mockIPC(options = {}) {
  if(!crypto.randomUUID)crypto.randomUUID=()=> 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  const initial = {lang:'en', weekly:'inside', transition:'hard_step', adaptive:false, automatic:true, update:{available:null,checking:false,installing:false,message:null,downloaded:null,total:null,deferred:false,preview:false}, slots:[], flags:{notch_visible:true,notch_on_hover:true,tray_visible:true},
    display:{shows_notch_readings:true,weekly_ring_dashed:false,weekly_reading:false,weekly_headline:false,reset_time_format:'automatic',show_usage_pace:false,claude_daily_pace_ring:false,show_codex_extra_limits:true},
    limits:{watch_limit:0.5,critical_limit:0.7},
    widgets:{system:true,calendar:true,weatherOn:true,todoOn:true,
    hidden:['system-gpu','widget-weather'], colors:{'system-cpu':'36a8eb','widget-weather':'00e5cc'},
    order:['system-cpu','codex','widget-calendar','system-memory','widget-stock:us:AAPL','widget-weather','system-gpu','widget-todo'],
    weatherCity:{id:1,name:'Seoul',latitude:37.56,longitude:126.97}}};
  window.replayManifests=[];window.replayBodies={};
  window.fixture = JSON.parse(localStorage.getItem('settings-fixture') || 'null') || initial;
  window.calls = []; window.emitted = []; window.unmocked = []; window.failNextPrefs = false; window.failNextTransition = false; window.failNextDisplay = false; window.failNextLimits = false; window.failNextAutomatic = false;
  const events = new Map(), save = () => localStorage.setItem('settings-fixture', JSON.stringify(fixture));
  window.events = events;
  window.__TAURI__ = {core:{invoke:async(cmd,args={})=>{
    calls.push({cmd,args:structuredClone(args)});
    if(cmd==='stock_backtest_archive'){
      const r=args.request;
      if(r.action==='list'){if(options.delayReplayList)return new Promise(resolve=>window.releaseInitialReplayList=manifests=>resolve({type:'manifests',manifests}));return {type:'manifests',manifests:structuredClone(replayManifests)};}
      if(r.action==='loadManifest')return {type:'manifest',manifest:structuredClone(replayManifests.find(m=>m.runID===r.runID))};
      if(r.action==='loadCase'||r.action==='loadResult')return {type:'body',...replayBodies[r.runID+'/'+r.caseID][r.action]};
      throw Error('No archive writes in UI fixture');
    }
    if(cmd==='set_widget_prefs') {
      await new Promise(resolve=>setTimeout(resolve,30));
      if(window.failNextPrefs){window.failNextPrefs=false;throw Error('fixture save rejected');}
      const p=args.prefs;
      fixture.widgets={...fixture.widgets,system:p.system,calendar:p.calendar,weatherOn:p.weather,todoOn:p.todo,hidden:p.hidden,order:p.order,colors:p.colors};
      save();return structuredClone(fixture.widgets);
    }
    if(cmd==='set_lang'){fixture.lang=args.lang;save();return args.lang;}
    if(cmd==='set_weekly_ring'){fixture.weekly=args.placement;save();return args.placement;}
    if(cmd==='set_color_transition'){
      if(window.failNextTransition){window.failNextTransition=false;throw Error('fixture transition rejected');}
      fixture.transition=args.style;save();return args.style;
    }
    if(cmd==='set_usage_display'){
      if(window.failNextDisplay){window.failNextDisplay=false;throw Error('fixture display rejected');}
      fixture.display={...fixture.display,...args.prefs};save();return structuredClone(fixture.display);
    }
    if(cmd==='set_usage_limits'){
      if(window.failNextLimits){window.failNextLimits=false;throw Error('fixture limits rejected');}
      const c=Math.min(Math.max(Number(args.prefs.critical_limit),0.02),1);
      const w=Math.min(Math.max(Number(args.prefs.watch_limit),0.01),c-0.01);
      fixture.limits={watch_limit:w,critical_limit:c};save();return structuredClone(fixture.limits);
    }
    if(cmd==='set_adaptive_pill'){fixture.adaptive=args.on;save();return args.on;}
    if(cmd==='set_ui_flags'){
      fixture.flags={notch_visible:args.notchVisible,notch_on_hover:args.notchOnHover,tray_visible:args.trayVisible||!args.notchVisible};
      save();return fixture.flags;
    }
    if(cmd==='set_notch_slots'){fixture.slots=args.slots;save();return args.slots;}
    if(cmd==='search_weather_cities')return [{id:2,name:'Hwaseong',admin1:'Gyeonggi',country:'South Korea',latitude:37.2,longitude:126.8}];
    if(cmd==='set_weather_city'){fixture.widgets.weatherCity=args.city;save();return null;}
    if(cmd==='set_automatic_updates'){
      if(window.failNextAutomatic){window.failNextAutomatic=false;throw Error('fixture automatic rejected');}
      fixture.automatic=!!args.enabled;save();return fixture.automatic;
    }
    if(cmd==='check_for_update'){fixture.update={...fixture.update,checking:true,message:null};save();(events.get('update_state')||(()=>{}))({payload:fixture.update});return null;}
    if(cmd==='preview_update'){fixture.update={...fixture.update,available:'1.22.0',preview:true,deferred:false,checking:false,installing:false,message:null,downloaded:null,total:null};save();(events.get('update_state')||(()=>{}))({payload:fixture.update});return null;}
    if(cmd==='reoffer_update'){if(fixture.update.available){fixture.update={...fixture.update,deferred:false};save();(events.get('update_state')||(()=>{}))({payload:fixture.update});}return null;}
    if(cmd==='dismiss_update'){fixture.update={...fixture.update,deferred:true};save();(events.get('update_state')||(()=>{}))({payload:fixture.update});return null;}
    if(cmd==='install_update'){fixture.update={...fixture.update,installing:true,deferred:false,message:null};save();(events.get('update_state')||(()=>{}))({payload:fixture.update});return null;}
    const flags=fixture.flags;
    const replies={get_lang:fixture.lang,get_lang_resolved:fixture.lang,get_system_look:{mica:false},get_theme:'dark',get_theme_resolved:'dark',
      get_notch_size_prefs:{preset:1,custom:1,uses_custom:false},get_scale:1,get_notch_edge:'right',get_notch_meter_style:'ring',get_hover_text_scale:1,
      get_monitors:[],get_weekly_ring:fixture.weekly,get_color_transition:fixture.transition,get_usage_display:fixture.display,get_usage_limits:fixture.limits,get_adaptive_pill:fixture.adaptive,get_ui_flags:flags,show_notch_now:flags,get_move_handle:true,
      get_autostart:false,get_hooks_installed:false,get_glyphs:{},get_notch_slots:fixture.slots,
      get_tray_options:[{id:'claude',label:'Claude',status:'ok',used:0.25},{id:'codex',label:'Codex',status:'ok',used:0.5},{id:'opencode',label:'OpenCode',status:'ok',used:12}],
      get_antigravity_prefs:{limit:'automatic',model:'gemini'},get_widget_prefs:fixture.widgets,
      get_update_state:fixture.update,get_automatic_updates:fixture.automatic!==false,
      stock_backtest_archive:{type:'manifests',manifests:[]},get_stock_settings:{enabled:false,symbols:[]},get_stock_credential_status:{toss:false,finnhub:false},load_stock_history:{version:1,trends:[],forecasts:[]}};
    if(!(cmd in replies)){unmocked.push(cmd);throw Error('Unmocked native call: '+cmd);}
    return structuredClone(replies[cmd]);
  }},event:{listen:async(name,fn)=>{events.set(name,fn);return()=>events.delete(name);},emit:async(name,payload)=>{emitted.push({name,payload});}},
  app:{getVersion:async()=>'settings QA'},window:{getCurrentWindow:()=>({
    onCloseRequested:async fn=>{window.nativeCloseRequested=fn;return()=>{};},
    hide:async()=>{window.hideCount=(window.hideCount||0)+1;},
    close:async()=>{let prevented=false;await window.nativeCloseRequested?.({preventDefault(){prevented=true;}});if(!prevented)window.destroyCount=(window.destroyCount||0)+1;}
  })}};
}

(async()=>{
  const browser=await chromium.launch({headless:true});
  try {
    const context=await browser.newContext({viewport:{width:680,height:520}}),errors=[],external=[];
    await context.route('**/*',route=>{
      const url=new URL(route.request().url()),name=path.basename(url.pathname);
      if(url.hostname==='settings.test'&&['settings.html','stocks.js','stocks.css','backtests.js','krx-listed-companies.tsv'].includes(name))
        return route.fulfill({path:path.join(root,name),contentType:name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':'text/javascript'});
      external.push(url.href);return route.abort();
    });
    await context.addInitScript(mockIPC,{delayReplayList:process.env.TASK6_FIX_ONLY==='1'&&process.env.TASK6_FIX_CASE==='listing'});
    const page=await context.newPage();
    page.on('pageerror',e=>errors.push(e.message));
    page.on('console',m=>{if(['error','warning'].includes(m.type()))errors.push(m.text());});
    await page.goto('http://settings.test/settings.html');
    await page.waitForSelector('#monitoring-box [data-hide="system-cpu"]',{state:'attached'});
    assert.equal(await page.title(),'PenguinNotch Settings');
    assert.equal(page.url(),'http://settings.test/settings.html');
    const tabs=['accounts','stocks','monitoring','widgets','appearance','general'];
    assert.deepEqual(await page.locator('[role=tab] > span:last-child').allTextContents(),['AI subscriptions','Stocks','Computer monitoring','Daily widgets','Appearance','General']);
    if(process.env.TASK6_FIX_ONLY==='1'){await task6ReviewFixUI(page,process.env.TASK6_FIX_CASE);assert.deepEqual(errors,[]);assert.deepEqual(external,[]);assert.deepEqual(await page.evaluate(()=>unmocked),[]);console.log('PASS Task6 fix1 actual settings mount: '+process.env.TASK6_FIX_CASE);return;}
    await task6ReplayUI(page);
    const idle=()=>page.waitForFunction(()=>!widgetSaving);
    const click=async selector=>{await page.locator(selector).click();await idle();};
    const state=()=>page.evaluate(()=>structuredClone(fixture.widgets));
    for(const tab of tabs){
      await page.locator('#tab-'+tab).click();
      assert.equal(await page.locator('.pane:visible').count(),1);
      assert.equal(await page.locator('#pane-'+tab).isVisible(),true);
      assert.ok(await page.locator('#subtitle').textContent());
    }
    assert.ok(await page.evaluate(()=>emitted.some(e=>e.name==='stock-view-state'&&e.payload.visible===true)));
    assert.equal(await page.evaluate(()=>emitted.filter(e=>e.name==='stock-view-state').at(-1).payload.visible),false);
    await page.locator('#tab-general').focus();await page.keyboard.press('Home');
    assert.equal(await page.locator('#tab-accounts').getAttribute('aria-selected'),'true');
    await page.keyboard.press('ArrowDown');
    await page.waitForFunction(()=>document.getElementById('tab-stocks').getAttribute('aria-selected')==='true');
    assert.equal(await page.evaluate(()=>document.activeElement&&document.activeElement.id),'tab-stocks');
    await page.keyboard.press('ArrowDown');
    assert.equal(await page.locator('#tab-monitoring').getAttribute('aria-selected'),'true');
    await page.locator('#tab-stocks').click();
    await page.waitForFunction(()=>document.activeElement&&document.activeElement.id==='stock-tab-watchlist');
    assert.ok((await page.locator('#stock-tab-watchlist').boundingBox()).y >= 0,
      'Stocks opens at the navigation instead of scrolling to the symbol field');
    await page.locator('#tab-monitoring').click();
    const original=await state();
    assert.equal(await page.locator('#pane-monitoring [data-hide]').count(),7);
    assert.equal(await page.locator('#pane-widgets [data-hide]').count(),3);
    assert.equal(await page.locator('#pane-appearance [data-hide], #pane-appearance #wx-q').count(),0);
    await click('[data-hide="system-cpu"]');
    assert.ok((await state()).hidden.includes('system-cpu'));
    assert.equal((await state()).weatherOn,true);
    await click('#sw-system');
    assert.equal(await page.locator('#pane-monitoring [data-hide]:disabled').count(),7);
    await click('#sw-system');
    assert.equal(await page.locator('[data-hide="system-cpu"]').getAttribute('aria-checked'),'false');
    assert.equal(await page.locator('[data-hide="system-gpu"]').getAttribute('aria-checked'),'false');
    const beforeMove=await state();
    await click('[data-move="system-cpu"][data-dir="1"]');
    const afterMove=await state();
    for(const id of ['codex','widget-calendar','widget-weather','widget-todo','widget-stock:us:AAPL'])
      assert.equal(afterMove.order.indexOf(id),beforeMove.order.indexOf(id),'other sections keep their slots');
    assert.equal(afterMove.order.indexOf('system-cpu'),beforeMove.order.indexOf('system-memory'));
    await page.locator('#tab-widgets').click();
    assert.equal(await page.locator('[data-hide="widget-weather"]').getAttribute('aria-checked'),'false','legacy hidden flag is reflected');
    await click('[data-hide="widget-weather"]');
    assert.equal((await state()).weatherOn,true);assert.ok(!(await state()).hidden.includes('widget-weather'));
    await click('[data-hide="widget-calendar"]');
    assert.equal((await state()).calendar,false);assert.ok((await state()).hidden.includes('system-gpu'));
    await click('[data-color="widget-weather"]');
    assert.notEqual((await state()).colors['widget-weather'],original.colors['widget-weather']);
    assert.equal((await state()).colors['system-cpu'],original.colors['system-cpu']);
    await page.locator('#wx-q').fill('Hwaseong');await page.locator('#wx-q').press('Enter');
    await page.locator('#wx-results button').click();
    await page.waitForFunction(()=>fixture.widgets.weatherCity?.id===2);
    await page.locator('#tab-accounts').click();
    await page.locator('[data-np="opencode"]').click();
    await page.waitForFunction(()=>fixture.slots?.some(s=>s.provider==='opencode'));
    assert.equal(await page.locator('[data-np="opencode"]').getAttribute('aria-checked'),'true');
    assert.equal(await page.locator('#seg-weekly').isVisible(),true);
    await page.locator('#seg-weekly [data-v="outside"]').click();
    await page.waitForFunction(()=>fixture.weekly==='outside');
    assert.equal(await page.locator('#weekly-ring-extras').isVisible(),true,'dashed and weekly-reading appear while the ring is on');
    await page.locator('#sw-weekly-dashed').click();
    await page.waitForFunction(()=>fixture.display.weekly_ring_dashed===true&&!usageDisplayBusy);
    await page.locator('#seg-weekly [data-v="off"]').click();
    await page.waitForFunction(()=>fixture.weekly==='off');
    assert.equal(await page.locator('#weekly-ring-extras').isVisible(),false,'ring-off hides dependent controls');
    assert.equal(await page.evaluate(()=>fixture.display.weekly_ring_dashed),true,'hiding extras does not erase the saved dash choice');
    await page.locator('#seg-weekly [data-v="outside"]').click();
    await page.waitForFunction(()=>fixture.weekly==='outside');
    assert.equal(await page.locator('#sw-weekly-dashed').getAttribute('aria-checked'),'true','saved dash choice returns with the extras');
    await page.locator('#sw-readings').click();
    await page.waitForFunction(()=>fixture.display.shows_notch_readings===false&&!usageDisplayBusy);
    await page.locator('#seg-reset-time [data-v="remaining"]').click();
    await page.waitForFunction(()=>fixture.display.reset_time_format==='remaining'&&!usageDisplayBusy);
    await page.evaluate(()=>window.failNextDisplay=true);
    await page.locator('#sw-usage-pace').click();
    await page.waitForFunction(()=>!usageDisplayBusy);
    assert.equal(await page.locator('#sw-usage-pace').getAttribute('aria-checked'),'false','failed display save restores native value');
    assert.match(await page.locator('#strip').textContent(),/fixture display rejected/);
    assert.equal(await page.evaluate(()=>fixture.display.show_usage_pace),false);
    await page.locator('#seg-transition [data-v="ramp"]').click();
    await page.waitForFunction(()=>fixture.transition==='ramp'&&!transitionBusy);
    assert.match(await page.locator('#cap-transition').textContent(),/watch limit below/);
    assert.equal(await page.locator('#cap-critical').isVisible(),true);
    await page.evaluate(()=>window.failNextTransition=true);
    await page.locator('#seg-transition [data-v="hard_step"]').click();
    await page.waitForFunction(()=>!transitionBusy);
    assert.equal(await page.locator('#seg-transition [data-v="ramp"]').getAttribute('aria-pressed'),'true','failed transition save restores native value');
    assert.match(await page.locator('#strip').textContent(),/fixture transition rejected/);
    await page.locator('#watch-limit').evaluate(el=>{el.value='0.9';el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));});
    await page.waitForFunction(()=>fixture.limits.watch_limit<=fixture.limits.critical_limit-0.01);
    assert.ok((await page.evaluate(()=>fixture.limits.watch_limit)) < (await page.evaluate(()=>fixture.limits.critical_limit)));
    await page.locator('#btn-limits-reset').click();
    await page.waitForFunction(()=>fixture.limits.watch_limit===0.5&&fixture.limits.critical_limit===0.7&&!usageLimitsBusy);
    await page.evaluate(()=>window.failNextLimits=true);
    await page.locator('#critical-limit').evaluate(el=>{el.value='0.9';el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));});
    await page.waitForFunction(()=>!usageLimitsBusy);
    assert.equal(await page.evaluate(()=>fixture.limits.critical_limit),0.7,'failed limits save restores native value');
    await page.locator('#tab-appearance').click();
    assert.equal(await page.locator('#seg-weekly').count(),1,'weekly ring stays in AI subscriptions');
    assert.equal(await page.locator('#seg-weekly').isVisible(),false);
    assert.equal(await page.locator('#seg-transition').count(),1,'colour transition is not duplicated in Appearance');
    assert.equal(await page.locator('#seg-transition').isVisible(),false);
    assert.equal(await page.locator('#seg-size').count(),1,'custom size does not duplicate the preset control');
    assert.equal(await page.locator('#sw-adaptive').getAttribute('aria-checked'),'false','screen sampling is opt-in');
    await page.locator('#sw-adaptive').click();
    await page.waitForFunction(()=>fixture.adaptive&&!adaptivePill.busy);
    await page.locator('#tab-general').click();
    assert.equal(await page.locator('#seg-tray').isVisible(),true);
    await page.locator('#seg-tray [data-v="none"]').click();
    await page.waitForFunction(()=>fixture.flags.tray_visible===false);
    assert.equal(await page.evaluate(()=>fixture.flags.notch_visible),true);
    assert.equal(await page.locator('#sw-auto-update').getAttribute('aria-checked'),'true');
    await page.evaluate(()=>window.failNextAutomatic=true);
    await page.locator('#sw-auto-update').click();
    await page.waitForFunction(()=>!autoUpdate.busy);
    assert.equal(await page.evaluate(()=>fixture.automatic),true,'failed automatic save restores native value');
    assert.equal(await page.locator('#sw-auto-update').getAttribute('aria-checked'),'true');
    await page.locator('#sw-auto-update').click();
    await page.waitForFunction(()=>fixture.automatic===false&&!autoUpdate.busy);
    await page.locator('#btn-update-preview').click();
    await page.waitForFunction(()=>fixture.update.preview===true&&fixture.update.available==='1.22.0');
    assert.equal(await page.evaluate(()=>calls.some(c=>c.cmd==='install_update')),false,'preview does not install');
    await page.evaluate(()=>{fixture.update={available:'1.22.0',preview:false,deferred:true,checking:false,installing:false,message:null,downloaded:null,total:null};(events.get('update_state')||(()=>{}))({payload:fixture.update});});
    await page.waitForFunction(()=>document.getElementById('btn-update-show')&&!document.getElementById('btn-update-show').hidden);
    await page.locator('#btn-update-show').click();
    await page.waitForFunction(()=>fixture.update.deferred===false);
    await page.locator('#lang').selectOption('ko');
    assert.deepEqual(await page.locator('[role=tab] > span:last-child').allTextContents(),['AI 구독','주식','컴퓨터 모니터링','생활 위젯','모양','일반']);
    await page.locator('#tab-accounts').click();
    assert.match(await page.locator('#pane-accounts').innerText(),/각 링 아래에 백분율 표시/);
    assert.match(await page.locator('#pane-accounts').innerText(),/주의 표시 기준/);
    assert.match(await page.locator('#sw-readings').getAttribute('aria-label'),/각 링 아래에 백분율 표시/);
    await page.locator('#tab-monitoring').click();
    const beforeFailure=await state();
    await page.evaluate(()=>window.failNextPrefs=true);
    await click('[data-color="system-cpu"]');
    assert.deepEqual(await state(),beforeFailure,'rejected save preserves every section');
    assert.match(await page.locator('#strip').textContent(),/fixture save rejected/);
    assert.equal(await page.locator('[data-color="system-cpu"]').isEnabled(),true);
    await page.locator('#tab-widgets').click();
    const saved=await state();await page.reload();
    await page.waitForSelector('#pane-widgets:visible [data-hide="widget-calendar"]');
    assert.deepEqual(await state(),saved,'settings and selected pane survive reload');
    assert.equal(await page.evaluate(()=>fixture.weekly),'outside');
    assert.equal(await page.evaluate(()=>fixture.transition),'ramp');
    assert.equal(await page.evaluate(()=>fixture.display.shows_notch_readings),false);
    assert.equal(await page.evaluate(()=>fixture.display.reset_time_format),'remaining');
    assert.equal(await page.evaluate(()=>fixture.display.weekly_ring_dashed),true);
    assert.equal(await page.evaluate(()=>fixture.limits.watch_limit),0.5);
    assert.equal(await page.evaluate(()=>fixture.automatic),false);
    assert.equal(await page.evaluate(()=>fixture.adaptive),true);
    assert.deepEqual(await page.evaluate(()=>fixture.slots),[{provider:'opencode'}]);
    assert.equal(await page.evaluate(()=>fixture.flags.tray_visible),false);
    assert.equal(await page.locator('[data-hide="widget-calendar"]').getAttribute('aria-checked'),'false');
    const evidence=process.env.SETTINGS_EVIDENCE;
    if(evidence)fs.mkdirSync(evidence,{recursive:true});
    for(const size of [{width:680,height:520},{width:860,height:680}])for(const theme of ['dark','light']){
      await page.setViewportSize(size);await page.evaluate(theme=>applyTheme(theme),theme);
      for(const tab of tabs){
        await page.locator('#tab-'+tab).click();
        const overflow=await page.evaluate(()=>({page:document.documentElement.scrollWidth>innerWidth,body:document.getElementById('body').scrollWidth>document.getElementById('body').clientWidth}));
        assert.deepEqual(overflow,{page:false,body:false},`${tab} ${theme} ${size.width} overflow`);
        if(evidence&&size.width===680&&theme==='dark'&&['accounts','appearance','monitoring','widgets'].includes(tab))await page.screenshot({path:path.join(evidence,tab+'-ko.png')});
      }
    }
    await page.locator('#tab-general').click();
    await page.locator('#lang').selectOption('ru');
    await page.locator('#tab-appearance').click();
    await page.setViewportSize({width:680,height:520});
    assert.equal(await page.evaluate(()=>document.getElementById('body').scrollWidth>document.getElementById('body').clientWidth),false,'Russian segmented controls wrap at the native size');
    assert.deepEqual(await page.evaluate(()=>unmocked),[]);
    assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
    console.log('PASS: six macOS-aligned sections, English/Korean, keyboard and saved tabs, independent hardware/widgets, legacy visibility, scoped order/color, city search, OpenCode, adaptive pill, color transition rollback, stock view events, persistence and 24 layout checks; no console errors, unmocked calls or external requests');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});

async function task6ReplayUI(page){
  await page.locator('#tab-stocks').click();
  await page.locator('#stock-tab-history').focus();await page.keyboard.press('Enter');
  assert.equal(await page.locator('#stock-history-replay').count(),1,'one integrated saved/replay history entry');
  await page.locator('#stock-history-replay').focus();await page.keyboard.press('Enter');
  assert.equal(await page.locator('#backtest-sessions').inputValue(),'60');
  assert.deepEqual(await page.locator('#backtest-sessions option').allTextContents(),['20','60','120']);
  assert.equal(await page.locator('#backtest-start').isEnabled(),false,'empty watchlist');
  assert.match(await page.locator('#stock-replay').textContent(),/No historical replay runs/);
  for(const n of ['20','60','120'])await page.locator('#backtest-sessions').selectOption(n);
  await page.evaluate(()=>{
    stockSettingsStore.configure({enabled:false,provider:'toss',symbols:[{symbol:'TEST',market:'us',name:'=TEST,"quoted"\nnext',visible:false}]});
    window.fixtureStarts=0;window.fixtureResumes=0;
    const originalStart=stockBacktestStore.start.bind(stockBacktestStore),originalResume=stockBacktestStore.resume.bind(stockBacktestStore);
    stockBacktestStore.resume=run=>{fixtureResumes++;return originalResume(run);};
    stockBacktestStore.start=args=>{fixtureStarts++;window.startedSymbols=args.symbols;return originalStart(args);};
    stockBacktestStore.stockRequest=()=>new Promise(resolve=>window.releaseReplay=()=>resolve({type:'calendar',requestedAt:Date.now(),value:null}));
  });
  assert.match(await page.locator('#stock-replay').textContent(),/including hidden.*1\/30/);
  await page.locator('#backtest-start').focus();await page.keyboard.press('Enter');
  await page.waitForFunction(()=>stockBacktestStore.busy&&window.releaseReplay);
  await page.evaluate(()=>{
    const generation=stockBacktestStore.generation;
    stockSettingsStore.configure({...stockSettingsStore.settings,symbols:Array.from({length:30},(_,i)=>({symbol:'TK'+i,market:'us',visible:i!==0}))});
    if(stockBacktestStore.generation!==generation)throw Error('Watchlist edit cancelled frozen replay');
    stockSettingsStore.settings.accountNotchEnabled=true;stockSettingsStore.settings.accountNotchSeq=7;stockSettingsStore.settings.accountSeq=9;
    document.getElementById('stock-client-id').value='PUBLIC_FIXTURE';
    document.getElementById('stock-client-secret').value='PUBLIC_FIXTURE';
    stockSettingsStore.viewerOverview={publicFixture:true};stockSettingsStore.viewerOpen=true;
  });
  await page.locator('#close').click();
  assert.equal(await page.evaluate(()=>hideCount),1);assert.equal(await page.evaluate(()=>window.destroyCount||0),0);
  assert.equal(await page.locator('#stock-client-secret').inputValue(),'');
  assert.equal(await page.locator('#stock-client-id').inputValue(),'');
  assert.equal(await page.evaluate(()=>stockSettingsStore.settings.accountNotchEnabled),true);
  assert.equal(await page.evaluate(()=>stockSettingsStore.settings.accountSeq),9);
  assert.equal(await page.evaluate(()=>startedSymbols.length),1);
  assert.match(await page.locator('#stock-replay').textContent(),/30\/30/);
  assert.equal(await page.evaluate(()=>stockSettingsStore.viewerOverview),null);
  await page.evaluate(()=>window.dispatchEvent(new Event('focus')));
  assert.equal(await page.locator('#stock-tab-history').getAttribute('aria-selected'),'true');
  assert.equal(await page.locator('#stock-replay').isVisible(),true);
  assert.equal(await page.locator('#backtest-sessions').inputValue(),'120');
  assert.equal(await page.evaluate(()=>fixtureStarts),1);assert.equal(await page.evaluate(()=>startedSymbols[0].visible),false);
  await page.evaluate(async()=>{window.preventedNative=0;await nativeCloseRequested({preventDefault(){preventedNative++;}});});
  assert.equal(await page.evaluate(()=>preventedNative),1);assert.equal(await page.evaluate(()=>hideCount),2);
  await page.evaluate(()=>window.dispatchEvent(new Event('focus')));
  await page.locator('#backtest-cancel').focus();await page.keyboard.press('Enter');
  await page.evaluate(()=>releaseReplay());await page.waitForFunction(()=>!stockBacktestStore.busy);
  assert.equal(await page.evaluate(()=>fixtureStarts),1);assert.equal(await page.evaluate(()=>fixtureResumes),0);
  assert.match(await page.locator('#stock-replay').textContent(),/paused|collection_cancelled/);
  // Public fake completed owner settles while hidden; official close proceeds normally and frees WebView.
  await page.evaluate(async()=>{stockBacktestStore.busy=true;stockBacktestStore.activeRunID='public';await nativeCloseRequested({preventDefault(){}});stockBacktestStore.busy=false;stockBacktestStore.activeRunID=null;stockBacktestStore.emit();});
  await page.waitForFunction(()=>window.destroyCount===1);
  const hideBefore=await page.evaluate(()=>hideCount);
  await page.locator('#close').click();assert.equal(await page.evaluate(()=>destroyCount),2);assert.equal(await page.evaluate(()=>hideCount),hideBefore);
  await page.evaluate(async()=>{await __TAURI__.window.getCurrentWindow().close();window.dispatchEvent(new Event('focus'));});
  assert.equal(await page.evaluate(()=>destroyCount),3);

  const fixture=require('../../Tests/Fixtures/stock-forecast-evaluation-v1.json');
  const sample=fixture.replayCases[0].caseData;
  const models=['GBM daily zero drift v1 / replay v1','GBM 1m zero drift v1 / replay v1','GBM 10m zero drift v1 / replay v1'];
  const hash='a'.repeat(64),resultHash='b'.repeat(64),runID='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const entry={caseID:sample.input.caseID,stockID:sample.input.stockID,tradingDay:sample.input.tradingDay,status:'saved',inputSHA256:hash,resultSHA256:resultHash,reason:null};
  // Expected fixture uses interval keys; no prediction is run by the rendered UI.
  const result={version:1,caseID:entry.caseID,inputSHA256:hash,calculationVersion:'replay-v1',computedAt:sample.target.fetchedAt,outcomes:models.map((model,i)=>({model,status:'forecast',reason:null,forecast:fixture.replayCases[0].expected[['1d','1m','10m'][i]]}))};
  const day='2026-09-24',pending={...entry,caseID:entry.caseID.replace(entry.tradingDay,day),tradingDay:day,status:'pending',inputSHA256:null,resultSHA256:null};
  const manifest={version:1,runID,createdAt:sample.target.fetchedAt,collectionStartedAt:sample.target.fetchedAt,collectionCompletedAt:null,protocolVersion:'replay-v1',codeVersion:'PUBLIC-FIXTURE',priceBasis:'provider-adjusted-as-fetched',cutoffMinutes:60,sessions:20,symbols:[entry.stockID],models,status:'paused',cases:[entry,pending]};
  await page.evaluate(({manifest,sample,result,hash,resultHash})=>{
    replayManifests=[manifest];replayBodies[manifest.runID+'/'+sample.input.caseID]={loadCase:{body:JSON.stringify(sample),sha256:hash},loadResult:{body:JSON.stringify(result),sha256:resultHash}};
    stockBacktestStore.runs=replayManifests;stockBacktestStore.errorMessage=null;stockBacktestStore.emit();
  },{manifest,sample,result,hash,resultHash});
  await page.waitForSelector('#backtest-export');
  await page.waitForFunction(()=>document.getElementById('stock-replay').textContent.includes('1/2')&&!document.getElementById('stock-replay').textContent.includes('Loading saved results'));
  assert.match(await page.locator('#stock-replay').textContent(),/Pending: 1/);
  assert.equal(await page.locator('.stock-evaluation').count(),3);
  const disclosure=page.locator('.stock-evaluation details').first();await disclosure.locator(':scope > summary').click();
  await page.evaluate(()=>stockBacktestStore.emit());assert.equal(await disclosure.getAttribute('open'),'');
  await page.locator('#backtest-day').selectOption(entry.tradingDay);
  assert.match(await page.locator('#stock-replay').textContent(),/1\/1/);
  await page.evaluate(()=>stockBacktestStore.emit());assert.equal(await page.locator('#backtest-day').inputValue(),entry.tradingDay);
  await page.locator('#backtest-model').selectOption(models[0]);assert.equal(await page.locator('.stock-evaluation').count(),1);
  await page.locator('#backtest-model').selectOption('');
  for(const language of ['en','ko']){
    await page.evaluate(language=>setUiLanguage(language),language);
    assert.ok((await page.locator('#stock-replay').textContent()).includes(language==='ko'?'현재 조회 자료로 재구성; 당시 정보만 사용한 검증을 보장하지 않음':'Reconstructed from data fetched now; availability at the original time is not guaranteed.'));
    for(const size of [{width:680,height:520},{width:860,height:680}]){
      await page.setViewportSize(size);await page.evaluate(()=>document.getElementById('stock-replay').style.fontSize='20px');
      assert.equal(await page.evaluate(()=>document.getElementById('stock-panel-history').scrollWidth>document.getElementById('stock-panel-history').clientWidth),false);
    }
  }
  await page.evaluate(()=>{document.getElementById('stock-replay').style.fontSize='';setUiLanguage('en');});
  await page.setViewportSize({width:680,height:520});
  const skipped=structuredClone(sample);skipped.input.dailyCloses=[];skipped.input.minutes=skipped.input.minutes.slice(-1);
  const allSkipped={...result,outcomes:models.map(model=>({model,status:'skipped',reason:model.includes('daily')?'insufficient_daily_history':'insufficient_intraday_history',forecast:null}))};
  await page.evaluate(({manifest,entry,skipped,allSkipped,hash,resultHash})=>{
    const m={...manifest,runID:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',status:'completed',collectionCompletedAt:manifest.createdAt,cases:[entry]};
    replayManifests.push(m);replayBodies[m.runID+'/'+entry.caseID]={loadCase:{body:JSON.stringify(skipped),sha256:hash},loadResult:{body:JSON.stringify(allSkipped),sha256:resultHash}};
    stockBacktestStore.runs=replayManifests;stockBacktestStore.emit();
  },{manifest,entry,skipped,allSkipped,hash,resultHash});
  await page.locator('#backtest-run').selectOption('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
  await page.waitForFunction(()=>document.getElementById('stock-replay').textContent.includes('Skipped: 1'));
  assert.equal(await page.locator('.stock-evaluation').count(),0,'all skipped never becomes a perfect score');
  await page.locator('[data-stock-disclosure^="replay-case:"] summary').click();
  assert.match(await page.locator('.stock-raw').textContent(),/insufficient_daily_history/);
  // A late failed read from the previous selection cannot contaminate the current run.
  await page.evaluate(()=>{window.originalCaseLoader=stockBacktestStore.loadCase.bind(stockBacktestStore);stockBacktestStore.loadCase=(run,id)=>run==='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'?new Promise((_,reject)=>window.rejectStaleLoad=()=>reject(Error('public stale read'))):originalCaseLoader(run,id);});
  await page.locator('#backtest-run').selectOption('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  await page.locator('#backtest-run').selectOption('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
  await page.waitForFunction(()=>document.getElementById('stock-replay').textContent.includes('Skipped: 1')&&!document.getElementById('stock-replay').textContent.includes('Loading saved results'));
  await page.evaluate(async()=>{rejectStaleLoad();await Promise.resolve();stockBacktestStore.emit();stockBacktestStore.loadCase=originalCaseLoader;});
  assert.equal(await page.locator('#stock-replay [role="alert"]').count(),0,'stale failed archive reply stays with its original selection');
  await page.evaluate(()=>{stockBacktestStore.errorMessage='archive_unavailable';stockBacktestStore.emit();});
  assert.equal(await page.locator('#backtest-start').isEnabled(),false);
  await page.evaluate(()=>{stockBacktestStore.errorMessage=null;stockSettingsStore.configure({provider:'finnhub',enabled:false,symbols:[{symbol:'TEST',market:'us'}]});});
  assert.equal(await page.locator('#backtest-start').isEnabled(),false);
  assert.match(await page.locator('#stock-replay').textContent(),/requires Toss Securities/);
  await page.locator('#stock-history-saved').click();
  const malicious=structuredClone(fixture.records[0]);malicious.name='=TEST,"quoted"\nnext';
  await page.evaluate(record=>{stockSettingsStore.history={version:1,trends:[],forecasts:[record]};stockSettingsStore.configure({provider:'toss',enabled:false,symbols:[]});stockSettingsView.render();},malicious);
  assert.ok((await page.locator('#stock-history').textContent()).includes(malicious.name));
  assert.equal(await page.locator('#stock-history script').count(),0);
  const csv=await page.evaluate(()=>PenguinNotchStocks.csv(stockSettingsStore.history.forecasts,false));
  assert.ok(csv.includes("'=TEST"));assert.ok(csv.includes('""quoted""'));
  await page.locator('#stock-history-filter-model').selectOption(malicious.model);
  await page.locator('[data-stock-disclosure^="history:"] > summary').click();
  await page.locator('[data-stock-disclosure^="record:"] > summary').click();
  await page.evaluate(()=>stockSettingsView.render());
  assert.equal(await page.locator('#stock-history-filter-model').inputValue(),malicious.model);
  assert.equal(await page.locator('[data-stock-disclosure^="record:"]').getAttribute('open'),'');
  assert.equal(await page.locator('#stock-export-forecasts').isEnabled(),true);
  await page.evaluate(()=>{stockSettingsStore.history={version:1,trends:[],forecasts:[]};stockSettingsView.render();});
  await page.locator('#stock-tab-watchlist').click();
}


async function task6ReviewFixUI(page,check){
  const fixture=require('../../Tests/Fixtures/stock-forecast-evaluation-v1.json'),sample=fixture.replayCases[0].caseData;
  const models=['GBM daily zero drift v1 / replay v1','GBM 1m zero drift v1 / replay v1','GBM 10m zero drift v1 / replay v1'];
  const hash='a'.repeat(64),resultHash='b'.repeat(64),runID='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const entry={caseID:sample.input.caseID,stockID:sample.input.stockID,tradingDay:sample.input.tradingDay,status:'saved',inputSHA256:hash,resultSHA256:resultHash,reason:null};
  const result={version:1,caseID:entry.caseID,inputSHA256:hash,calculationVersion:'replay-v1',computedAt:sample.target.fetchedAt,outcomes:models.map((model,i)=>({model,status:'forecast',reason:null,forecast:fixture.replayCases[0].expected[['1d','1m','10m'][i]]}))};
  const manifest={version:1,runID,createdAt:sample.target.fetchedAt,collectionStartedAt:sample.target.fetchedAt,collectionCompletedAt:sample.target.fetchedAt,protocolVersion:'replay-v1',codeVersion:'PUBLIC-FIXTURE',priceBasis:'provider-adjusted-as-fetched',cutoffMinutes:60,sessions:20,symbols:[entry.stockID],models,status:'completed',cases:[entry]};
  await page.waitForFunction(()=>stockSettingsStore.credentialGeneration>0&&calls.some(c=>c.cmd==='get_stock_settings'));
  if(check==='listing'){
    assert.equal(await page.evaluate(()=>stockBacktestStore.runs.length),0);
    await page.evaluate(manifest=>{replayManifests=[manifest];releaseInitialReplayList(replayManifests);},manifest);
    await page.evaluate(()=>stockBacktestStore.ready);
    assert.equal(await page.evaluate(()=>stockBacktestStore.runs.length),1,'actual settings mount/status reload preserves delayed initial list1');
    // Older unknown archives must join without overwriting newer known rows.
    const merged=await page.evaluate(async manifest=>{
      let release;const owner=new PenguinNotchBacktests.BacktestStore({invoke:async()=>new Promise(r=>release=r)});
      owner.publish({...manifest,status:'paused',collectionCompletedAt:null});
      const older={...manifest,runID:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',createdAt:manifest.createdAt-1000,collectionStartedAt:manifest.createdAt-1000};
      release({type:'manifests',manifests:[manifest,older]});await owner.ready;
      return owner.runs.map(m=>({runID:m.runID,status:m.status}));
    },manifest);
    assert.deepEqual(merged,[{runID:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',status:'completed'},{runID:manifest.runID,status:'paused'}]);
    return;
  }
  await page.evaluate(({manifest,sample,result,hash,resultHash})=>{
    replayManifests=[manifest];replayBodies[manifest.runID+'/'+sample.input.caseID]={loadCase:{body:JSON.stringify(sample),sha256:hash},loadResult:{body:JSON.stringify(result),sha256:resultHash}};
    stockBacktestStore.runs=replayManifests;stockBacktestStore.emit();
  },{manifest,sample,result,hash,resultHash});
  await page.locator('#tab-stocks').click();await page.locator('#stock-tab-history').click();await page.locator('#stock-history-replay').click();
  await page.waitForFunction(()=>document.querySelectorAll('.stock-evaluation').length===3&&!document.getElementById('stock-replay').textContent.includes('Loading saved results'));
  if(check==='focus'){
    const summary=page.locator('.stock-evaluation details > summary').first();await summary.focus();
    const key=await summary.evaluate(e=>e.parentElement.dataset.stockDisclosure);
    await page.evaluate(()=>stockBacktestStore.emit());
    assert.equal(await page.evaluate(()=>document.activeElement?.parentElement?.dataset.stockDisclosure),key,'IDless summary keyboard focus survives actual store refresh');
    await page.keyboard.press('Enter');assert.equal(await page.locator('.stock-evaluation details').first().getAttribute('open'),'');
  }else if(check==='units'){
    for(const lang of ['en','ko']){
      await page.evaluate(lang=>setUiLanguage(lang),lang);
      const comparison=page.locator('[data-stock-disclosure="replay-comparison"]');await comparison.locator(':scope > summary').click();
      const text=await comparison.textContent();assert.match(text,/MAPE \d+\.\d+% · Brier (?:0\.\d+|0|1)/,'paired MAPE has percentage units, Brier remains a fraction');
      assert.doesNotMatch(text,/Brier [\d.]+%/);
      await comparison.locator(':scope > summary').click();
    }
  }else throw Error('Unknown focused review check');
}
