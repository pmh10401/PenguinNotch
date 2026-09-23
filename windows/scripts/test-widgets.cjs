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
console.log('PASS: widget rates, order, hide, colors, calendar and Korean labels');
