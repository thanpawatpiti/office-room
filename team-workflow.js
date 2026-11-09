'use strict';
const path = require('node:path');
const crypto = require('node:crypto');
const text = (v, max = 2000) => typeof v === 'string' && v.trim() && v.length <= max;

function questions(input) {
  if (!Array.isArray(input) || !input.length || input.length > 20) throw Error('รายการคำถามไม่ถูกต้อง');
  const ids = new Set();
  return input.map((q, index) => {
    const id = q.id || `q${index + 1}`;
    if (!text(id, 100) || ids.has(id) || !text(q.question) || (q.multiSelect !== undefined && typeof q.multiSelect !== 'boolean')) throw Error('คำถามต้องมีรหัสไม่ซ้ำและข้อความ');
    ids.add(id);
    const options = q.options || [];
    if (!Array.isArray(options) || options.length > 10) throw Error('ตัวเลือกไม่ถูกต้อง');
    const labels = new Set();
    const clean = options.map((o, n) => {
      if (!text(o.label, 200) || labels.has(o.label) || (o.description !== undefined && typeof o.description !== 'string')) throw Error('ตัวเลือกต้องมีชื่อไม่ซ้ำ');
      labels.add(o.label);
      return { id: `o${n + 1}`, label: o.label, description: (o.description || '').slice(0, 2000) };
    });
    return { id, question: q.question, header: String(q.header || '').slice(0, 40), options: clean, multiSelect: q.multiSelect === true };
  });
}
function makeQuestion(from, input, extra = {}) {
  return { ...extra, id: crypto.randomUUID(), from, status: 'pending', questions: questions(input), createdAt: Date.now() };
}
function answerQuestion(prompt, input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw Error('คำตอบไม่ถูกต้อง');
  const answers = Object.create(null);
  for (const q of prompt.questions) {
    const a = input[q.id];
    if (!a || !Array.isArray(a.selected) || a.selected.some(id => !q.options.some(o => o.id === id)) || new Set(a.selected).size !== a.selected.length || (!q.multiSelect && a.selected.length > 1) || (a.text !== undefined && typeof a.text !== 'string')) throw Error('กรุณาตอบคำถามให้ถูกต้อง');
    const custom = (a.text || '').trim();
    if ((!a.selected.length && !custom) || custom.length > 12000) throw Error('กรุณาตอบทุกข้อ');
    answers[q.id] = { selected: a.selected, text: custom };
  }
  // A retry is harmless only if it repeats the same accepted decision.
  if (prompt.status === 'answered') {
    if (JSON.stringify(prompt.answers) !== JSON.stringify(answers)) throw Error('คำถามนี้ตอบแล้ว');
    return false;
  }
  if (prompt.status !== 'pending') throw Error('คำถามนี้หมดอายุแล้ว');
  prompt.status = 'answered'; prompt.answers = answers; prompt.answeredAt = Date.now();
  return true;
}
function answerText(prompt) {
  return prompt.questions.map(q => {
    const a = prompt.answers[q.id];
    return `${q.question}\n${[...a.selected.map(id => q.options.find(o => o.id === id).label), a.text].filter(Boolean).join(', ')}`;
  }).join('\n\n');
}
function validateTasks(input, dirs, members) {
  if (!Array.isArray(input) || !input.length || input.length > 50) throw Error('ต้องมีรายการงาน');
  const ids = new Set();
  const tasks = input.map(t => {
    if (!text(t.id, 80) || !/^[a-zA-Z0-9_-]+$/.test(t.id) || ids.has(t.id) || !members.includes(t.owner) || !text(t.assignment) || !text(t.reason) || !Array.isArray(t.files) || !t.files.length || t.files.length > 1000 || !Array.isArray(t.dependsOn || [])) throw Error('งานต้องมีรหัส เจ้าของ ขอบเขตไฟล์ และคำอธิบาย');
    ids.add(t.id);
    const files = t.files.map(f => {
      if (!text(f, 2000) || !path.isAbsolute(f)) throw Error('ขอบเขตไฟล์ต้องเป็น absolute path');
      const resolved = path.resolve(f);
      if (!dirs.some(d => resolved.startsWith(path.resolve(d) + path.sep)) || resolved.split(path.sep).some(p => ['.git', '.office-workflow', '.office-task-tmp'].includes(p))) throw Error('ไฟล์อยู่นอกโปรเจกต์หรือเป็น metadata');
      return resolved;
    });
    return { id: t.id, owner: t.owner, assignment: t.assignment, reason: t.reason, model: t.model, effort: t.effort, files: [...new Set(files)], dependsOn: [...new Set(t.dependsOn || [])], status: 'pending', revision: 0 };
  });
  const visiting = new Set(), visited = new Set();
  function visit(t) {
    if (visiting.has(t.id)) throw Error('งานรอกันเป็นวง');
    if (visited.has(t.id)) return;
    visiting.add(t.id);
    for (const id of t.dependsOn) { const dep = tasks.find(x => x.id === id); if (!dep) throw Error('ไม่พบงานที่ต้องรอ'); visit(dep); }
    visiting.delete(t.id); visited.add(t.id);
  }
  tasks.forEach(visit);
  return tasks;
}
const overlaps = (a, b) => a === b || a.startsWith(b + path.sep) || b.startsWith(a + path.sep);
function runnable(tasks) {
  const busy = tasks.filter(t => ['running', 'waiting'].includes(t.status));
  const chosen = [];
  for (const t of tasks) {
    if (t.status !== 'pending' || !t.dependsOn.every(id => tasks.find(x => x.id === id)?.status === 'done')) continue;
    if ([...busy, ...chosen].some(x => x.owner === t.owner || x.files.some(a => t.files.some(b => overlaps(a, b))))) continue;
    chosen.push(t);
  }
  return chosen;
}
module.exports = { questions, makeQuestion, answerQuestion, answerText, validateTasks, runnable, overlaps };
