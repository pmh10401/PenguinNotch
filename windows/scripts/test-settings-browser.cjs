'use strict';
// Run with an installed Playwright on NODE_PATH. Native calls use public synthetic fixtures only.
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const {chromium} = require('playwright');
const root = path.join(__dirname, '../penguinnotch/ui');

function mockIPC() {
  const initial = {lang:'en', weekly:'inside', transition:'hard_step', adaptive:false, automatic:true, update:{available:null,checking:false,installing:false,message:null,downloaded:null,total:null,deferred:false,preview:false}, slots:[], flags:{notch_visible:true,notch_on_hover:true,tray_visible:true},
    display:{shows_notch_readings:true,weekly_ring_dashed:false,weekly_reading:false,weekly_headline:false,reset_time_format:'automatic',show_usage_pace:false,claude_daily_pace_ring:false,show_codex_extra_limits:true},
    limits:{watch_limit:0.5,critical_limit:0.7},
    widgets:{system:true,calendar:true,weatherOn:true,todoOn:true,
    hidden:['system-gpu','widget-weather'], colors:{'system-cpu':'36a8eb','widget-weather':'00e5cc'},
    order:['system-cpu','codex','widget-calendar','system-memory','widget-stock:us:AAPL','widget-weather','system-gpu','widget-todo'],
    weatherCity:{id:1,name:'Seoul',latitude:37.56,longitude:126.97}}};
  window.fixture = JSON.parse(localStorage.getItem('settings-fixture') || 'null') || initial;
  window.calls = []; window.emitted = []; window.unmocked = []; window.failNextPrefs = false; window.failNextTransition = false; window.failNextDisplay = false; window.failNextLimits = false; window.failNextAutomatic = false;
  const events = new Map(), save = () => localStorage.setItem('settings-fixture', JSON.stringify(fixture));
  window.events = events;
  window.__TAURI__ = {core:{invoke:async(cmd,args={})=>{
    calls.push({cmd,args:structuredClone(args)});
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
      get_stock_settings:{enabled:false,symbols:[]},get_stock_credential_status:{toss:false,finnhub:false},load_stock_history:{version:1,trends:[],forecasts:[]}};
    if(!(cmd in replies)){unmocked.push(cmd);throw Error('Unmocked native call: '+cmd);}
    return structuredClone(replies[cmd]);
  }},event:{listen:async(name,fn)=>{events.set(name,fn);return()=>events.delete(name);},emit:async(name,payload)=>{emitted.push({name,payload});}},
  app:{getVersion:async()=>'settings QA'},window:{getCurrentWindow:()=>({close:async()=>{}})}};
}

(async()=>{
  const browser=await chromium.launch({headless:true});
  try {
    const context=await browser.newContext({viewport:{width:680,height:520}}),errors=[],external=[];
    await context.route('**/*',route=>{
      const url=new URL(route.request().url()),name=path.basename(url.pathname);
      if(url.hostname==='settings.test'&&['settings.html','stocks.js','stocks.css','krx-listed-companies.tsv'].includes(name))
        return route.fulfill({path:path.join(root,name),contentType:name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':'text/javascript'});
      external.push(url.href);return route.abort();
    });
    await context.addInitScript(mockIPC);
    const page=await context.newPage();
    page.on('pageerror',e=>errors.push(e.message));
    page.on('console',m=>{if(['error','warning'].includes(m.type()))errors.push(m.text());});
    await page.goto('http://settings.test/settings.html');
    await page.waitForSelector('#monitoring-box [data-hide="system-cpu"]',{state:'attached'});
    assert.equal(await page.title(),'PenguinNotch Settings');
    assert.equal(page.url(),'http://settings.test/settings.html');
    const tabs=['accounts','stocks','monitoring','widgets','appearance','general'];
    assert.deepEqual(await page.locator('[role=tab] > span:last-child').allTextContents(),['AI subscriptions','Stocks','Computer monitoring','Daily widgets','Appearance','General']);
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
    await page.waitForFunction(()=>document.activeElement&&document.activeElement.id==='stock-symbol');
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
