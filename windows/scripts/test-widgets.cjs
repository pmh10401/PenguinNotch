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
assert.equal(nativeWidth, Number(notch.match(/const DESIGN_W_UPRIGHT=([\d.]+)/)[1]), 'fallback zoom must match the native window');
assert.ok(nativeWidth >= 70+30+246*1.5+10, 'space for 150% cards without changing notch zoom');
console.log('PASS: hover scale validation, all eight sizes, four edges, viewport bounds, CSS zoom and measured hot rectangles');

// Exercise the actual preview/folding state machine with deterministic timers.
{
  let now=0,sequence=0,reports=0;
  const timers=new Map(),listeners=new Map();
  const context=vm.createContext({onHover:false,folded:false,pointerIn:false,carrying:false,dragging:false,stockDragging:false,menuOpen:false,foldTimer:null,previewTimer:null,hideTimer:null,
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
