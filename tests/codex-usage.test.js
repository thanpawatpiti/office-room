'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createSessionReader, readRolloutLimits } = require('../codex-usage');

const line = (at, rate_limits) => JSON.stringify({ timestamp: new Date(at).toISOString(), type: 'event_msg', payload: { type: 'token_count', rate_limits } }) + '\n';
const codex = used => ({ limit_id: 'codex', primary: { used_percent: used, window_minutes: 300, resets_at: 2000000000 }, secondary: { used_percent: used / 2, window_minutes: 10080, resets_at: 2000500000 } });
function dayDir(root, offsetDays = 0) {
  const d = new Date(Date.now() - offsetDays * 86400000);
  const dir = path.join(root, String(d.getFullYear()), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0'));
  fs.mkdirSync(dir, { recursive: true }); return dir;
}

test('the newest Codex limits line wins; other limit ids and null readings are skipped', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-usage-'));
  const file = path.join(dayDir(root), 'rollout-a.jsonl');
  fs.writeFileSync(file, line(1000, codex(10)) + line(2000, codex(40)) + line(3000, { limit_id: 'premium', primary: { used_percent: 99 } }) + line(4000, null) + '{"broken"\n');
  const reading = readRolloutLimits(file);
  assert.deepEqual(reading, { at: 2000, limits: { primary: { usedPercent: 40, windowDurationMins: 300, resetsAt: 2000000000 }, secondary: { usedPercent: 20, windowDurationMins: 10080, resetsAt: 2000500000 } } });
});

test('the reader picks the most recently written session, and rereads only after a change', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-usage-'));
  const older = path.join(dayDir(root, 1), 'rollout-yesterday.jsonl'), newer = path.join(dayDir(root), 'rollout-today.jsonl');
  fs.writeFileSync(older, line(1000, codex(70))); fs.utimesSync(older, new Date(5000), new Date(5000));
  fs.writeFileSync(newer, line(2000, codex(30)));
  const read = createSessionReader(root);
  assert.equal(read().limits.primary.usedPercent, 30);
  assert.equal(read(), null, 'unchanged file is not parsed again');
  fs.appendFileSync(newer, line(3000, codex(36))); fs.utimesSync(newer, new Date(), new Date(Date.now() + 1000));
  assert.equal(read().limits.primary.usedPercent, 36);
  assert.equal(createSessionReader(path.join(root, 'missing'))(), null);
});
