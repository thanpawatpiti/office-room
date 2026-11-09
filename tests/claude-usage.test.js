'use strict';
const assert = require('node:assert/strict');
const { test } = require('node:test');
const { createUsageReader, parseUsage } = require('../claude-usage');

test('account utilization is already a percentage, including zero and full usage', () => {
  const resetsAt = '2026-11-06T06:50:00Z';
  assert.deepEqual(parseUsage({ five_hour: { utilization: 12, resets_at: resetsAt }, seven_day: { utilization: 40 } }), [
    { key: '5h', used: 12, resetsAt: Date.parse(resetsAt) }, { key: '7d', used: 40, resetsAt: null },
  ]);
  assert.deepEqual(parseUsage({ five_hour: { utilization: 0 }, seven_day: { utilization: 100 } }).map(w => w.used), [0, 100]);
});

test('missing windows remain unknown; malformed values never become false zeroes', () => {
  assert.deepEqual(parseUsage({ five_hour: null, seven_day: { utilization: 39.6, resets_at: 'bad date' } }), [{ key: '7d', used: 40, resetsAt: null }]);
  for (const data of [null, {}, { five_hour: { utilization: '12' } }, { five_hour: { utilization: NaN } }, { seven_day: { utilization: 101 } }, { five_hour: { utilization: -1 } }]) {
    assert.throws(() => parseUsage(data));
  }
});

test('reader calls the account endpoint without an inference request', async () => {
  let calls = 0;
  const read = createUsageReader({ credentials: async () => 'fixture-token', request: async (url, options) => {
    calls++;
    assert.equal(url, 'https://api.anthropic.com/api/oauth/usage');
    assert.equal(options.headers.Authorization, 'Bearer fixture-token');
    assert.equal(options.headers['anthropic-beta'], 'oauth-2025-04-20');
    assert.equal(options.body, undefined);
    assert(options.signal instanceof AbortSignal);
    return { ok: true, json: async () => ({ five_hour: { utilization: 12 } }) };
  } });
  assert.equal((await read())[0].used, 12);
  assert.equal(calls, 1);
});

test('network, authentication, throttling and invalid responses report safe errors', async () => {
  const credentials = async () => 'fixture-secret';
  for (const status of [401, 429, 500]) {
    const read = createUsageReader({ credentials, request: async () => ({ ok: false, status, text: async () => 'fixture-secret' }) });
    await assert.rejects(read(), { message: `บริการ usage ของ Claude ตอบกลับ HTTP ${status}` });
  }
  await assert.rejects(createUsageReader({ credentials, request: async () => { throw new Error('fixture-secret'); } })(), { message: 'เชื่อมต่อบริการ usage ของ Claude ไม่ได้' });
  await assert.rejects(createUsageReader({ credentials, request: async () => ({ ok: true, json: async () => { throw new Error('fixture-secret'); } }) })(), { message: 'บริการ usage ของ Claude ส่งข้อมูลไม่ถูกต้อง' });
  await assert.rejects(createUsageReader({ credentials: async () => { throw new Error('fixture login required'); }, request: async () => { assert.fail('must not request without credentials'); } })(), /fixture login required/);
});

test('a 429 carries its status and the Retry-After delay for the back-off', async () => {
  const read = createUsageReader({ credentials: async () => 'fixture-token', request: async () => ({ ok: false, status: 429, headers: new Headers({ 'retry-after': '120' }) }) });
  await assert.rejects(read(), error => error.status === 429 && error.retryAfter === 120000);
});
