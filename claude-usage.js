'use strict';
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const run = promisify(execFile);

function parseUsage(data) {
  if (!data || typeof data !== 'object') throw new Error('บริการ usage ของ Claude ส่งข้อมูลไม่ถูกต้อง');
  const windows = [['5h', data.five_hour], ['7d', data.seven_day]].flatMap(([key, value]) => {
    if (!value || typeof value.utilization !== 'number' || !Number.isFinite(value.utilization) || value.utilization < 0 || value.utilization > 100) return [];
    const reset = typeof value.resets_at === 'string' ? Date.parse(value.resets_at) : NaN;
    return [{ key, used: Math.round(value.utilization), resetsAt: Number.isFinite(reset) ? reset : null }];
  });
  if (!windows.length) throw new Error('ข้อมูล usage ของ Claude ไม่ครบหรือรูปแบบเปลี่ยน');
  return windows;
}
async function readCredentials() {
  // The same trusted Keychain reader used by the user's AIUsageBar; never log its output.
  let stdout;
  try { ({ stdout } = await run('/usr/bin/security', ['find-generic-password', '-s', 'Claude Code-credentials', '-w'], { timeout: 10000, maxBuffer: 1024 * 1024 })); }
  catch { throw new Error('อ่านบัญชี Claude ไม่ได้ กรุณาตรวจการลงชื่อเข้าใช้และสิทธิ์ Keychain'); }
  let oauth;
  try { oauth = JSON.parse(stdout).claudeAiOauth; } catch { /* invalid local credential */ }
  if (!oauth || typeof oauth.accessToken !== 'string' || !oauth.accessToken) throw new Error('ไม่พบการลงชื่อเข้าใช้ Claude');
  if (oauth.expiresAt && oauth.expiresAt <= Date.now()) throw new Error('บัญชี Claude หมดอายุ กรุณาเข้าใช้ Claude Code อีกครั้ง');
  return oauth.accessToken;
}
function createUsageReader({ credentials = readCredentials, request = fetch } = {}) {
  return async () => {
    const token = await credentials();
    let response;
    try { response = await request('https://api.anthropic.com/api/oauth/usage', { headers: { Authorization: `Bearer ${token}`, 'anthropic-beta': 'oauth-2025-04-20' }, signal: AbortSignal.timeout(10000) }); }
    catch { throw new Error('เชื่อมต่อบริการ usage ของ Claude ไม่ได้'); }
    if (!response.ok) {
      const error = new Error(`บริการ usage ของ Claude ตอบกลับ HTTP ${response.status}`);
      error.status = response.status;
      const retryAfter = Number(response.headers?.get?.('retry-after'));
      if (retryAfter > 0) error.retryAfter = retryAfter * 1000;
      throw error;
    }
    let data;
    try { data = await response.json(); } catch { throw new Error('บริการ usage ของ Claude ส่งข้อมูลไม่ถูกต้อง'); }
    return parseUsage(data);
  };
}
module.exports = { createUsageReader, parseUsage };
