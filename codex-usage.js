'use strict';
const fs = require('node:fs');
const path = require('node:path');

// Every Codex session (this app, the CLI or the desktop app) writes the account limits into its
// rollout file after each turn, so the newest file holds the latest reading without asking OpenAI.
function newestRollout(sessionsDir, now = Date.now()) {
  let newest = null;
  for (let n = 0; n < 2; n++) { // today's and yesterday's folders hold every recently active session
    const d = new Date(now - n * 86400000);
    const dir = path.join(sessionsDir, String(d.getFullYear()), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0'));
    let names = [];
    try { names = fs.readdirSync(dir); } catch { continue; }
    for (const name of names) if (name.startsWith('rollout-') && name.endsWith('.jsonl')) {
      const file = path.join(dir, name);
      try { const mtime = fs.statSync(file).mtimeMs; if (!newest || mtime > newest.mtime) newest = { file, mtime }; } catch { /* removed meanwhile */ }
    }
  }
  return newest;
}

// Returns { limits, at } in the app-server's rateLimits shape, or null when the file has none.
function readRolloutLimits(file, fallbackAt = Date.now()) {
  let tail = '';
  try {
    const fd = fs.openSync(file, 'r');
    try {
      const size = fs.fstatSync(fd).size, length = Math.min(size, 512 * 1024), buf = Buffer.alloc(length);
      fs.readSync(fd, buf, 0, length, size - length); tail = buf.toString('utf8');
    } finally { fs.closeSync(fd); }
  } catch { return null; }
  const lines = tail.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i].includes('"rate_limits":{')) continue;
    let line;
    try { line = JSON.parse(lines[i]); } catch { continue; }
    const rl = line.payload?.rate_limits;
    if (!rl || (rl.limit_id && rl.limit_id !== 'codex')) continue;
    const windowOf = x => x && typeof x.used_percent === 'number' ? { usedPercent: x.used_percent, windowDurationMins: x.window_minutes, resetsAt: x.resets_at } : undefined;
    const limits = { primary: windowOf(rl.primary), secondary: windowOf(rl.secondary) };
    if (!limits.primary && !limits.secondary) continue;
    return { limits, at: Date.parse(line.timestamp) || fallbackAt };
  }
  return null;
}

// Reads the newest rollout only when it changed since the previous call.
function createSessionReader(sessionsDir) {
  let seen = '';
  return () => {
    const newest = newestRollout(sessionsDir);
    if (!newest || seen === newest.file + newest.mtime) return null;
    seen = newest.file + newest.mtime;
    return readRolloutLimits(newest.file, newest.mtime);
  };
}

module.exports = { newestRollout, readRolloutLimits, createSessionReader };
