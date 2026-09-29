'use strict';
// Run with an already-installed Playwright on NODE_PATH. All IPC and asset requests are local mocks.
// Optional NOTCH_SCROLL_EVIDENCE names a directory for screenshots and the measured scroll ranges.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ui = path.join(__dirname, '../penguinnotch/ui');
const evidence = process.env.NOTCH_SCROLL_EVIDENCE;

function mockIPC(){
  window.calls=[]; window.events=new Map(); window.testSize=1;
  window.send=(name,payload)=>(events.get(name)||[]).forEach(fn=>fn({payload}));
  window.__TAURI__={core:{invoke:async(cmd,args)=>{
    calls.push({cmd,args});
    if(cmd==='report_dpr') return devicePixelRatio*testSize;
    const replies={get_theme_resolved:'dark',get_notch_edge:'right',get_notch_insets:[0,0,0,0],get_move_handle:true,
      get_ui_flags:{notch_visible:true,notch_on_hover:false},get_notch_meter_style:'ring',get_hover_text_scale:1,
      get_notch_slots:[],get_weekly_ring:'off',get_color_transition:'hard_step',
      get_usage_display:{shows_notch_readings:true,weekly_ring_dashed:false,weekly_reading:false,weekly_headline:false,reset_time_format:'automatic',show_usage_pace:false,claude_daily_pace_ring:false,show_codex_extra_limits:true},
      get_usage_limits:{watch_limit:0.5,critical_limit:0.7},
      get_opencode:{status:'absent'},get_state:{sessions:[],agg:'idle',lang_resolved:'en'},
      get_usage:{status:'ok',windows:[],fetched_at:0},get_codex:{status:'absent'},get_cursor:{status:'absent'},get_grok:{status:'absent'},get_glm:{status:'absent'},get_antigravity:{status:'absent'},
      get_activity:[],get_glyphs:{},get_stock_settings:{enabled:false,symbols:[]},get_stock_credential_status:{toss:false,finnhub:false},load_stock_history:{version:1,trends:[],forecasts:[]},
      get_update_state:{}};
    if(cmd==='stock_request') throw Error('Unexpected external request');
    return replies[cmd]??null;
  }},event:{listen:async(name,fn)=>{events.set(name,[...(events.get(name)||[]),fn]);return()=>{};},emit:async()=>{}}};
}
function seed(){
  window.clicks=0; window.savedOrders=[];
  stockStore.tick=async()=>{window.clicks++;}; stockStore.loadChart=async()=>{};
  stockStore.saveSettings=async value=>{savedOrders.push(value.symbols.map(s=>s.symbol));stockStore.settings=value;renderRing();return true;};
}
if(process.argv.includes('--serve')){
  // Same fixture in an ordinary browser for manual/CUA wheel QA; no Playwright required.
  const server=require('node:http').createServer((req,res)=>{
    const name=path.basename(new URL(req.url,'http://localhost').pathname)||'notch.html';
    if(!['notch.html','stocks.css','stocks.js','widgets.js'].includes(name)){res.writeHead(404);res.end();return;}
    let body=fs.readFileSync(path.join(ui,name),'utf8');
    if(name==='notch.html') body=body.replace('<head>',`<head><script>(${mockIPC.toString()})()</script>`).replace('</body>',`<script>
      addEventListener('load',()=>{
        (${seed.toString()})();
        const q=new URLSearchParams(location.search);
        testSize=Math.max(.75,Math.min(1.5,Number(q.get('size'))||1));
        const count=Math.max(1,Math.min(30,Number(q.get('count'))||30));
        stockStore.settings=PenguinNotchStocks.normalizeSettings({enabled:true,symbols:Array.from({length:count},(_,i)=>({symbol:'T'+String(i).padStart(2,'0'),market:'us',visible:true}))});
        applyEdge(q.get('edge'));applyMeterStyle(q.get('style'));reportDpr();
      });
      </script></body>`);
    res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':'text/javascript','Cache-Control':'no-store'});res.end(body);
  });
  server.listen(0,'127.0.0.1',()=>console.log(`Mock notch: http://127.0.0.1:${server.address().port}/notch.html?edge=right&style=ring&size=1&count=30`));
}else (async () => {
  const {chromium}=require('playwright');
  const browser = await chromium.launch({headless:true});
  try {
    const context = await browser.newContext({viewport:{width:480,height:640},deviceScaleFactor:1.5,reducedMotion:'reduce'});
    const errors = [], requests = [], ranges = [];
    await context.route('**/*', route => {
      const url = new URL(route.request().url()), name = path.basename(url.pathname);
      if(url.hostname==='notch.test' && ['notch.html','stocks.css','stocks.js','widgets.js'].includes(name))
        return route.fulfill({path:path.join(ui,name),contentType:name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':'text/javascript'});
      requests.push(url.href);
      return route.abort();
    });
    await context.addInitScript(mockIPC);
    const page = await context.newPage();
    page.on('pageerror', e=>errors.push(e.message));
    page.on('console', m=>{if(m.type()==='error'||m.type()==='warning')errors.push(m.text());});
    await page.goto('http://notch.test/notch.html');
    assert.equal(page.url(),'http://notch.test/notch.html');
    assert.equal(await page.title(),''); // The transparent native page deliberately has no title.
    await page.waitForFunction(()=>stockStore.settingsReady);
    await page.evaluate(seed);
    const configure = async (edge,size,style,count=30,work={width:900,height:640}) => {
      const vertical=edge==='left'||edge==='right';
      await page.mouse.move(0,0);
      await page.setViewportSize({width:Math.min(Math.round((vertical?480:650)*size),work.width),height:Math.min(Math.round((vertical?980:650)*size),work.height)});
      await page.evaluate(({edge,size,style,count})=>{
        testSize=size; send('pointer_left'); applyUiFlags({notch_on_hover:false});
        stockStore.settings=PenguinNotchStocks.normalizeSettings({enabled:true,symbols:Array.from({length:count},(_,i)=>({symbol:'T'+String(i).padStart(2,'0'),market:'us',visible:true}))});
        applyEdge(edge); applyMeterStyle(style); reportDpr(); cells.scrollTop=0;cells.scrollLeft=0;
      },{edge,size,style,count});
      await page.waitForFunction(size=>Math.abs((parseFloat(document.documentElement.style.zoom)||1)-size)<.021,size);
      // Flush ResizeObserver and the scroll event before collecting DOM geometry.
      await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
    };
    const measure = () => page.evaluate(()=>{
      const vertical=edgeIsVertical(), axis=vertical?'scrollTop':'scrollLeft';
      return {edge:notchEdge,style:meterStyle,size:testSize,viewport:[innerWidth,innerHeight],
        pill:pill.getBoundingClientRect().toJSON(),clip:cells.getBoundingClientRect().toJSON(),
        orb:orb.getBoundingClientRect().toJSON(),move:moveHandle.getBoundingClientRect().toJSON(),
        first:cells.firstElementChild.getBoundingClientRect().toJSON(),last:cells.lastElementChild.getBoundingClientRect().toJSON(),
        count:cells.children.length,axis,offset:cells[axis],cross:cells[vertical?'scrollLeft':'scrollTop'],
        extent:vertical?cells.clientHeight:cells.clientWidth,content:vertical?cells.scrollHeight:cells.scrollWidth,
        zoom:parseFloat(document.documentElement.style.zoom)||1};
    });
    const point = r=>({x:r.left+r.width/2,y:r.top+r.height/2});
    const hover = p=>page.mouse.move(p.x,p.y);
    const atEnd = () => page.waitForFunction(()=>edgeIsVertical()?Math.abs(cells.scrollTop-(cells.scrollHeight-cells.clientHeight))<=1:Math.abs(cells.scrollLeft-(cells.scrollWidth-cells.clientWidth))<=1);
    const atStart = () => page.waitForFunction(()=>edgeIsVertical()?cells.scrollTop===0:cells.scrollLeft===0);
    const checkPointer = p=>page.evaluate(p=>({id:cellAt(p.x,p.y),dom:document.elementFromPoint(p.x,p.y)?.closest('.cell')?.dataset.p||null,hover:hoverId,shown:card.classList.contains('show')}),p);
    const bridgeResults=[];
    for(const edge of ['left','right','top','bottom']){
      await configure(edge,1,'ring');
      const source=await page.locator('.cell .ringwrap').nth(2).boundingBox();
      const p={x:source.x+source.width/2,y:source.y+source.height/2};
      await hover(p);
      await page.waitForFunction(()=>card.classList.contains('show'));
      const route=await page.evaluate(p=>{
        const r=pill.getBoundingClientRect(),c=card.getBoundingClientRect();
        if(notchEdge==='left')return [{x:r.right-2,y:p.y},{x:(r.right+c.left)/2,y:p.y},{x:c.left+12,y:p.y}];
        if(notchEdge==='right')return [{x:r.left+2,y:p.y},{x:(r.left+c.right)/2,y:p.y},{x:c.right-12,y:p.y}];
        if(notchEdge==='top')return [{x:p.x,y:r.bottom-2},{x:p.x,y:(r.bottom+c.top)/2},{x:p.x,y:c.top+12}];
        return [{x:p.x,y:r.top+2},{x:p.x,y:(r.top+c.bottom)/2},{x:p.x,y:c.bottom-12}];
      },p);
      const result={edge};
      for(const [i,stage] of ['padding','bridge','card'].entries()){
        await hover(route[i]);
        // Cross padding within the 250 ms grace, then dwell beyond it in the bridge and card.
        await page.waitForTimeout(i===0?150:300);
        const state=await checkPointer(route[i]);
        assert.equal(state.id,null,`${edge}: ${stage} must not map to an invisible cell`);
        result[stage]=state.shown&&state.hover==='widget-stock:us:T02';
      }
      bridgeResults.push(result);
    }
    console.log('Hover bridge traversal: '+JSON.stringify(bridgeResults));
    if(evidence){fs.mkdirSync(evidence,{recursive:true});fs.writeFileSync(path.join(evidence,'hover-bridge.json'),JSON.stringify(bridgeResults,null,2));}
    assert.ok(bridgeResults.every(r=>r.padding&&r.bridge&&r.card),'slow cell -> padding -> bridge -> card keeps the same card open on all four edges');
    console.log('PASS slow real pointer traversal through padding/bridge/card on all four edges');
    const readingSnap=()=>page.evaluate(()=>{
      const cell=cells.firstElementChild, pct=cell&&cell.querySelector('.pct');
      const vertical=edgeIsVertical();
      return {pill:pill.getBoundingClientRect().toJSON(),cell:cell.getBoundingClientRect().toJSON(),
        pct:pct?getComputedStyle(pct).display:'none',
        content:vertical?cells.scrollHeight:cells.scrollWidth,
        extent:vertical?cells.clientHeight:cells.clientWidth,
        overflow:(vertical?cells.scrollHeight-cells.clientHeight:cells.scrollWidth-cells.clientWidth)>1,
        card:card.classList.contains('show'),hover:hoverId};
    });
    for(const edge of ['left','right','top','bottom']) for(const style of ['ring','bar']){
      await configure(edge,1,style,30);
      const p=await page.locator('.cell .ringwrap').nth(1).boundingBox();
      await hover({x:p.x+p.width/2,y:p.y+p.height/2});
      await page.waitForFunction(()=>card.classList.contains('show'));
      const before=await readingSnap();
      assert.equal(before.overflow,true,`${edge}/${style}/30 must overflow`);
      const hoverBefore=before.hover;
      await page.evaluate(()=>applyUsageDisplay({shows_notch_readings:false}));
      const after=await readingSnap();
      assert.equal(after.pct,'none',`${edge}/${style}/30: hiding readings removes reserved label space`);
      assert.ok(after.cell.height<before.cell.height-4,`${edge}/${style}/30: per-cell extent shrinks ${JSON.stringify({before:before.cell,after:after.cell})}`);
      const vertical=edge==='left'||edge==='right';
      if(vertical){
        assert.ok(after.content<before.content,`${edge}/${style}/30: scroll content shortens`);
        assert.ok(Math.abs(after.pill.height-before.pill.height)<1,`${edge}/${style}/30: capped stack viewport is kept ${JSON.stringify({before:before.pill,after:after.pill})}`);
        assert.equal(after.overflow,true,`${edge}/${style}/30: the list still overflows`);
      }else{
        assert.ok(after.pill.height<before.pill.height-4,`${edge}/${style}/30: depth shrinks when labels leave`);
      }
      assert.equal(after.card,true,`${edge}/${style}/30: hiding readings keeps hover content`);
      assert.equal(after.hover,hoverBefore,`${edge}/${style}/30: hover target is unchanged`);
      await page.evaluate(()=>applyUsageDisplay({shows_notch_readings:true}));

      await configure(edge,1,style,2);
      const shortBefore=await readingSnap();
      assert.equal(shortBefore.overflow,false,`${edge}/${style}/2 fits without scrolling`);
      await page.evaluate(()=>applyUsageDisplay({shows_notch_readings:false}));
      const shortAfter=await readingSnap();
      assert.equal(shortAfter.pct,'none',`${edge}/${style}/2: labels leave the layout`);
      assert.ok(shortAfter.cell.height<shortBefore.cell.height-4,`${edge}/${style}/2: per-cell extent shrinks`);
      if(vertical){
        assert.ok(shortAfter.pill.height<shortBefore.pill.height-4,`${edge}/${style}/2: un-capped pill shortens ${JSON.stringify({before:shortBefore.pill,after:shortAfter.pill})}`);
      }else{
        assert.ok(shortAfter.pill.height<shortBefore.pill.height-4,`${edge}/${style}/2: depth shrinks`);
      }
      await page.evaluate(()=>applyUsageDisplay({shows_notch_readings:true}));
    }
    console.log('PASS hiding readings reduces per-cell extent; long lists keep a capped viewport; short lists shrink');
    await page.evaluate(()=>{
      stockStore.settings=PenguinNotchStocks.normalizeSettings({enabled:false,symbols:[]});
      usage={status:'ok',windows:[
        {id:'session',used:0.3,duration:18000,resets_at:Date.now()+36e5},
        {id:'weekly_all',used:0.6,duration:604800,resets_at:Date.now()+36e5}
      ],fetched_at:Date.now()};
      notchSlots=[{provider:'claude'}];
      weeklyRing='outside';
      usageDisplay=Object.assign(defaultUsageDisplay(),{weekly_ring_dashed:true});
      applyMeterStyle('ring');
      applyEdge('right');
      renderRing();
    });
    assert.equal(await page.evaluate(()=>meterStyle),'ring');
    assert.equal(await page.evaluate(()=>notchEdge),'right');
    const dashed=await page.evaluate(()=>{
      const mark=document.querySelector('svg.ring .weekly-dash, svg.ring path.weekly-dash, svg.ring circle.weekly-dash');
      const markup=document.querySelector('svg.ring')?document.querySelector('svg.ring').innerHTML:'';
      const dashCount=(markup.match(/stroke-dasharray=/g)||[]).length;
      const used=mark&&mark.getAttribute('stroke-dasharray');
      const dup=/\sstroke-dasharray="[^"]*"\s[^>]*stroke-dasharray=/.test(markup);
      const length=mark&&mark.tagName==='path'?mark.getTotalLength():null;
      const C=2*Math.PI*31;
      return {used,dup,dashCount,tag:mark&&mark.tagName,length,circle:C,computed:mark?getComputedStyle(mark).strokeDasharray:null};
    });
    assert.equal(dashed.dup,false,'used arc must not carry two stroke-dasharray attributes');
    assert.match(String(dashed.used||dashed.computed),/4/);
    if(dashed.tag==='path') assert.ok(dashed.length>0 && dashed.length<dashed.circle-1,'dashed amount is not a full circle');
    await page.evaluate(()=>{usageDisplay.weekly_ring_dashed=false;weeklyRing='inside';renderRing();});
    const solid=await page.evaluate(()=>!!document.querySelector('svg.ring .weekly-dash'));
    assert.equal(solid,false,'turning the dash off removes the dashed used arc');
    await page.evaluate(()=>{usageDisplay.weekly_ring_dashed=true;renderRing();});
    const inside=await page.evaluate(()=>{
      const mark=document.querySelector('svg.ring .weekly-dash');
      return mark&&(mark.getAttribute('r')||(mark.getAttribute('d')||'').includes('A 16 '));
    });
    assert.ok(inside,'inside placement still dashes the used arc');
    console.log('PASS dashed weekly ring has a single dasharray and a partial used arc');
    const pairMeasure=()=>page.evaluate(()=>{
      const pillBox=pill.getBoundingClientRect(), pct=document.querySelector('.cell[data-p="claude"] .pct');
      const ring=document.querySelector('.cell[data-p="claude"] .ringwrap');
      if(!pct||!ring) return null;
      const p=pct.getBoundingClientRect(), r=ring.getBoundingClientRect();
      const range=document.createRange(); range.selectNodeContents(pct);
      const ink=range.getBoundingClientRect();
      return {text:pct.textContent,pair:pct.classList.contains('pair'),font:parseFloat(getComputedStyle(pct).fontSize),
        height:p.height,pill:pillBox,pct:p,ring:r,view:[innerWidth,innerHeight],edge:notchEdge,style:meterStyle,
        scroll:pct.scrollWidth,client:pct.clientWidth,ink};
    });
    for(const edge of ['left','right','top','bottom']) for(const style of ['ring','bar']) for(const size of [.75,1,1.5]) for(const pair of [[1,1],[1,0.5]]){
      await configure(edge,size,style,0);
      await page.evaluate(({used,week})=>{
        stockStore.settings=PenguinNotchStocks.normalizeSettings({enabled:false,symbols:[]});
        usage={status:'ok',windows:[
          {id:'session',used,duration:18000,resets_at:Date.now()+36e5},
          {id:'weekly_all',used:week,duration:604800,resets_at:Date.now()+36e5}
        ],fetched_at:Date.now()};
        notchSlots=[{provider:'claude'}];
        weeklyRing='outside';
        usageDisplay=Object.assign(defaultUsageDisplay(),{weekly_reading:true});
        renderRing();
      },{used:pair[0],week:pair[1]});
      const g=await pairMeasure();
      assert.ok(g,`${edge}/${style}/${size} ${pair.join('/')} rendered`);
      assert.equal(g.pair,true,`${edge}/${style}/${size} uses the pair class`);
      assert.ok(g.font<14.5,`${edge}/${style}/${size} pair type is smaller than the single reading`);
      assert.equal(g.text,`${Math.round(pair[0]*100)}%/${Math.round(pair[1]*100)}%`);
      assert.ok(g.scroll<=g.client+0.6,`${edge}/${style}/${size} full pair text fits its box ${JSON.stringify(g)}`);
      assert.ok(g.ink.width<=g.pct.width+0.6&&g.ink.left>=g.pct.left-0.6&&g.ink.right<=g.pct.right+0.6,`${edge}/${style}/${size} glyph range stays in the label`);
      assert.ok(g.pct.left>=g.pill.left-0.6&&g.pct.right<=g.pill.right+0.6,`${edge}/${style}/${size} pair stays in the pill ${JSON.stringify(g)}`);
      assert.ok(g.pct.left>=-0.6&&g.pct.right<=g.view[0]+0.6&&g.pct.top>=-0.6&&g.pct.bottom<=g.view[1]+0.6,`${edge}/${style}/${size} pair stays in the window`);
      assert.ok(g.pct.top>=g.ring.bottom-1||g.pct.bottom<=g.ring.top+1||(g.pct.left>=g.ring.right-1||g.pct.right<=g.ring.left+1),`${edge}/${style}/${size} pair does not cover the ring`);
    }
    await configure('right',1,'ring',0);
    await page.evaluate(()=>{
      stockStore.settings=PenguinNotchStocks.normalizeSettings({enabled:false,symbols:[]});
      usage={status:'ok',windows:[{id:'session',used:1,duration:18000,resets_at:Date.now()+36e5}],fetched_at:Date.now()};
      notchSlots=[{provider:'claude'}]; weeklyRing='off';
      usageDisplay=defaultUsageDisplay(); renderRing();
    });
    const single=await pairMeasure();
    assert.equal(single.pair,false);
    assert.equal(single.text,'100%');
    assert.ok(single.font>=14.5,'a single reading keeps the larger type');
    console.log('PASS paired readings stay inside the pill on all edges');
    await page.evaluate(()=>{
      usage={status:'ok',windows:[],fetched_at:0}; notchSlots=[]; weeklyRing='off';
      usageDisplay=defaultUsageDisplay(); renderRing();
    });
    let cases=0;
    for(const edge of ['left','right','top','bottom']) for(const style of ['ring','bar']) for(const size of [.75,.8,1,1.137,1.25,1.5]) {
      await configure(edge,size,style);
      const start=await measure(), vertical=edge==='left'||edge==='right';
      assert.equal(start.count,30);
      assert.ok(start.content>start.extent,'fixture must overflow');
      for(const [name,r] of [['pill',start.pill],['orb',start.orb],['move',start.move]])
        assert.ok(r.left>=-.05&&r.top>=-.05&&r.right<=start.viewport[0]+.05&&r.bottom<=start.viewport[1]+.05,`${edge}/${size} ${name} outside window: ${JSON.stringify(start)}`);
      assert.ok(start.clip.left>=start.pill.left&&start.clip.top>=start.pill.top&&start.clip.right<=start.pill.right&&start.clip.bottom<=start.pill.bottom,'scroll viewport stays in body');
      const p=point(start.first);
      await hover(p);
      await page.mouse.wheel(0,100000); // Ordinary vertical wheel must also work on top/bottom.
      await atEnd();
      const end=await measure();
      assert.equal(end.cross,0);
      assert.deepEqual(end.pill,start.pill,'scroll must not shift the body');
      assert.ok(vertical?end.last.top>=end.clip.top-1&&end.last.bottom<=end.clip.bottom+1:end.last.left>=end.clip.left-1&&end.last.right<=end.clip.right+1,'last cell fully reachable');
      const mapping=await checkPointer(p);
      assert.equal(mapping.dom,mapping.id,'real DOM and geometric pointer mapping agree after wheel');
      if(mapping.id)assert.equal(mapping.hover,mapping.id,'stationary hover follows scrolled cell');
      else assert.equal(mapping.shown,false,'no stale hover in clipped gap');
      const last=point(end.last);
      await hover(last);
      assert.equal((await checkPointer(last)).id,'widget-stock:us:T29');
      const clicks=await page.evaluate(()=>window.clicks);
      await page.mouse.click(last.x,last.y);
      assert.ok(await page.evaluate(n=>window.clicks>n,clicks),'last cell click keeps its action');
      await page.mouse.wheel(0,100000); await atEnd();
      assert.equal((await measure()).offset,end.offset,'outward end boundary');
      await page.mouse.wheel(0,-100000); await atStart();
      await page.mouse.wheel(0,-100000); await atStart();
      assert.equal((await measure()).offset,0,'outward start boundary');
      await hover(point((await measure()).first));
      await page.mouse.wheel(100000,0); await atEnd(); // Horizontal trackpad motion.
      ranges.push({edge,style,size,viewport:start.viewport,extent:start.extent,content:start.content,range:[0,end.offset]});
      cases++;
    }
    console.log(`PASS ${cases} real Chromium layouts: four edges, ring/bar, 75–150%, work-area cap, handles, last item, both wheel axes, boundaries and pointer mapping`);

    for(const edge of ['left','right','top','bottom']) {
      await configure(edge,1,'ring');
      // Put the first cell just outside the scrollport but inside the pill padding.
      const data=await page.evaluate(()=>{
        const vertical=edgeIsVertical(),v=cells.getBoundingClientRect(),r=cells.firstElementChild.getBoundingClientRect();
        cells[vertical?'scrollTop':'scrollLeft']=(vertical?r.bottom-v.top:r.right-v.left)+2;
        const hidden=cells.firstElementChild.getBoundingClientRect(),source=cells.children[2].getBoundingClientRect();
        return {outside:{x:vertical?hidden.left+hidden.width/2:hidden.right-1,y:vertical?hidden.bottom-1:hidden.top+hidden.height/2},source:{x:source.left+source.width/2,y:source.top+source.height/2}};
      });
      assert.equal((await checkPointer(data.outside)).dom,null,'clipped DOM cell cannot be a drag target');
      assert.equal((await checkPointer(data.outside)).id,null,'clipped cell cannot be a hover/click target');
      const saved=await page.evaluate(()=>savedOrders.length);
      await hover(data.source); await page.mouse.down(); await hover(data.outside); await page.mouse.up();
      assert.equal(await page.evaluate(()=>savedOrders.length),saved,'dropping in clipped padding never reorders an invisible cell');
      await page.mouse.click(data.outside.x,data.outside.y);
      assert.equal((await checkPointer(data.outside)).shown,false,'padding does not reuse a stale card');
      const targets=await page.evaluate(()=>[2,3].map(i=>{const r=cells.children[i].getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2};}));
      await hover(targets[0]); await page.mouse.down(); await hover(targets[1]); await page.mouse.up();
      assert.equal(await page.evaluate(()=>savedOrders.length),saved+1,'visible reorder still commits');
      await page.keyboard.down('Alt'); await hover(targets[0]); await page.mouse.down(); await hover(targets[1]); await page.mouse.up(); await page.keyboard.up('Alt');
      assert.ok(await page.evaluate(()=>calls.some(c=>c.cmd==='drag_begin')),'Alt drag keeps the native movement path');
      assert.equal(await page.evaluate(()=>savedOrders.length),saved+1,'Alt drag does not reorder');
      await page.evaluate(()=>send('drag_end'));
      const beforeFold=(await measure()).offset;
      await page.mouse.move(0,0);
      await page.evaluate(()=>{applyUiFlags({notch_on_hover:true});send('notch_pointer',false);});
      await page.waitForFunction(()=>folded);
      const probe=await page.evaluate(()=>calls.filter(c=>c.cmd==='set_hot').at(-1).args.probe);
      assert.equal(probe.length,4,'folded pill reports a physical screen probe');
      assert.ok(probe.every(Number.isFinite)&&probe[2]>0&&probe[3]>0);
      await page.evaluate(()=>pill.dispatchEvent(new WheelEvent('wheel',{deltaY:100,bubbles:true,cancelable:true})));
      assert.equal((await measure()).offset,beforeFold,'folded wheel cannot move the hidden list');
      await page.evaluate(()=>send('notch_pointer',true));
      await page.waitForFunction(()=>!folded);
      assert.equal(await page.evaluate(()=>calls.filter(c=>c.cmd==='set_hot').at(-1).args.probe??null),null,'unfolding stops backdrop sampling');
      assert.equal((await measure()).offset,beforeFold,'folding retains scroll position');
    }
    console.log('PASS real pointer clicks, clipped drop cancellation, visible reorder, Alt move and fold/unfold on every edge');

    for(const edge of ['left','right','top','bottom']) for(const size of [.75,1,1.5]) {
      await configure(edge,size,'bar',3,{width:2000,height:2000});
      const before=await measure();
      assert.ok(before.content<=before.extent,'short list fits');
      await hover(point(before.first));await page.mouse.wheel(100,100);
      await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
      assert.deepEqual(await measure(),before,'no overflow means no layout or scroll shift');
    }
    console.log('PASS no-overflow geometry and scroll stability at 75%, 100%, 150% on all edges');

    // The newly merged provider and appearance events redraw the actual ring and its open card.
    await configure('right',1,'ring',1);
    await page.evaluate(()=>{
      stockStore.settings.enabled=false;
      send('notch_slots',[{provider:'opencode'}]);
      send('opencode',{status:'ok',windows:[{id:'rolling',label:'5-hour Limit',used:.25},{id:'weekly',label:'Weekly limit',used:.6}],fetched_at:Date.now()});
      send('weekly_ring','inside');
      send('color_transition','hard_step');
    });
    await page.locator('[data-p="opencode"] .ringwrap').hover();
    await page.waitForFunction(()=>card.classList.contains('show')&&hoverId==='opencode');
    assert.equal(await page.locator('[data-p="opencode"] .pct').textContent(),'25%');
    for(const theme of ['dark','light']){
      await page.evaluate(theme=>send('theme_resolved',theme),theme);
      for(const style of ['hard_step','ramp']){
        await page.evaluate(style=>send('color_transition',style),style);
        const colors=await page.evaluate(()=>{
          const normalized=document.createElement('span');normalized.style.color=tone(.25);
          return {ring:document.querySelector('[data-p="opencode"] .reading circle').getAttribute('stroke'),
            card:document.querySelector('#card .w-fill').style.backgroundColor,expected:normalized.style.color,tone:tone(.25)};
        });
        assert.equal(colors.ring,colors.tone,`${theme} ${style} ring`);
        assert.equal(colors.card,colors.expected,`${theme} ${style} open card redraws with ring`);
      }
    }
    await page.mouse.move(0,0);
    await page.evaluate(()=>{applyUiFlags({notch_on_hover:true});send('notch_pointer',false);});
    await page.waitForFunction(()=>folded);
    for(const [behind,color] of [['dark','rgb(245, 245, 247)'],['light','rgb(0, 0, 0)'],['off','rgb(245, 245, 247)']]){
      await page.evaluate(behind=>send('pill_backdrop',behind),behind);
      await page.waitForFunction(color=>getComputedStyle(document.getElementById('rest')).backgroundColor===color,color);
    }
    assert.equal(await page.locator('body').getAttribute('data-behind'),null,'off restores the selected theme');
    console.log('PASS OpenCode rolling/weekly rendering, live dark/light color transitions in the open card, folded probe lifecycle and adaptive pill opt-out');
    assert.deepEqual(errors,[],'no console warnings/errors or page exceptions');
    assert.deepEqual(requests,[],'no non-fixture network requests');
    assert.equal(await page.evaluate(()=>calls.some(c=>c.cmd==='stock_request')),false,'no account or market calls');
    if(evidence){
      fs.mkdirSync(evidence,{recursive:true});
      fs.writeFileSync(path.join(evidence,'ranges.json'),JSON.stringify(ranges,null,2));
      for(const edge of ['right','top']){
        await configure(edge,1,'ring');await hover(point((await measure()).first));await page.mouse.wheel(0,100000);await atEnd();
        await page.screenshot({path:path.join(evidence,edge+'.png')});
      }
    }
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
