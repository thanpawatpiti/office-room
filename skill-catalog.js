'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');

// Read front matter as display data, never evaluate YAML or execute a skill while listing it.
function metadata(file) {
  const handle = fs.openSync(file, 'r');
  let text;
  try { const buffer = Buffer.alloc(32768); text = buffer.subarray(0, fs.readSync(handle, buffer, 0, buffer.length, 0)).toString('utf8'); }
  finally { fs.closeSync(handle); }
  const header = text.match(/^\uFEFF?---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/)?.[1] || '';
  function field(name) {
    const lines = header.split(/\r?\n/);
    const index = lines.findIndex(line => line.startsWith(name + ':'));
    if (index < 0) return '';
    let value = lines[index].slice(name.length + 1).trim();
    if (/^[>|][-+]?\s*$/.test(value) || !value) {
      const continuation = [];
      for (let i = index + 1; i < lines.length && (!lines[i].trim() || /^\s/.test(lines[i])); i++) continuation.push(lines[i].trim());
      value = continuation.join(' ').trim();
    }
    if (value.startsWith('"') && value.endsWith('"')) { try { return JSON.parse(value); } catch { return value.slice(1, -1); } }
    if (value.startsWith("'") && value.endsWith("'")) return value.slice(1, -1).replace(/''/g, "'");
    return value;
  }
  return { name: field('name') || path.basename(path.dirname(file)), description: field('description').replace(/\s+/g, ' ').slice(0, 2000) };
}

function discoverSkills({ home = os.homedir(), dirs = [] } = {}) {
  const roots = ['.agents/skills', '.claude/skills', '.codex/skills'].map(folder => ({ path: path.join(home, folder), source: 'ส่วนตัว', scope: 'personal' }));
  for (const dir of dirs) for (const folder of ['.agents/skills', '.claude/skills', '.codex/skills']) roots.push({ path: path.join(dir, folder), source: 'โปรเจกต์ ' + path.basename(dir), scope: 'project' });
  const visited = new Set(), files = new Set(), result = [];
  const skip = new Set(['.trash', '.git', 'node_modules', 'references', 'assets', 'scripts', 'tests']);
  function visit(directory, origin, depth) {
    if (depth > 8) return;
    let real;
    try { real = fs.realpathSync(directory); if (visited.has(real) || !fs.statSync(real).isDirectory()) return; } catch { return; }
    visited.add(real);
    const file = path.join(real, 'SKILL.md');
    try {
      if (fs.statSync(file).isFile()) {
        const resolved = fs.realpathSync(file);
        if (!files.has(resolved)) {
          const info = metadata(resolved); files.add(resolved);
          const relative = path.relative(origin.path, resolved).split(path.sep);
          const qualifier = origin.scope === 'personal' ? (relative[0] === '.system' ? ' · ระบบ' : relative[0] === 'synced' ? ' · ซิงก์' : '') : '';
          result.push({ id: crypto.createHash('sha256').update(resolved).digest('hex').slice(0, 32), ...info, path: resolved, source: origin.source + qualifier, scope: origin.scope });
        }
        return; // Nested resources/test fixtures inside an installed skill are not separate skills.
      }
    } catch { /* not a skill directory; inspect children */ }
    let children;
    try { children = fs.readdirSync(real, { withFileTypes: true }); } catch { return; }
    for (const entry of children.sort((a,b) => a.name.localeCompare(b.name))) if (!skip.has(entry.name) && (!entry.name.startsWith('.') || entry.name === '.system') && (entry.isDirectory() || entry.isSymbolicLink())) visit(path.join(real, entry.name), origin, depth + 1);
  }
  for (const root of roots) visit(root.path, root, 0);
  return result.sort((a,b) => a.name.localeCompare(b.name) || a.source.localeCompare(b.source));
}

function resolveSkills(selection, catalog) {
  if (selection == null || selection === '') return [];
  const values = typeof selection === 'string' ? selection.split(',').map(s => s.trim()).filter(Boolean) : selection;
  if (!Array.isArray(values) || values.length > 100 || values.some(value => typeof value !== 'string')) throw new Error('รายการสกิลไม่ถูกต้อง');
  return [...new Set(values)].map(value => {
    const byID = catalog.find(skill => skill.id === value);
    if (byID) return byID;
    const named = catalog.filter(skill => skill.name === value);
    if (named.length === 1) return named[0];
    throw new Error(named.length ? 'ชื่อสกิลซ้ำ กรุณาเลือกจากรายการ: ' + value : 'ไม่พบสกิลที่เลือกแล้ว กรุณาโหลดรายการใหม่: ' + value);
  });
}
module.exports = { discoverSkills, resolveSkills };
