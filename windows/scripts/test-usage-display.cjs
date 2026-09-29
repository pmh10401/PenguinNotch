'use strict';
// vm-extracted overlay and pace checks. No Playwright. Duration is seconds; reset times are ms.
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {test} = require('node:test');

const html = readFileSync(join(__dirname, '../penguinnotch/ui/notch.html'), 'utf8');
const settings = readFileSync(join(__dirname, '../penguinnotch/ui/settings.html'), 'utf8');

function markedSource(document, name) {
  const begin = `// BEGIN TESTABLE ${name}`;
  const end = `// END TESTABLE ${name}`;
  assert.equal(document.split(begin).length, 2, `exactly one ${name} begin marker`);
  assert.equal(document.split(end).length, 2, `exactly one ${name} end marker`);
  const start = document.indexOf(begin) + begin.length;
  const stop = document.indexOf(end);
  assert.ok(stop > start, `${name} markers are ordered`);
  return document.slice(start, stop);
}

function overlayContext(prefs) {
  const context = vm.createContext({
    usageDisplay: Object.assign({
      shows_notch_readings: true, weekly_ring_dashed: false, weekly_reading: false,
      weekly_headline: false, reset_time_format: 'automatic', show_usage_pace: false,
      claude_daily_pace_ring: false, show_codex_extra_limits: true
    }, prefs || {}),
    agPrefs: {limit: 'automatic', model: 'gemini'}
  });
  vm.runInContext(markedSource(html, 'HEADLINE SELECTOR'), context);
  vm.runInContext(markedSource(html, 'WEEKLY SELECTOR'), context);
  vm.runInContext(markedSource(html, 'HELPERS'), context);
  vm.runInContext(markedSource(html, 'WEEKLY HEADLINE'), context);
  vm.runInContext(markedSource(html, 'DAILY PACE'), context);
  vm.runInContext(markedSource(html, 'USAGE PACE'), context);
  vm.runInContext(markedSource(html, 'DISPLAY'), context);
  return context;
}

const WEEK = 7 * 86400;
const now = 1_800_000_000_000;
const win = (id, used, duration, extra) => Object.assign({
  id, used, duration, resets_at: now + 86400 * 1000
}, extra || {});

test('weekly headline swaps a shorter window for a real week and leaves the card intact', () => {
  const ctx = overlayContext({weekly_headline: true});
  const session = win('session', 0.01, 5 * 3600);
  const week = win('weekly_all', 0.94, WEEK);
  const snap = {windows: [session, week]};
  const led = ctx.applyWeeklyHeadline(ctx.headlineOf(snap, 'claude'), ctx.weeklyOf(snap, 'claude'), true);
  assert.equal(led.headline.id, 'weekly_all');
  assert.equal(led.weekly.id, 'session');
  const drawn = ctx.displayedUsage(snap, 'claude', now);
  assert.deepEqual(drawn.windows, snap.windows);
  assert.equal(drawn.headline.id, 'weekly_all');
});

test('weekly headline leads with a real week when the headline window is missing', () => {
  const ctx = overlayContext({weekly_headline: true});
  const week = win('weekly_all', 0.94, WEEK);
  const snap = {windows: [week]};
  const led = ctx.applyWeeklyHeadline(ctx.headlineOf(snap, 'claude'), ctx.weeklyOf(snap, 'claude'), true);
  assert.equal(led.headline.id, 'weekly_all');
  assert.equal(led.weekly, null);
  const drawn = ctx.displayedUsage(snap, 'claude', now);
  assert.equal(drawn.headline.id, 'weekly_all');
  assert.equal(drawn.weekly, null);
});

test('weekly headline is a no-op without a finite positive duration', () => {
  const ctx = overlayContext({weekly_headline: true});
  const snap = {windows: [win('session', 0.01), win('weekly_all', 0.94)]};
  delete snap.windows[0].duration;
  delete snap.windows[1].duration;
  const led = ctx.applyWeeklyHeadline(ctx.headlineOf(snap, 'claude'), ctx.weeklyOf(snap, 'claude'), true);
  assert.equal(led.headline.id, 'session');
  assert.equal(led.weekly.id, 'weekly_all');
});

test('disabled weekly headline leaves a missing Codex primary blank', () => {
  const ctx = overlayContext({weekly_headline: false});
  const snap = {windows: [{id: 'spark', used: 0.1}, {id: 'secondary', used: 0.4, duration: WEEK}]};
  assert.equal(ctx.headlineOf(snap, 'codex'), null);
  const drawn = ctx.displayedUsage(snap, 'codex', now);
  assert.equal(drawn.headline, null);
});

test('enabled weekly headline leads with Codex secondary when primary is missing', () => {
  const ctx = overlayContext({weekly_headline: true});
  const snap = {windows: [{id: 'secondary', used: 0.4, duration: WEEK}]};
  const led = ctx.applyWeeklyHeadline(ctx.headlineOf(snap, 'codex'), ctx.weeklyOf(snap, 'codex'), true);
  assert.equal(led.headline.id, 'secondary');
  assert.equal(led.weekly, null);
});

test('Codex durations are never inferred from primary or secondary ids', () => {
  const ctx = overlayContext({weekly_headline: true});
  const snap = {windows: [{id: 'primary', used: 0.1}, {id: 'secondary', used: 0.9}]};
  const led = ctx.applyWeeklyHeadline(ctx.headlineOf(snap, 'codex'), ctx.weeklyOf(snap, 'codex'), true);
  assert.equal(led.headline.id, 'primary');
  assert.equal(led.weekly.id, 'secondary');
  const withWeek = {windows: [
    {id: 'primary', used: 0.95, duration: WEEK},
    {id: 'secondary', used: 0.10, duration: 5 * 3600}
  ]};
  const already = ctx.applyWeeklyHeadline(ctx.headlineOf(withWeek, 'codex'), ctx.weeklyOf(withWeek, 'codex'), true);
  assert.equal(already.headline.id, 'primary', 'a week already leading is left alone');
});

test('a second window that is not a week is left alone', () => {
  const ctx = overlayContext({weekly_headline: true});
  const grok = {windows: [win('credits', 0.8, null)]};
  grok.windows[0].duration = undefined;
  const led = ctx.applyWeeklyHeadline(ctx.headlineOf(grok, 'grok'), ctx.weeklyOf(grok, 'grok'), true);
  assert.equal(led.headline && led.headline.id, 'credits');
  const monthly = {windows: [win('session', 0.3, 86400), win('weekly', 0.8, 30 * 86400)]};
  const left = ctx.applyWeeklyHeadline(ctx.headlineOf(monthly, 'glm'), ctx.weeklyOf(monthly, 'glm'), true);
  assert.equal(left.headline.id, 'session');
  assert.equal(left.weekly.id, 'weekly');
});

test('daily pace leads Claude when weekly_all has a reset, and weekly headline does not override it', () => {
  const ctx = overlayContext({weekly_headline: true, claude_daily_pace_ring: true});
  const weekStart = now - 2.25 * 86400 * 1000;
  const resets = weekStart + 7 * 86400 * 1000;
  const session = {id: 'session', used: 0.42, duration: 5 * 3600, resets_at: now + 3600 * 1000};
  const weekly = {id: 'weekly_all', used: 0.30, duration: WEEK, resets_at: resets};
  const snap = {windows: [session, weekly]};
  const drawn = ctx.displayedUsage(snap, 'claude', weekStart + 2.25 * 86400 * 1000);
  assert.equal(drawn.headline.id, 'daily_pace');
  assert.equal(drawn.weekly.id, 'session');
  assert.equal(drawn.windows.map(w => w.id).join(','), 'daily_pace,session,weekly_all');
  assert.ok(Math.abs(drawn.headline.used - 0.70) < 1e-9);
  assert.equal(drawn.headline.duration, undefined);
});

test('daily pace falls back honestly without weekly_all or a reset', () => {
  const ctx = overlayContext({claude_daily_pace_ring: true});
  const seven = {windows: [win('session', 0.4, 5 * 3600), win('seven_day', 0.3, WEEK)]};
  assert.equal(ctx.applyDailyPace(seven, 'claude', true, now), null);
  const noReset = {windows: [{id: 'session', used: 0.4}, {id: 'weekly_all', used: 0.3}]};
  assert.equal(ctx.applyDailyPace(noReset, 'claude', true, now), null);
  const codex = {windows: [win('weekly_all', 0.3, WEEK)]};
  assert.equal(ctx.applyDailyPace(codex, 'codex', true, now), null);
});

test('usage pace matches the Mac boundary math and refuses missing duration', () => {
  const ctx = overlayContext();
  const at = 1_800_000_000_000;
  const deficit = ctx.usagePace({id: 'w', used: 0.98, duration: 604800, resets_at: at + 86400 * 1000}, at);
  assert.ok(Math.abs(deficit.percentagePoints - 12.285714) < 1e-5);
  assert.equal(deficit.isDeficit, true);
  assert.equal(ctx.usagePaceSummary(deficit), '12.3% deficit');
  const reserved = ctx.usagePace({id: 'w', used: 0.27, duration: 604800, resets_at: at + 302400 * 1000}, at);
  assert.ok(Math.abs(reserved.percentagePoints - (-23)) < 1e-5);
  assert.equal(ctx.usagePaceSummary(reserved), '23% reserved');
  const beyond = ctx.usagePace({id: 'w', used: 0.2, duration: 604800, resets_at: at + 604801 * 1000}, at);
  assert.ok(Math.abs(beyond.percentagePoints - 20) < 1e-5);
  assert.equal(ctx.usagePace({id: 'w', used: 0.5, resets_at: at + 86400 * 1000}, at), null);
  assert.equal(ctx.usagePace({id: 'w', used: 0.5, duration: 0, resets_at: at + 86400 * 1000}, at), null);
  assert.equal(ctx.usagePace({id: 'w', used: 0.5, duration: 604800, resets_at: at}, at), null);
  const tiny = ctx.usagePace({id: 'w', used: 0.5004, duration: 604800, resets_at: at + 302400 * 1000}, at);
  assert.equal(ctx.usagePaceSummary(tiny), '<0.1% deficit');
});

test('reading pair follows the selected headline and never duplicates the same window', () => {
  const ctx = overlayContext({weekly_headline: true, weekly_reading: true});
  const session = win('session', 0.30, 5 * 3600);
  const week = win('weekly_all', 0.70, WEEK);
  const drawn = ctx.displayedUsage({windows: [session, week]}, 'claude', now);
  assert.equal(ctx.readingLabel(drawn.headline, drawn.weekly, true, true), '70%/30%');
  assert.equal(ctx.readingLabel(drawn.headline, drawn.headline, true, true), '70%');
  assert.equal(ctx.readingLabel(drawn.headline, drawn.weekly, false, true), '70%');
  assert.equal(ctx.readingLabel({id: 'session', count: 4}, week, true, true), '~4');
});

test('Codex extras hide in the card while the headline stays primary', () => {
  const windows = [
    {id: 'spark', used: 0.1}, {id: 'primary', used: 0.32}, {id: 'code-review', used: 0.2}, {id: 'secondary', used: 0.4}
  ];
  const shown = overlayContext({show_codex_extra_limits: true});
  assert.equal(shown.headlineOf({windows}, 'codex').id, 'primary');
  assert.deepEqual(shown.cardWindows({windows}, 'codex').map(w => w.id), ['spark', 'primary', 'code-review', 'secondary']);
  const hidden = overlayContext({show_codex_extra_limits: false});
  assert.equal(hidden.headlineOf({windows}, 'codex').id, 'primary');
  assert.deepEqual(hidden.cardWindows({windows}, 'codex').map(w => w.id), ['primary', 'secondary']);
});

test('dashed weekly arc uses one dasharray on a partial path', () => {
  const source = html.slice(html.indexOf('function svgArc('), html.indexOf('function stockSweep('));
  const svg = vm.runInNewContext(source + '; svgArc');
  assert.equal(svg(16, 0, '#fff', 2, '', true), '');
  const partial = svg(16, 0.6, '#00FF88', 2.4, 'opacity="0.85"', true);
  assert.equal((partial.match(/stroke-dasharray=/g) || []).length, 1);
  assert.match(partial, /stroke-dasharray="4 2"/);
  assert.match(partial, /<path /);
  assert.ok(!partial.includes('stroke-dasharray="4 2"') || !partial.includes('stroke-dasharray="' + (2 * Math.PI * 16 * 0.6).toFixed(2)));
  const full = svg(16, 1, '#00FF88', 2.4, '', true);
  assert.match(full, /<circle /);
  assert.equal((full.match(/stroke-dasharray=/g) || []).length, 1);
  const solid = svg(16, 0.6, '#00FF88', 2.4);
  assert.match(solid, /<circle /);
  assert.doesNotMatch(solid, /stroke-dasharray="4 2"/);
});

test('settings defaults, reset-time names and invalid limits match native sanitizers', () => {
  const displaySrc = settings.slice(settings.indexOf('function defaultUsageDisplay()'), settings.indexOf('async function saveUsageDisplay'));
  const limitsSrc = settings.slice(settings.indexOf('function defaultUsageLimits()'), settings.indexOf('async function saveUsageLimits'));
  const page = vm.createContext({
    document: {
      querySelectorAll: () => [],
      getElementById: () => ({classList:{toggle(){}}, setAttribute(){}, disabled:false, hidden:false, textContent:'', value:''})
    },
    usageDisplayBusy: false,
    colorTransition: 'hard_step',
    ui: (_, text) => text
  });
  vm.runInContext(displaySrc, page);
  vm.runInContext(limitsSrc, page);
  const d = page.defaultUsageDisplay();
  assert.equal(d.shows_notch_readings, true);
  assert.equal(d.weekly_ring_dashed, false);
  assert.equal(d.weekly_reading, false);
  assert.equal(d.weekly_headline, false);
  assert.equal(d.reset_time_format, 'automatic');
  assert.equal(d.show_usage_pace, false);
  assert.equal(d.claude_daily_pace_ring, false);
  assert.equal(d.show_codex_extra_limits, true);
  assert.equal(page.readUsageDisplay({reset_time_format: 'remaining'}).reset_time_format, 'remaining');
  assert.equal(page.readUsageDisplay({reset_time_format: 'nope'}).reset_time_format, 'automatic');
  const crossed = page.sanitizeUsageLimits(0.9, 0.4);
  assert.equal(crossed.critical_limit, 0.4);
  assert.ok(Math.abs(crossed.watch_limit - 0.39) < 1e-12);
  const reset = page.sanitizeUsageLimits(0.5, 0.7);
  assert.equal(reset.watch_limit, 0.5);
  assert.equal(reset.critical_limit, 0.7);
});
