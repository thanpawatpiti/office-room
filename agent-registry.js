'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const crypto = require('node:crypto');

const BUILTINS = [
  { id: 'claude', displayName: 'Claude Code', command: 'claude', adapter: 'claude' },
  { id: 'codex', displayName: 'Codex', command: 'codex', adapter: 'codex' },
  ...['gemini', 'qwen', 'aider', 'cursor-agent', 'opencode', 'copilot', 'amp', 'goose', 'crush', 'kiro', 'q'].map(id => ({ id, displayName: id, command: id, adapter: null })),
];
const ID = /^(?!user$|done$|system$|coordinator$|dispatcher$)[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/;
function executable(command, envPath = process.env.PATH) {
  for (const file of command.includes('/') ? [path.resolve(command)] : (envPath || '').split(path.delimiter).map(dir => path.join(dir, command))) {
    try { fs.accessSync(file, fs.constants.X_OK); if (fs.statSync(file).isFile()) return fs.realpathSync(file); } catch { /* next PATH entry */ }
  }
  return null;
}
// CLIs bundled inside the desktop apps, used when nothing is on PATH.
function desktopCli(id, home = require('node:os').homedir()) {
  const first = files => files.map(f => executable(f)).find(Boolean) || null;
  if (id === 'codex') {
    return first(['/Applications', path.join(home, 'Applications')].flatMap(dir => ['Codex.app', 'ChatGPT.app'].flatMap(app =>
      ['Resources/codex', 'MacOS/codex-cli'].map(f => path.join(dir, app, 'Contents', f)))));
  }
  if (id === 'claude') {
    const root = path.join(home, 'Library', 'Application Support', 'Claude', 'claude-code');
    let versions = [];
    try { versions = fs.readdirSync(root).sort((a, b) => b.localeCompare(a, undefined, { numeric: true })); } catch { return null; }
    return first(versions.flatMap(v => [path.join(root, v, 'claude.app', 'Contents', 'MacOS', 'claude'), path.join(root, v, 'claude')]));
  }
  return null;
}
function capture(file, args, { input, accept, timeout = 12000, cwd, onChild } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    onChild?.(child);
    let text = '', buffer = '', stderr = '', done = false;
    const finish = (error, value) => { if (done) return; done = true; clearTimeout(timer); child.kill(); error ? reject(error) : resolve(value); };
    const timer = setTimeout(() => finish(new Error('อ่านข้อมูล CLI หมดเวลา')), timeout);
    child.on('error', error => finish(error)); child.stdin.on('error', () => {}); child.stderr.on('data', data => { stderr = (stderr + data).slice(-2000); });
    child.stdout.on('data', data => {
      text += data; buffer += data;
      if (text.length > 2 * 1024 * 1024) return finish(new Error('ข้อมูล CLI ใหญ่เกินไป'));
      if (!accept) return;
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        try { const value = accept(JSON.parse(line)); if (value !== undefined) finish(null, value); } catch (error) { if (error instanceof SyntaxError) continue; finish(error); }
      }
    });
    child.on('close', code => { if (!done) code === 0 && !accept ? finish(null, text.trim()) : finish(new Error('CLI ไม่ส่งข้อมูลที่รองรับ (exit ' + code + ') ' + (accept ? stderr : stderr + text).slice(-2000))); });
    if (input !== undefined) child.stdin.write(JSON.stringify(input) + '\n');
    else child.stdin.end();
  });
}
function modelsFrom(raw, provider) {
  if (!Array.isArray(raw) || !raw.length) throw new Error('CLI ไม่ส่งรายชื่อโมเดล');
  return raw.map(m => {
    const selector = provider === 'claude' ? m.value : m.model || m.id;
    if (typeof selector !== 'string' || !selector || selector.length > 200) throw new Error('model selector ไม่ถูกต้อง');
    const efforts = provider === 'claude' ? m.supportedEffortLevels : (m.supportedReasoningEfforts || m.supportedEfforts)?.map(e => typeof e === 'string' ? e : e.reasoningEffort);
    return { id: selector, selector, resolvedModel: m.resolvedModel || selector, displayName: m.displayName || selector, description: String(m.description || '').slice(0, 1000), supportedEfforts: Array.isArray(efforts) ? [...new Set(efforts.filter(e => typeof e === 'string'))] : [], effortSupport: efforts?.length ? 'supported' : m.supportsEffort === false ? 'unsupported' : 'unknown', defaultEffort: m.defaultReasoningEffort || m.defaultEffort || null, isDefault: provider === 'claude' ? selector === 'default' : !!m.isDefault, inputModalities: m.inputModalities || null };
  });
}
// Effort names describe a provider's depth levels. This order only preserves a user's legacy ceiling;
// it never ranks models/providers or decides what effort a task needs.
const DEPTH = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
function permittedModels(record, policy = {}) {
  if (policy.enabled === false) return [];
  return (record.models || []).filter(m => !policy.models?.length || policy.models.includes(m.selector) || policy.models.includes(m.resolvedModel)).map(m => {
    let allowed = m.supportedEfforts;
    if (policy.allowedEfforts?.[m.selector]) allowed = allowed.filter(e => policy.allowedEfforts[m.selector].includes(e));
    if (policy.maxEffort) {
      const cap = DEPTH.indexOf(policy.maxEffort);
      allowed = cap < 0 ? [] : allowed.filter(e => DEPTH.indexOf(e) >= 0 && DEPTH.indexOf(e) <= cap);
    }
    return { ...m, allowedEfforts: allowed, runtimeDefaultAllowed: !policy.maxEffort && !policy.allowedEfforts?.[m.selector] };
  }).filter(m => m.effortSupport !== 'supported' || m.allowedEfforts.length || m.runtimeDefaultAllowed);
}
function validateChoice(record, policy, { model, effort }) {
  const models = permittedModels(record, policy);
  const chosen = model ? models.find(m => m.selector === model || m.resolvedModel === model) : models.find(m => m.isDefault);
  if (!chosen) throw new Error('ต้องเลือก model จาก catalog ที่อนุญาตของ ' + record.id);
  if (effort == null || effort === '' || effort === 'default') {
    if (!chosen.runtimeDefaultAllowed && (chosen.effortSupport !== 'supported' || !chosen.allowedEfforts.includes(chosen.defaultEffort))) throw new Error('ต้องระบุ effort ที่อยู่ในขอบเขตผู้ใช้');
    return { model: chosen.selector, effort: chosen.runtimeDefaultAllowed ? undefined : chosen.defaultEffort };
  }
  if (!chosen.allowedEfforts.includes(effort)) throw new Error('effort ไม่รองรับหรือเกินขอบเขตของ model ' + chosen.selector);
  return { model: chosen.selector, effort };
}
// Lowers an over-deep effort to the deepest level the model allows at or below cap; never raises it or errors.
function capEffort(record, policy, choice, cap) {
  const limit = DEPTH.indexOf(cap), asked = DEPTH.indexOf(choice.effort);
  if (!cap || !choice.effort || limit < 0 || asked <= limit) return choice;
  const model = permittedModels(record, policy).find(m => m.selector === choice.model);
  const level = DEPTH.filter(e => DEPTH.indexOf(e) <= limit && model?.allowedEfforts.includes(e)).pop();
  return level ? { ...choice, effort: level } : choice;
}
function parseNext(text) {
  const footer = String(text).trim().match(/\[\[NEXT\s+([^\n]*?)\]\]$/);
  if (!footer) return { body: String(text).trim(), next: null };
  let next;
  try {
    if (footer[1].trim().startsWith('{')) next = JSON.parse(footer[1]);
    else { next = {}; for (const [, key, value] of footer[1].matchAll(/(\w+)\s*=\s*([\w.\-|]+)/g)) next[key] = value; }
  } catch { return { body: String(text).trim(), next: null }; }
  if (!next || typeof next.to !== 'string' || next.to.length > 100) return { body: String(text).trim(), next: null };
  for (const field of ['model', 'effort', 'assignment', 'reason', 'then', 'kind', 'mode']) if (next[field] !== undefined && (typeof next[field] !== 'string' || next[field].length > 2000)) return { body: String(text).trim(), next: null };
  return { body: String(text).slice(0, footer.index).trim(), next };
}

// These are attributed worker reports, not a claim that the server ran the checks.
function validateCompletion(report) {
  const shortText = (value, max = 2000) => typeof value === 'string' && value.trim().length > 0 && value.length <= max;
  if (!report || !shortText(report.summary)) throw new Error('ต้องมีสรุปผลก่อนปิดงาน');
  if (!Array.isArray(report.checks) || report.checks.length > 50 || !Array.isArray(report.remaining) || report.remaining.length > 50) throw new Error('ต้องระบุผลตรวจและสิ่งที่ยังค้าง');
  for (const check of report.checks) {
    if (!check || !shortText(check.name, 200) || !['passed', 'failed', 'not_run'].includes(check.result) || !shortText(check.evidence) || (check.required !== undefined && typeof check.required !== 'boolean')) throw new Error('ผลตรวจต้องมีชื่อ ผล และหลักฐานหรือเหตุผลที่ยังไม่ตรวจ');
  }
  if (report.remaining.some(item => !shortText(item))) throw new Error('รายการค้างไม่ถูกต้อง');
  if (report.review !== undefined && (!report.review || !['not_required', 'self_reviewed'].includes(report.review.status) || !shortText(report.review.reason))) throw new Error('ข้อยกเว้นการตรวจงานต้องมีเหตุผล');
  return { summary: report.summary.trim(), checks: report.checks.map(check => ({ name: check.name.trim(), result: check.result, evidence: check.evidence.trim(), required: check.required !== false })), remaining: report.remaining.map(item => item.trim()), ...(report.review ? { review: { status: report.review.status, reason: report.review.reason.trim() } } : {}) };
}
class Registry {
  constructor({ settings, codexModels, cwd, changed = () => {}, cache = {} }) { this.settings = settings; this.codexModels = codexModels; this.cwd = cwd; this.changed = changed; this.records = Object.assign(Object.create(null), Object.fromEntries(Object.entries(cache).map(([id, record]) => [id, { models: record.models, discoveredAt: record.discoveredAt, stale: true, authState: 'unknown' }]))); this.pending = null; this.listEntries(); }
  listEntries() {
    const custom = this.settings().cliEntries || [];
    if (!Array.isArray(custom) || custom.some(e => !ID.test(e.id) || Object.prototype.hasOwnProperty.call(Object.prototype, e.id) || typeof e.command !== 'string' || !e.command || !['office-jsonl', null].includes(e.adapter))) throw new Error('CLI entry ต้องมี id, command และ adapter office-jsonl');
    if (new Set(custom.map(e => e.id)).size !== custom.length || custom.some(e => BUILTINS.some(b => b.id === e.id && b.adapter))) throw new Error('CLI id ซ้ำกับตัวเชื่อมที่มีอยู่');
    const entries = [...BUILTINS.filter(b => !custom.some(e => e.id === b.id)), ...custom];
    const paths = new Map();
    for (const entry of entries) {
      const file = executable(entry.command) || (BUILTINS.includes(entry) ? desktopCli(entry.id) : null);
      if (!file && !this.records[entry.id] && !entry.adapter) continue;
      const previous = this.records[entry.id] || {};
      this.records[entry.id] = Object.assign(previous, entry, { executablePath: file, installed: !!file, supported: !!entry.adapter, duplicateOf: file ? paths.get(file) || null : null, authState: previous.authState || 'unknown' });
      if (file && !paths.has(file)) paths.set(file, entry.id);
    }
    for (const id of Object.keys(this.records)) if (!entries.some(e => e.id === id)) delete this.records[id];
    return Object.values(this.records);
  }
  refresh() {
    if (this.pending) return this.pending;
    this.pending = (async () => {
      this.listEntries();
      await Promise.all(Object.values(this.records).map(async record => {
        if (!record.installed || !record.supported) return;
        record.refreshing = true; record.authState = 'unknown'; this.changed();
        try {
          record.version = await capture(record.executablePath, ['--version'], { cwd: this.cwd });
          let raw;
          if (record.adapter === 'codex') {
            const login = await capture(record.executablePath, ['login', 'status'], { cwd: this.cwd }).catch(() => '');
            // Some versions print status on stderr; the app-server's account RPC is authoritative.
            raw = await this.codexModels(); record.authState = raw.authState || (/logged in/i.test(login) ? 'loggedIn' : 'unknown'); raw = raw.models;
          } else if (record.adapter === 'claude') {
            const auth = JSON.parse(await capture(record.executablePath, ['auth', 'status'], { cwd: this.cwd })); record.authState = auth.loggedIn ? 'loggedIn' : 'loggedOut';
            raw = await capture(record.executablePath, ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--no-session-persistence', '--safe-mode', '--permission-mode', 'plan', '--tools', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--setting-sources', ''], { cwd: this.cwd, input: { type: 'control_request', request_id: 'catalog', request: { subtype: 'initialize' } }, accept: m => m.type === 'control_response' && m.response?.response ? m.response.response.models : undefined });
          } else {
            const info = await capture(record.executablePath, ['--office-capabilities'], { cwd: this.cwd, accept: m => m.type === 'capabilities' ? m : undefined });
            raw = info.models; record.authState = info.authState || 'unknown'; record.permissions = info.permissions || {}; record.quotaGroup = typeof info.quotaGroup === 'string' ? info.quotaGroup : null;
          }
          record.models = modelsFrom(raw, record.adapter); record.discoveredAt = Date.now(); record.discoveryError = null; record.stale = false;
        } catch (error) { record.discoveryError = error.message; record.stale = !!record.models?.length; }
        finally { record.refreshing = false; this.changed(); }
      }));
      return this.records;
    })().finally(() => { this.pending = null; });
    return this.pending;
  }
  eligible(id) { const r = this.records[id]; return !!(r?.installed && !r.duplicateOf && r.supported && r.authState === 'loggedIn' && (r.adapter !== 'office-jsonl' || r.permissions?.readOnly) && permittedModels(r, this.settings().agents?.[id]).length); }
}
function chooseBootstrap(ids) { return ids.length ? ids[crypto.randomInt(ids.length)] : null; }
module.exports = { Registry, executable, desktopCli, capture, modelsFrom, permittedModels, validateChoice, capEffort, parseNext, chooseBootstrap, validateCompletion };
