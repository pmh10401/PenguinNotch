'use strict';
// Run with an installed Playwright on NODE_PATH. Native calls use public synthetic fixtures only.
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const {chromium} = require('playwright');
const root = path.join(__dirname, '../penguinnotch/ui');

function mockIPC() {
  const initial = {lang:'en', weekly:'inside', slots:[], flags:{notch_visible:true,notch_on_hover:true,tray_visible:true}, widgets:{system:true,calendar:true,weatherOn:true,todoOn:true,
    hidden:['system-gpu','widget-weather'], colors:{'system-cpu':'36a8eb','widget-weather':'00e5cc'},
    order:['system-cpu','codex','widget-calendar','system-memory','widget-stock:us:AAPL','widget-weather','system-gpu','widget-todo'],
    weatherCity:{id:1,name:'Seoul',latitude:37.56,longitude:126.97}}};
  window.fixture = JSON.parse(localStorage.getItem('settings-fixture') || 'null') || initial;
  window.calls = []; window.emitted = []; window.failNextPrefs = false;
  const events = new Map(), save = () => localStorage.setItem('settings-fixture', JSON.stringify(fixture));
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
    if(cmd==='set_ui_flags'){
      fixture.flags={notch_visible:args.notchVisible,notch_on_hover:args.notchOnHover,tray_visible:args.trayVisible||!args.notchVisible};
      save();return fixture.flags;
    }
    if(cmd==='set_notch_slots'){fixture.slots=args.slots;save();return args.slots;}
    if(cmd==='search_weather_cities')return [{id:2,name:'Hwaseong',admin1:'Gyeonggi',country:'South Korea',latitude:37.2,longitude:126.8}];
    if(cmd==='set_weather_city'){fixture.widgets.weatherCity=args.city;save();return null;}
    const flags=fixture.flags;
    const replies={get_lang:fixture.lang,get_lang_resolved:fixture.lang,get_system_look:{mica:false},get_theme:'dark',get_theme_resolved:'dark',
      get_notch_size_prefs:{preset:1,custom:1,uses_custom:false},get_scale:1,get_notch_edge:'right',get_notch_meter_style:'ring',get_hover_text_scale:1,
      get_monitors:[],get_weekly_ring:fixture.weekly,get_ui_flags:flags,show_notch_now:flags,get_move_handle:true,
      get_autostart:false,get_hooks_installed:false,get_glyphs:{},get_notch_slots:fixture.slots,
      get_tray_options:[{id:'claude',label:'Claude',status:'ok',used:0.25},{id:'codex',label:'Codex',status:'ok',used:0.5}],
      get_antigravity_prefs:{limit:'automatic',model:'gemini'},get_widget_prefs:fixture.widgets,
      get_update_state:{available:null,checking:false,installing:false,message:null},
      get_stock_settings:{enabled:false,symbols:[]},get_stock_credential_status:{toss:false,finnhub:false},load_stock_history:{version:1,trends:[],forecasts:[]}};
    if(!(cmd in replies))throw Error('Unmocked native call: '+cmd);
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
    await page.keyboard.press('ArrowDown');await page.keyboard.press('ArrowDown');
    assert.equal(await page.locator('#tab-monitoring').getAttribute('aria-selected'),'true');
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
    assert.equal(await page.locator('#seg-weekly').isVisible(),true);
    await page.locator('#seg-weekly [data-v="outside"]').click();
    await page.waitForFunction(()=>fixture.weekly==='outside');
    await page.locator('#tab-general').click();
    assert.equal(await page.locator('#seg-tray').isVisible(),true);
    await page.locator('#seg-tray [data-v="none"]').click();
    await page.waitForFunction(()=>fixture.flags.tray_visible===false);
    assert.equal(await page.evaluate(()=>fixture.flags.notch_visible),true);
    await page.locator('#lang').selectOption('ko');
    assert.deepEqual(await page.locator('[role=tab] > span:last-child').allTextContents(),['AI 구독','주식','컴퓨터 모니터링','생활 위젯','모양','일반']);
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
        if(evidence&&size.width===680&&theme==='dark'&&['monitoring','widgets'].includes(tab))await page.screenshot({path:path.join(evidence,tab+'-ko.png')});
      }
    }
    assert.deepEqual(errors,[]);assert.deepEqual(external,[]);
    console.log('PASS: six macOS-aligned sections, English/Korean, keyboard and saved tabs, independent hardware/widgets, legacy visibility, scoped order/color, city search, failed-save preservation, stock view events, persistence and 24 layout checks; no console errors or external requests');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
