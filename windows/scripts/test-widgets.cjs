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
