// Run with node --test test-codex-headline.cjs from windows/.
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const html = readFileSync(join(__dirname, 'penguinnotch/ui/notch.html'), 'utf8');
const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)];
for (const [, source] of scripts) new vm.Script(source);
function markedSource(document, name) {
  const begin = `// BEGIN TESTABLE ${name} SELECTOR`;
  const end = `// END TESTABLE ${name} SELECTOR`;
  assert.equal(document.split(begin).length, 2, `exactly one ${name} begin marker`);
  assert.equal(document.split(end).length, 2, `exactly one ${name} end marker`);
  const start = document.indexOf(begin) + begin.length;
  const stop = document.indexOf(end);
  assert.ok(stop > start, `${name} markers are ordered`);
  return document.slice(start, stop);
}
const context = vm.createContext({});
vm.runInContext(markedSource(html, 'HEADLINE'), context);
vm.runInContext(markedSource(html, 'WEEKLY'), context);
const pick = (windows, provider = 'codex') => context.headlineOf({ windows }, provider)?.id ?? null;

test('Codex headline selects core primary regardless of extra-window order', () => {
  assert.equal(pick([{ id: 'spark' }, { id: 'secondary' }, { id: 'primary' }]), 'primary');
});
test('Missing Codex primary stays blank, never replaced by weekly or extra quotas', () => {
  assert.equal(pick([{ id: 'spark' }, { id: 'secondary' }]), null);
  assert.equal(pick([{ id: 'secondary' }]), null);
  assert.equal(pick([{ id: 'spark' }, { id: 'code-review' }]), null);
  assert.equal(pick([]), null);
});
test('Codex secondary remains available to the separate weekly ring', () => {
  const windows = [{ id: 'spark' }, { id: 'secondary', used: 0.8 }];
  assert.equal(context.weeklyOf({ windows }, 'codex').id, 'secondary');
  assert.equal(context.weeklyOf({ windows: [{ id: 'primary' }] }, 'codex'), null);
});
test('Marker extraction does not depend on neighbouring function order', () => {
  const block = `// BEGIN TESTABLE HEADLINE SELECTOR\n${markedSource(html, 'HEADLINE')}\n// END TESTABLE HEADLINE SELECTOR`;
  const reordered = `function staleOf() {}\n${block}\nfunction unrelated() {}`;
  const isolated = vm.createContext({});
  vm.runInContext(markedSource(reordered, 'HEADLINE'), isolated);
  assert.equal(isolated.headlineOf({ windows: [{ id: 'secondary' }] }, 'codex'), null);
});
test('Other provider headline selection is unchanged', () => {
  assert.equal(pick([{ id: 'weekly_all' }, { id: 'session' }], 'claude'), 'session');
  assert.equal(pick([{ id: 'on_demand' }, { id: 'included' }], 'cursor'), 'included');
});

test('Selected providers and system widgets are listed together', () => {
  const widgets = {
    extraCells: () => [{ id: 'system-cpu' }],
    arrange: cells => cells,
  };
  const absent = { status: 'absent' };
  const selected = vm.createContext({
    claudeCells: () => [{ id: 'claude', base: 'claude' }],
    codexSnap: { status: 'ready' }, glmSnap: absent, cursorSnap: absent,
    grokSnap: absent, agSnap: absent,
    notchSlots: [{ provider: 'claude' }],
    window: { PenguinNotchWidgets: widgets }, PenguinNotchWidgets: widgets,
    systemPayload: { order: [] }, uiLang: 'en',
  });
  selected.slotFor = id => selected.notchSlots?.find(slot => slot.provider === id);
  vm.runInContext(markedSource(html, 'PROVIDERS'), selected);
  assert.deepEqual(Array.from(selected.providers(), cell => cell.id), ['claude', 'system-cpu']);
  selected.notchSlots = [];
  assert.deepEqual(Array.from(selected.providers(), cell => cell.id), ['system-cpu']);
  selected.notchSlots = null;
  assert.deepEqual(Array.from(selected.providers(), cell => cell.id), ['claude', 'codex', 'system-cpu']);
});

test('Settings can save the last AI provider off and restore automatic selection', async () => {
  const settings = readFileSync(join(__dirname, 'penguinnotch/ui/settings.html'), 'utf8');
  const source = settings.slice(settings.indexOf('function notchOn(){'), settings.indexOf('const accountsPane ='));
  const calls = [];
  const page = vm.createContext({
    notchSlots: [{ provider: 'claude' }],
    providerList: () => [{ id: 'claude' }],
    renderAccounts: () => {}, toast: () => {}, strip: () => {},
    invoke: (name, args) => { calls.push({ name, args }); return Promise.resolve(); },
  });
  vm.runInContext(source, page);
  page.renderAccounts = () => {};
  page.toggleNotch('claude');
  assert.deepEqual(Array.from(page.notchOn()), []);
  assert.equal(calls[0].name, 'set_notch_slots');
  assert.deepEqual(Array.from(calls[0].args.slots), []);
  page.toggleNotch('claude');
  assert.deepEqual(Array.from(page.notchOn(), slot => slot.provider), ['claude']);
  assert.equal(calls[1].name, 'set_notch_slots');
  assert.equal(calls[1].args.slots, null);
});
