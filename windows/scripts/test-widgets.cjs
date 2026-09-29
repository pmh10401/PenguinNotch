const assert = require('node:assert/strict');
const path = require('node:path');
require(path.join(__dirname, '../penguinnotch/ui/widgets.js'));
const W = globalThis.PenguinNotchWidgets;

assert.equal(W.formatRate(0, false), '0B/s');
assert.equal(W.formatRate(1500000, true), '1.5M/s');
assert.equal(W.formatRate(1200000, false), '1.2MB/s');
assert.equal(W.formatRate(300000, false), '300KB/s');
assert.equal(W.dayDistance(0), 'Today');
assert.equal(W.dayDistance(1), 'In 1 day');
assert.equal(W.dayDistance(-1), '1 day ago');
assert.equal(W.dayDistance(3), 'In 3 days');
assert.equal(W.condition(61), 'Rain');
assert.equal(W.t('ko', 'Calendar'), '달력');
assert.equal(W.t('ko', 'Refresh'), '새로고침');
assert.equal(W.t('fr', 'Calendar'), 'Calendar');

const month = W.calendarMonth(new Date(2026, 1, 15), 0, 0);
assert.equal(month.days.length, 42);
assert.equal(month.start.getMonth(), 1);
assert.equal(month.days[0].getDay(), 0);

const payload = {
  system: true, calendar: true, weatherOn: true, todoOn: true,
  hidden: ['system-gpu'], order: ['widget-todo', 'system-cpu'],
  colors: { 'system-cpu': 'b026ff' },
  cpu: 0.2, memoryUsed: 4, memoryTotal: 8,
  diskUsed: 1, diskTotal: 2, diskAvailable: 1,
  netDown: 1200000, netUp: 300000, link: 'wired', linkName: 'Ethernet',
  battery: 0.8, batteryState: 'charging', watts: null,
  weather: null, weatherCity: null, todos: [{ id: 'a', title: 'keep', done: false }]
};
const cells = W.arrange(W.extraCells(payload, 'en').concat([{ id: 'codex', base: 'codex' }]), payload.order);
assert.equal(cells[0].id, 'widget-todo');
assert.equal(cells[1].id, 'system-cpu');
assert.equal(cells.find(cell => cell.id === 'system-gpu'), undefined);
assert.equal(cells.find(cell => cell.id === 'system-cpu').meter.color, '#b026ff');
assert.equal(cells.find(cell => cell.id === 'system-cpu').meter.text, '20%');
assert.equal(cells.find(cell => cell.id === 'system-network').meter.text, '1.5M/s');
assert.equal(cells.find(cell => cell.id === 'system-network').meter.fraction, 1);
assert.equal(cells.find(cell => cell.id === 'system-network').meter.invert, true);
assert.equal(cells.find(cell => cell.id === 'system-battery').meter.text, '80% ⚡');
assert.equal(cells.find(cell => cell.id === 'widget-todo').meter.text, '0/1');
assert.equal(cells.find(cell => cell.id === 'codex').id, 'codex');

const disk = cells.find(cell => cell.id === 'system-disk').meter;
assert.equal(disk.text, '50%');
assert.deepEqual(disk.rows.map(row => [row.label, row.detail]), [
  ['Home volume', '1 B / 2 B'], ['Available for files', '1 B']
]);
const volumes = [
  { id: 'system', name: 'System', mountPoints: ['C:\\'], used: 200e9, total: 500e9, available: 250e9 },
  { id: 'data', name: '자료 <backup>', mountPoints: ['D:\\', 'C:\\Mount\\자료\\'], used: 800e9, total: 1e12, available: 200e9 }
];
const multi = { system: true, diskUsed: 1e12, diskTotal: 1.5e12, diskAvailable: 450e9, volumes };
const diskCell = (value, lang = 'en') => W.extraCells(value, lang).find(cell => cell.id === 'system-disk');
const aggregate = diskCell(multi).meter;
assert.equal(aggregate.text, '67%', 'aggregate is weighted by capacity');
assert.equal(aggregate.fraction, 1 / 1.5);
assert.deepEqual(aggregate.rows.map(row => [row.label, row.detail]), [
  ['Mounted volumes', '1.0 TB / 1.5 TB'],
  ['Free space', '500 GB'],
  ['Available for files', '450 GB'],
  ['C:\\', 'System · C:\\ · Used: 200 GB / 500 GB · Free space: 300 GB · Available for files: 250 GB'],
  ['D:\\', '자료 <backup> · D:\\, C:\\Mount\\자료\\ · Used: 800 GB / 1.0 TB · Free space: 200 GB']
]);
assert.deepEqual(aggregate.rows.slice(3).map(row => row.fraction), [0.4, 0.8]);
const koreanDisk = diskCell(multi, 'ko').meter;
assert.equal(koreanDisk.rows[0].label, '마운트된 볼륨');
assert.match(koreanDisk.rows[3].detail, /사용 중: 200 GB/);
assert.match(koreanDisk.rows[3].detail, /남은 공간: 300 GB/);
assert.equal(diskCell({ ...multi, hidden: ['system-disk'] }), undefined);
assert.equal(diskCell({ ...multi, system: false }), undefined);
const missingDisk = diskCell({ system: true, volumes: [], diskUsed: null, diskTotal: null }).meter;
assert.equal(missingDisk.text, '—');
assert.deepEqual(missingDisk.rows.map(row => [row.label, row.detail]), [['Mounted volumes', 'No reading']]);
assert.equal(diskCell({ ...multi, diskUsed: null }).meter.text, '—');
assert.equal(diskCell({ ...multi, volumes: [null, { total: 0 }, { total: 10, used: NaN }] }).meter.rows.length, 3);
const mountedFolder = { ...volumes[1], name: 'C:\\Mount\\자료\\', mountPoints: ['C:\\Mount\\자료\\'] };
const mountedRow = diskCell({ ...multi, volumes: [mountedFolder] }).meter.rows[3];
assert.equal(mountedRow.label, 'Volume');
assert.equal(mountedRow.detail, 'C:\\Mount\\자료\\ · Used: 800 GB / 1.0 TB · Free space: 200 GB');

const monitorCell = (value, id, lang = 'en') => W.extraCells({ system: true, ...value }, lang).find(cell => cell.id === id).meter;
const logicalCores = monitorCell({ cpu: 0.25, cpuCores: [
  { id: '0,0', usage: 0 }, { id: '0,1', usage: 0.5 }, { id: '1,0', usage: null }
] }, 'system-cpu');
assert.deepEqual(logicalCores.rows.slice(1).map(row => [row.label, row.detail, row.fraction]), [
  ['CPU 0:0', '0%', 0], ['CPU 0:1', '50%', 0.5], ['CPU 1:0', '—', null]
]);
const gpu = monitorCell({ gpu: 0.8, gpuEngines: [
  { id: 'adapter-a/0', name: '3D', usage: 0.75 }, { id: 'adapter-b/0', name: 'Copy', usage: 0.8 },
  { id: 'adapter-b/1', name: 'VideoDecode', usage: null }
], recentGpu: { average: 0.4, peak: 0.9 } }, 'system-gpu');
assert.equal(gpu.text, '80%');
assert.equal(gpu.fraction, 0.8, 'use backend busiest physical engine, not the sum of engines');
assert.deepEqual(gpu.rows.map(row => row.detail), ['80%', '40% / 90%', '3D · 75%', 'Copy · 80%', 'VideoDecode · —']);
for (const value of [null, undefined, NaN, Infinity, -1, 1.1]) {
  const missing = monitorCell({ gpu: value }, 'system-gpu');
  assert.equal(missing.text, '—');
  assert.equal(missing.fraction, null);
}
assert.equal(monitorCell({ gpu: 0 }, 'system-gpu').text, '0%', 'measured idle is distinct from unavailable');
assert.equal(monitorCell({ gpu: 0.5 }, 'system-gpu', 'ko').rows[0].label, '가장 바쁜 GPU 엔진');

const wifiPayload = { link: 'wifi', linkName: 'Wireless', linkStrength: 0.64, netDown: 1200000, netUp: 300000 };
const wifi = monitorCell(wifiPayload, 'system-network');
assert.equal(wifi.text, '1.5M/s');
assert.equal(wifi.fraction, 0.64, 'network ring is connection quality, independent of traffic');
assert.equal(wifi.invert, true, 'stronger signal uses the healthy color');
assert.deepEqual(wifi.rows.map(row => [row.label, row.detail]), [
  ['Primary connection', 'Wi-Fi · Wireless'], ['Wi-Fi signal', '64%'], ['Download', '1.2MB/s'], ['Upload', '300KB/s']
]);
for (const value of [null, undefined, NaN, -0.1, 1.01]) {
  const missing = monitorCell({ ...wifiPayload, linkStrength: value }, 'system-network');
  assert.equal(missing.fraction, null);
  assert.equal(missing.rows[1].detail, '—');
  assert.equal(missing.text, '1.5M/s', 'missing strength must not discard measured traffic');
}
assert.equal(monitorCell({ ...wifiPayload, linkStrength: 0 }, 'system-network').rows[1].detail, '0%');
assert.equal(monitorCell({ ...wifiPayload, link: 'wired', linkStrength: null }, 'system-network').fraction, 1);
assert.equal(monitorCell({ ...wifiPayload, link: 'disconnected' }, 'system-network').fraction, 0);
assert.equal(monitorCell({ ...wifiPayload, link: 'other' }, 'system-network').fraction, null);
assert.equal(monitorCell({ ...wifiPayload, netDown: null, netUp: null }, 'system-network').text, '—');
assert.equal(monitorCell(wifiPayload, 'system-network', 'ko').rows[1].label, 'Wi-Fi 신호');
console.log('PASS: widget rates, order, hide, colors, calendar, Korean labels, disk volumes, logical CPUs, GPU and Wi-Fi signal');

// Run the page's real card placement and hot-rectangle reporting, including both CSS zooms.
const fs = require('node:fs'), vm = require('node:vm');
const notch = fs.readFileSync(path.join(__dirname, '../penguinnotch/ui/notch.html'), 'utf8');
const settings = fs.readFileSync(path.join(__dirname, '../penguinnotch/ui/settings.html'), 'utf8');
for (const source of [notch, settings]) {
  const normalize = vm.runInNewContext(source.match(/function normalizeHoverTextScale[^\n]+/)[0] + '; normalizeHoverTextScale');
  for (const invalid of [NaN, Infinity, -Infinity, null, undefined, '1.5', {}, []]) assert.equal(normalize(invalid), 1);
  assert.equal(normalize(-1), 0.8); assert.equal(normalize(42), 1.5);
  assert.equal(normalize(1.24), 1.2); assert.equal(normalize(1.25), 1.3);
  for (let step = 8; step <= 15; step++) assert.equal(normalize(step / 10), step / 10);
}
const geometry = notch.slice(notch.indexOf('function placeCard(){'), notch.indexOf('function renderMeterCard'));
const hot = notch.slice(notch.indexOf('function rectOf('), notch.indexOf('/* What wakes the folded notch'));
const rectangle = (left, top, width, height) => ({left, top, width, height, right:left+width, bottom:top+height});
for (const edge of ['left', 'right', 'top', 'bottom']) for (const zoom of [0.75, 1, 1.25]) {
  const vertical = edge === 'left' || edge === 'right', width = (vertical ? 480 : 650) * zoom, height = 420 * zoom;
  const pillRect = vertical ? rectangle(edge === 'left' ? 0 : width-70*zoom, 30*zoom, 70*zoom, 340*zoom)
    : rectangle(80*zoom, edge === 'top' ? 0 : height-93*zoom, 450*zoom, 93*zoom);
  // Near both ends: clamping must keep the entire card on screen, including at the bottom edge.
  for (const end of [0, 1]) for (let step = 8; step <= 15; step++) {
    const scale = step / 10, k = zoom * scale;
    const cellRect = vertical ? rectangle(pillRect.left, (end ? 350 : 30)*zoom, 44*zoom, 44*zoom)
      : rectangle((end ? 500 : 80)*zoom, pillRect.top, 44*zoom, 44*zoom);
    const cell = {getBoundingClientRect:()=>cellRect, querySelector:()=>null};
    const pill = {getBoundingClientRect:()=>pillRect, querySelector:()=>cell};
    const card = {style:{}, classList:{contains:()=>true}, getBoundingClientRect:()=>rectangle(
      (parseFloat(card.style.left)||0)*k, (parseFloat(card.style.top)||0)*k,
      Math.min(246, parseFloat(card.style.maxWidth))*k, Math.min(1000, parseFloat(card.style.maxHeight))*k)};
    const tail = {style:{}, getBoundingClientRect:()=>rectangle(parseFloat(tail.style.left)*zoom,
      parseFloat(tail.style.top)*zoom, (vertical?32:36)*zoom, (vertical?36:32)*zoom)};
    let reported;
    const context = {card, pill, tail, hoverId:'fixture', hoverTextScale:scale, notchEdge:edge,
      innerWidth:width, innerHeight:height, insets:[12,9,24,7], folded:false,
      updateCard:null, updateTail:null,
      document:{documentElement:{style:{zoom:String(zoom)}}}, window:{devicePixelRatio:1.5},
      edgeIsVertical:()=>vertical, placeHandles:()=>false, callq:(cmd,args)=>{assert.equal(cmd,'set_hot');reported=args;return Promise.resolve();}};
    vm.runInNewContext(geometry + hot + '; placeCard();', context);
    const box = card.getBoundingClientRect();
    assert.ok(box.left >= 15*zoom-0.01 && box.right <= width-17*zoom+0.01, `${edge}: horizontal bounds`);
    assert.ok(box.top >= 20*zoom-0.01 && box.bottom <= height-32*zoom+0.01, `${edge}: vertical bounds`);
    if (edge === 'left') assert.ok(box.left >= pillRect.right+30*zoom-0.01);
    if (edge === 'right') assert.ok(box.right <= pillRect.left-30*zoom+0.01);
    if (edge === 'top') assert.ok(box.top >= pillRect.bottom+30*zoom-0.01);
    if (edge === 'bottom') assert.ok(box.bottom <= pillRect.top-30*zoom+0.01);
    assert.equal(reported.expanded, true);
    assert.deepEqual(Array.from(reported.rects[2]), [box.left,box.top,box.width,box.height].map(v=>v*1.5));
  }
}
const native = fs.readFileSync(path.join(__dirname, '../penguinnotch/src/main.rs'), 'utf8');
const nativeWidth = Number(native.match(/pub const NOTCH_W: f64 = ([\d.]+)/)[1]);
assert.ok(nativeWidth >= 70+30+246*1.5+10, 'space for 150% cards without changing notch zoom');
console.log('PASS: hover scale validation, all eight sizes, four edges, viewport bounds, CSS zoom and measured hot rectangles');

// Exercise the actual preview/folding state machine with deterministic timers.
{
  let now=0,sequence=0,reports=0;
  const timers=new Map(),listeners=new Map();
  const context=vm.createContext({onHover:false,folded:false,pointerIn:false,carrying:false,dragging:false,stockDragging:false,menuOpen:false,foldTimer:null,previewTimer:null,hideTimer:null,
    updateCardHeld:()=>false,
    document:{body:{classList:{toggle(){}}}},hideCard(){},setHovered(){},reportHot(){reports++;},
    setTimeout(fn,delay){const id=++sequence;timers.set(id,{fn,at:now+delay});return id;},clearTimeout:id=>timers.delete(id),
    listen(name,fn){listeners.set(name,fn);return Promise.resolve();}});
  vm.runInContext(notch.slice(notch.indexOf('const FOLD_GRACE='),notch.indexOf("listen('notch_pointer'")),context);
  const advance=ms=>{const end=now+ms;while(true){const next=[...timers].filter(([,v])=>v.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];if(!next)break;now=next[1].at;timers.delete(next[0]);next[1].fn();}now=end;};
  context.applyUiFlags({notch_on_hover:true});advance(450);assert.equal(context.folded,true);
  listeners.get('notch_show_now')();assert.equal(context.folded,false);advance(4999);assert.equal(context.folded,false);
  advance(451);assert.equal(context.folded,true);
  for(const guard of ['pointerIn','carrying','dragging','stockDragging','menuOpen']){
    listeners.get('notch_show_now')();context[guard]=true;advance(6000);assert.equal(context.folded,false,guard+' prevents folding');
    context[guard]=false;context.scheduleFold();advance(450);assert.equal(context.folded,true);
  }
  listeners.get('notch_show_now')();advance(4000);listeners.get('notch_show_now')();advance(4000);assert.equal(context.folded,false,'repeat reveal renews preview');
  context.applyUiFlags({notch_on_hover:false});advance(6000);assert.equal(context.folded,false,'Keep open cancels preview folding');
  listeners.get('notch_show_now')();context.applyUiFlags({notch_on_hover:true});advance(450);assert.equal(context.folded,true,'explicit hover choice ends preview');
  assert.ok(reports>10,'visibility transitions remeasure native hot regions');
}
console.log('PASS: reveal duration/renewal, Keep open, hover and drag/menu folding guards');

// Exercise the page's real wheel listener without a browser dependency. Rendered clipping and
// elementFromPoint/reorder parity are covered by test-notch-scroll-browser.cjs.
{
  const wheelSource=notch.slice(notch.indexOf("pill.addEventListener('wheel'"),notch.indexOf("document.addEventListener('mousemove'",notch.indexOf("pill.addEventListener('wheel'")));
  const zoomSource=notch.slice(notch.indexOf('function fitZoom(){'),notch.indexOf('// `settled` only'));
  for(const vertical of [false,true]) for(const zoom of [.75,1,1.137,1.5]){
    let wheel,synced=0;
    const cells={clientHeight:200,clientWidth:200,scrollHeight:900,scrollWidth:900,scrollTop:0,scrollLeft:0};
    const context=vm.createContext({cells,folded:false,dragging:false,stockDragging:false,carrying:false,press:{id:'old'},lastPointer:null,
      nativeDpr:1.5*zoom,window:{devicePixelRatio:1.5},innerWidth:123,
      document:{documentElement:{style:{zoom:String(zoom)}}},edgeIsVertical:()=>vertical,syncScrollHover(){synced++;},
      pill:{addEventListener(name,fn,opts){assert.equal(name,'wheel');assert.equal(opts.passive,false);wheel=fn;}}});
    vm.runInContext(zoomSource+wheelSource,context);
    assert.equal(context.fitZoom(),zoom,'capping viewport width must not change scale');
    const axis=vertical?'scrollTop':'scrollLeft',cross=vertical?'scrollLeft':'scrollTop';
    const event=(patch={})=>{const e={deltaX:0,deltaY:0,deltaMode:0,clientX:5,clientY:8,preventDefault(){this.prevented=true;},...patch};wheel(e);return e;};
    event({deltaY:40*zoom});assert.equal(cells[axis],40);assert.equal(cells[cross],0);
    assert.equal(context.press,null,'scroll cannot refresh the cell pressed before it moved');
    assert.deepEqual(Array.from(context.lastPointer),[5,8]);assert.ok(synced>0,'wheel immediately rechecks stationary hover');
    event({deltaX:30*zoom,deltaY:10*zoom});assert.equal(cells[axis],70,'trackpad dominant axis only, never summed');
    event({deltaY:2,deltaMode:1});assert.equal(cells[axis],102,'line units');
    event({deltaY:1,deltaMode:2});assert.equal(cells[axis],302,'page units');
    event({deltaY:1e6});assert.equal(cells[axis],700);
    assert.equal(event({deltaY:20}).prevented,true);assert.equal(cells[axis],700,'end clamp');
    event({deltaY:-1e6});assert.equal(cells[axis],0);
    assert.equal(event({deltaY:-20}).prevented,true);assert.equal(cells[axis],0,'start clamp');
    for(const guard of ['folded','dragging','stockDragging','carrying']){
      context[guard]=true;event({deltaY:80});assert.equal(cells[axis],0,guard);context[guard]=false;
    }
    event({deltaY:80,ctrlKey:true});event({deltaY:NaN});assert.equal(cells[axis],0);
    cells.scrollHeight=cells.scrollWidth=200;
    assert.equal(event({deltaY:100}).prevented,undefined,'non-overflow wheel is untouched');assert.equal(cells[axis],0);
  }
}
console.log('PASS: capped viewport DPI, wheel units/axes/boundaries, stationary hover, drag/fold guards and no-overflow stability');

{
  const ny = 'America/New_York';
  const forecastDay = Date.UTC(2026, 2, 7, 5, 0, 0) / 1000;
  const sunrise = Date.UTC(2026, 2, 7, 11, 20, 0) / 1000;
  const sunset = Date.UTC(2026, 2, 7, 23, 0, 0) / 1000;
  const measuredAt = Date.UTC(2026, 2, 7, 17, 0, 0) / 1000;
  const nowToday = Date.UTC(2026, 2, 7, 17, 0, 0);
  const beforeDst = Date.UTC(2026, 2, 8, 6, 30, 0) / 1000;
  const afterDst = Date.UTC(2026, 2, 8, 7, 30, 0) / 1000;
  const afterDstMidnight = Date.UTC(2026, 2, 9, 4, 30, 0);
  assert.equal(W.cityLocalDate(forecastDay, ny), '2026-03-07');
  assert.equal(W.cityLocalDate(beforeDst, ny), '2026-03-08');
  assert.equal(W.cityLocalDate(afterDst, ny), '2026-03-08');
  assert.equal(W.cityLocalDate(afterDstMidnight / 1000, ny), '2026-03-09');
  const naiveOffsetDate = new Date((afterDstMidnight / 1000 - 5 * 3600) * 1000).toISOString().slice(0, 10);
  assert.equal(naiveOffsetDate, '2026-03-08');
  assert.equal(W.cityClock(measuredAt, 'Not/A_Zone', 'en'), null);
  assert.equal(W.cityClock(measuredAt, '', 'en'), null);
  assert.equal(W.cityLocalDate(forecastDay, null), null);
  const hourlyRain = [1, 2, 3, 4, 5, 6].map(hour => ({
    end: measuredAt + hour * 3600, probability: hour === 3 ? 80 : 10 * hour
  }));
  const weather = {
    name: 'New York', temperature: 12.4, code: 61, feelsLike: 11.2,
    low: 5, high: 15, rain: 80, humidity: 70, wind: 2.3, uv: 4.5,
    sunrise, sunset, forecastDay, timezone: ny, measuredAt, hourlyRain, stale: false
  };
  const labels = rows => rows.map(row => [row.label, row.detail]);
  const today = W.weatherRows({ weatherOn: true, weather, now: nowToday }, 'en');
  assert.deepEqual(labels(today).filter(([label]) => [
    'Daily low / high', 'Chance of rain today', 'Precip. peak (next 6h)', 'Peak hour ending',
    'Sunrise / Sunset', 'UV peak today', 'Updated (city time)'
  ].indexOf(label) >= 0), [
    ['Daily low / high', '5° / 15°C'],
    ['Chance of rain today', '80%'],
    ['Precip. peak (next 6h)', '80%'],
    ['Peak hour ending', W.cityClock(measuredAt + 3 * 3600, ny, 'en')],
    ['Sunrise / Sunset', W.cityClock(sunrise, ny, 'en') + ' / ' + W.cityClock(sunset, ny, 'en')],
    ['UV peak today', '4.5'],
    ['Updated (city time)', W.cityClock(measuredAt, ny, 'en')]
  ]);
  const korean = W.weatherRows({ weatherOn: true, weather, now: nowToday }, 'ko');
  assert.equal(korean.find(row => row.detail === '80%').label, '오늘 강수 확률');
  assert.equal(korean.find(row => row.label === '일출 / 일몰').detail, W.cityClock(sunrise, ny, 'ko') + ' / ' + W.cityClock(sunset, ny, 'ko'));
  const afterMidnight = W.weatherRows({ weatherOn: true, weather, now: afterDstMidnight }, 'en');
  assert.equal(afterMidnight.some(row => row.label === 'Chance of rain today' || row.label === 'UV peak today' || row.label === 'Daily low / high'), false);
  assert.equal(afterMidnight.find(row => row.label === 'Sunrise / Sunset').detail, 'Unavailable');
  assert.equal(afterMidnight.find(row => row.label === 'Precip. peak (next 6h)').detail, 'Unavailable');
  assert.equal(afterMidnight.find(row => row.label === 'Updated (city time)').detail, W.cityClock(measuredAt, ny, 'en'));
  const seoulMidnight = 1790002800;
  assert.equal(new Date(seoulMidnight * 1000).toISOString(), '2026-09-21T15:00:00.000Z');
  assert.equal(W.cityLocalDate(seoulMidnight, 'Asia/Seoul'), '2026-09-22');
  assert.equal(W.cityLocalDate(seoulMidnight + 86400, 'Asia/Seoul'), '2026-09-23');
  const badZone = W.weatherRows({ weatherOn: true, weather: { ...weather, timezone: 'Not/A_Zone' }, now: nowToday }, 'en');
  assert.equal(badZone.find(row => row.label === 'Updated (city time)').detail, 'Unavailable');
  assert.equal(badZone.find(row => row.label === 'Sunrise / Sunset').detail, 'Unavailable');
  assert.equal(badZone.some(row => row.label === 'Chance of rain today'), false);
  const seoulWeather = { ...weather, timezone: 'Asia/Seoul', forecastDay: seoulMidnight, measuredAt: seoulMidnight + 12 * 3600, sunrise: seoulMidnight + 6 * 3600, sunset: seoulMidnight + 18 * 3600, hourlyRain: [] };
  const seoulToday = W.extraCells({ weatherOn: true, weather: seoulWeather, now: (seoulMidnight + 3600) * 1000 }, 'en')
    .find(cell => cell.id === 'widget-weather').meter.rows;
  assert.ok(seoulToday.some(row => row.label === 'Chance of rain today'));
  const seoulNext = W.extraCells({ weatherOn: true, weather: seoulWeather, now: (seoulMidnight + 86400) * 1000 }, 'en')
    .find(cell => cell.id === 'widget-weather').meter.rows;
  assert.equal(seoulNext.some(row => row.label === 'Chance of rain today'), false);
  assert.equal(seoulNext.find(row => row.label === 'Sunrise / Sunset').detail, 'Unavailable');
  const missing = W.weatherRows({
    weatherOn: true,
    weather: { temperature: 1, code: 0, timezone: 'GMT', measuredAt: 1000, forecastDay: 1000, hourlyRain: 'nope', sunrise: null, sunset: undefined },
    now: 1000 * 1000
  }, 'en');
  assert.equal(missing.find(row => row.label === 'Precip. peak (next 6h)').detail, 'Unavailable');
  assert.equal(missing.find(row => row.label === 'Sunrise / Sunset').detail, 'Unavailable');
  assert.ok(missing.find(row => row.label === 'Updated (city time)').detail);
  const partialCurrentHour = [
    { end: 2000, probability: 10 }, { end: 5600, probability: 20 }, { end: 9200, probability: 30 },
    { end: 12800, probability: 40 }, { end: 16400, probability: 50 }, { end: 20000, probability: 60 }
  ];
  assert.deepEqual(W.upcomingRainPeak(partialCurrentHour, 1000), { end: 20000, probability: 60 });
  const gappedHours = [
    { end: 2000, probability: 10 }, { end: 5600, probability: 20 }, { end: 9200, probability: 30 },
    { end: 16400, probability: 40 }, { end: 20000, probability: 50 }, { end: 22600, probability: 60 }
  ];
  assert.equal(W.upcomingRainPeak(gappedHours, 1000), null);
  const duplicateHours = [
    { end: 4600, probability: 10 }, { end: 8200, probability: 20 }, { end: 8200, probability: 90 },
    { end: 11800, probability: 40 }, { end: 15400, probability: 50 }, { end: 19000, probability: 60 }
  ];
  assert.equal(W.upcomingRainPeak(duplicateHours, 1000), null);
  const hole = [1, 2, 3, 4, 5, 6].map(hour => ({ end: 1000 + hour * 3600, probability: hour === 3 ? null : 10 }));
  assert.equal(W.upcomingRainPeak(hole, 1000), null);
  const validHours = [1, 2, 3, 4, 5, 6].map(hour => ({ end: 1000 + hour * 3600, probability: hour === 4 ? 55 : 10 }));
  assert.deepEqual(W.upcomingRainPeak(validHours, 1000), { end: 1000 + 4 * 3600, probability: 55 });
  const over = [1, 2, 3, 4, 5, 6].map(hour => ({ end: 1000 + hour * 3600, probability: hour === 4 ? 150 : 10 }));
  assert.equal(W.upcomingRainPeak(over, 1000), null);
  const negative = [1, 2, 3, 4, 5, 6].map(hour => ({ end: 1000 + hour * 3600, probability: hour === 2 ? -1 : 10 }));
  assert.equal(W.upcomingRainPeak(negative, 1000), null);
}
console.log('PASS: weather city-local midnight including DST, hover extras, missing/malformed arrays');
