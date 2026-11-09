'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const hash = file => {
  try { const st = fs.lstatSync(file); if (st.isSymbolicLink()) return 'link:' + fs.readlinkSync(file); if (!st.isFile()) return 'directory'; return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') + ':' + (st.mode & 0o777); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
};
function manifest(dir, result = Object.create(null), prefix = '') {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === '.git' || entry.name === '.office-workflow' || entry.name === '.office-task-tmp') continue;
    const rel = path.join(prefix, entry.name), file = path.join(dir, entry.name);
    if (entry.isDirectory()) manifest(file, result, rel); else result[rel] = hash(file);
  }
  return result;
}
function noSymlinks(file, root) {
  let current = root;
  if (fs.lstatSync(current).isSymbolicLink()) throw Error('โฟลเดอร์โปรเจกต์ต้องไม่เป็น symbolic link');
  for (const part of path.relative(root, file).split(path.sep).filter(Boolean)) {
    current = path.join(current, part);
    try { if (fs.lstatSync(current).isSymbolicLink()) throw Error('ไม่รวมไฟล์ผ่าน symbolic link: ' + current); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
function prepare(dirs) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'office-task-'));
  const roots = [];
  try {
    dirs.forEach((original, index) => {
      const copy = path.join(base, String(index));
      fs.cpSync(original, copy, { recursive: true, verbatimSymlinks: true, filter: file => !['.git', '.office-workflow', '.office-task-tmp'].includes(path.basename(file)) });
      roots.push({ original, copy, before: manifest(copy) });
    });
    return { base, roots };
  } catch (error) { fs.rmSync(base, { recursive: true, force: true }); throw error; }
}
function changes(workspace, files) {
  const result = [];
  for (const root of workspace.roots) {
    const after = manifest(root.copy);
    for (const rel of new Set([...Object.keys(root.before), ...Object.keys(after)])) {
      if (root.before[rel] === after[rel]) continue;
      const target = path.join(root.original, rel), source = path.join(root.copy, rel);
      if (!files.some(f => target === f || target.startsWith(f + path.sep))) throw Error('แก้นอกขอบเขต task: ' + target);
      noSymlinks(target, root.original); noSymlinks(source, root.copy);
      if ((after[rel] || '').startsWith('link:')) throw Error('ไม่รวม symbolic link ใหม่');
      if (hash(target) !== (root.before[rel] || null)) throw Error('ไฟล์ต้นฉบับเปลี่ยนระหว่างทำงาน: ' + target);
      result.push({ target, source, deleted: !after[rel] });
    }
  }
  return result;
}
// Validate the entire change set before touching originals; rollback if an I/O step fails.
function integrate(workspace, files) {
  const edits = changes(workspace, files), applied = [];
  try {
    for (const edit of edits) {
      const old = hash(edit.target) === null ? null : { data: fs.readFileSync(edit.target), mode: fs.statSync(edit.target).mode };
      applied.push({ ...edit, old });
      if (edit.deleted) fs.unlinkSync(edit.target);
      else { fs.mkdirSync(path.dirname(edit.target), { recursive: true }); fs.copyFileSync(edit.source, edit.target); fs.chmodSync(edit.target, fs.statSync(edit.source).mode); }
    }
  } catch (error) {
    for (const edit of applied.reverse()) {
      if (edit.old) { fs.writeFileSync(edit.target, edit.old.data); fs.chmodSync(edit.target, edit.old.mode); }
      else fs.rmSync(edit.target, { force: true });
    }
    throw error;
  }
  return edits.map(e => e.target);
}
module.exports = { prepare, changes, integrate, manifest, noSymlinks };
