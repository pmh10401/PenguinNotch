'use strict';
// Offline Playwright fixture for the notch update card. No network.
const assert = require('node:assert/strict');
const path = require('node:path');
const {chromium} = require('playwright');
const ui = path.join(__dirname, '../penguinnotch/ui');

function mockIPC(){
  window.calls=[]; window.events=new Map();
  window.send=(name,payload)=>(events.get(name)||[]).forEach(fn=>fn({payload}));
  window.update={available:null,checking:false,installing:false,message:null,downloaded:null,total:null,deferred:false,preview:false};
  window.__TAURI__={core:{invoke:async(cmd,args)=>{
    calls.push({cmd,args});
    if(cmd==='report_dpr') return devicePixelRatio;
    if(cmd==='preview_update'){
      update={available:'1.22.0',checking:false,installing:false,message:null,downloaded:null,total:null,deferred:false,preview:true};
      send('update_state',update); return null;
    }
    if(cmd==='dismiss_update'){
      if(update.available){update={...update,deferred:true,installing:false}; send('update_state',update);}
      return null;
    }
    if(cmd==='install_update'){
      if(update.preview) throw Error('preview must not install');
      await new Promise(resolve=>{ window.holdInstall=()=>{ window.holdInstall=null; resolve(); }; });
      update={...update,installing:true,deferred:false,downloaded:0,total:200,message:null};
      send('update_state',update);
      update={...update,downloaded:100,total:200};
      send('update_state',update);
      return null;
    }
    if(cmd==='reoffer_update'){
      if(update.available){update={...update,deferred:false}; send('update_state',update);}
      return null;
    }
    const replies={get_theme_resolved:'dark',get_notch_edge:'right',get_notch_insets:[0,0,0,0],get_move_handle:true,
      get_ui_flags:{notch_visible:true,notch_on_hover:true},get_notch_meter_style:'ring',get_hover_text_scale:1,
      get_notch_slots:[{provider:'claude'}],get_weekly_ring:'off',get_color_transition:'hard_step',
      get_usage_display:{shows_notch_readings:true,weekly_ring_dashed:false,weekly_reading:false,weekly_headline:false,reset_time_format:'automatic',show_usage_pace:false,claude_daily_pace_ring:false,show_codex_extra_limits:true},
      get_usage_limits:{watch_limit:0.5,critical_limit:0.7},
      get_opencode:{status:'absent'},get_state:{sessions:[],agg:'idle',lang_resolved:'en'},
      get_usage:{status:'ok',windows:[{id:'session',used:0.2,duration:18000,resets_at:Date.now()+8e6}],fetched_at:Date.now()},
      get_codex:{status:'absent'},get_cursor:{status:'absent'},get_grok:{status:'absent'},get_glm:{status:'absent'},get_antigravity:{status:'absent'},
      get_activity:[],get_glyphs:{},get_stock_settings:{enabled:false,symbols:[]},get_stock_credential_status:{toss:false,finnhub:false},
      load_stock_history:{version:1,trends:[],forecasts:[]},get_update_state:update,show_notch_now:null};
    if(cmd==='stock_request') throw Error('Unexpected external request');
    if(cmd==='set_hot') return null;
    return replies[cmd]??null;
  }},event:{listen:async(name,fn)=>{events.set(name,[...(events.get(name)||[]),fn]);return()=>{};},emit:async()=>{}}};
}

(async()=>{
  const browser=await chromium.launch({headless:true});
  try{
    const context=await browser.newContext({viewport:{width:480,height:640}});
    const errors=[];
    await context.route('**/*',route=>{
      const url=new URL(route.request().url()), name=path.basename(url.pathname);
      if(url.hostname==='notch.test'&&['notch.html','stocks.css','stocks.js','widgets.js'].includes(name))
        return route.fulfill({path:path.join(ui,name),contentType:name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':'text/javascript'});
      return route.abort();
    });
    await context.addInitScript(mockIPC);
    const page=await context.newPage();
    page.on('pageerror',e=>errors.push(e.message));
    await page.goto('http://notch.test/notch.html');
    await page.waitForFunction(()=>typeof applyUpdateState==='function');
    assert.equal(await page.locator('#update-card.show').count(),0,'empty update state does not open a card');

    await page.evaluate(()=>invoke('preview_update'));
    await page.waitForFunction(()=>updateCard.classList.contains('show'));
    assert.match(await page.locator('#update-card').innerText(),/preview/i);
    await page.locator('#upd-install').click();
    await page.waitForFunction(()=>calls.filter(c=>c.cmd==='install_update').length===0);
    await page.waitForFunction(()=>updateOffer&&updateOffer.installing);
    const previewPct=await page.evaluate(()=>document.querySelector('#update-card .u-fill').style.width);
    assert.ok(!/NaN/.test(previewPct),'preview progress is not NaN');
    await page.waitForFunction(()=>calls.some(c=>c.cmd==='dismiss_update'));

    await page.evaluate(()=>{update={available:'1.22.0',checking:false,installing:false,message:null,downloaded:null,total:null,deferred:false,preview:false};send('update_state',update);});
    await page.waitForFunction(()=>updateCard.classList.contains('show')&&updateOffer&&!updateOffer.preview);
    await page.locator('#upd-later').click();
    await page.waitForFunction(()=>calls.some(c=>c.cmd==='dismiss_update')&&updateOffer.deferred);
    await page.waitForFunction(()=>!updateCard.classList.contains('show'));

    await page.evaluate(()=>invoke('reoffer_update'));
    await page.waitForFunction(()=>updateCard.classList.contains('show'));
    assert.equal(await page.locator('#update-card').getAttribute('aria-modal'),null);
    await page.locator('#upd-later').focus();
    await page.evaluate(()=>send('update_state',update));
    assert.equal(await page.evaluate(()=>document.activeElement&&document.activeElement.id),'upd-later');
    const installsBefore=await page.evaluate(()=>calls.filter(c=>c.cmd==='install_update').length);
    await page.evaluate(()=>{update={...update,checking:true,installing:false};send('update_state',update);});
    await page.waitForFunction(()=>updateOffer&&updateOffer.checking);
    assert.equal(await page.locator('#upd-install').isDisabled(),true);
    assert.equal(await page.locator('#upd-later').isDisabled(),true);
    assert.match(await page.locator('#update-card').innerText(),/Checking/);
    await page.locator('#upd-install').click({force:true});
    await page.locator('#upd-install').click({force:true});
    assert.equal(await page.evaluate(()=>calls.filter(c=>c.cmd==='install_update').length),installsBefore,'checking swallows Update');
    await page.evaluate(()=>{update={...update,checking:false};send('update_state',update);});
    await page.waitForFunction(()=>updateOffer&&!updateOffer.checking);
    await page.locator('#upd-install').click();
    await page.waitForFunction(()=>typeof holdInstall==='function');
    await page.locator('#upd-install').click();
    assert.equal(await page.evaluate(()=>calls.filter(c=>c.cmd==='install_update').length),installsBefore+1,'two Update presses before the native event are one invoke');
    assert.equal(await page.evaluate(()=>!!document.getElementById('upd-install')),true,'the button remains until installing arrives');
    await page.evaluate(()=>holdInstall());
    await page.waitForFunction(()=>updateOffer&&updateOffer.installing);
    const bar=await page.evaluate(()=>{
      const fill=document.querySelector('#update-card .u-fill');
      const now=document.querySelector('#update-card [role=progressbar]').getAttribute('aria-valuenow');
      return {width:fill&&fill.style.width,now};
    });
    assert.ok(!/NaN/.test(String(bar.width)+String(bar.now)),'install progress is not NaN');

    await page.evaluate(()=>{update={available:'1.22.0',checking:false,installing:false,message:'Could not install the update',downloaded:null,total:null,deferred:false,preview:false};send('update_state',update);});
    await page.waitForFunction(()=>updateCard.classList.contains('show'));
    assert.match(await page.locator('#update-card').innerText(),/Could not install the update/);

    await page.evaluate(()=>applyHoverTextScale(1.5));
    for(const edge of ['left','right','top','bottom']) for(const style of ['ring','bar']){
      const actual=await page.evaluate(({edge,style})=>{applyEdge(edge);applyMeterStyle(style);placeUpdateCard();return {edge:notchEdge,style:meterStyle};},{edge,style});
      assert.equal(actual.edge,edge,`${edge}/${style} applyEdge must keep that edge`);
      assert.equal(actual.style,style);
      const box=await page.locator('#update-card').boundingBox();
      const view=page.viewportSize();
      assert.ok(box&&box.x>=-1&&box.y>=-1&&box.x+box.width<=view.width+1&&box.y+box.height<=view.height+1,`${edge}/${style} card stays in the window ${JSON.stringify(box)}`);
    }

    await page.keyboard.press('Escape');
    await page.waitForFunction(()=>calls.filter(c=>c.cmd==='dismiss_update').length>=2);

    await page.evaluate(()=>setUiLanguage('ko'));
    await page.evaluate(()=>{update={available:'1.22.0',checking:false,installing:false,message:null,downloaded:null,total:null,deferred:false,preview:false};send('update_state',update);});
    await page.waitForFunction(()=>updateCard.classList.contains('show'));
    assert.match(await page.locator('#upd-later').innerText(),/나중에/);
    assert.match(await page.locator('#upd-install').innerText(),/업데이트/);

    assert.deepEqual(errors,[]);
    console.log('PASS update card preview/later/reoffer/install-once/progress/edges/escape/Korean');
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
