'use strict';
const fs = require('node:fs');
const workspace = require('./task-workspace');
const { runnable, makeQuestion, overlaps } = require('./team-workflow');
const { parseNext, validateCompletion } = require('./agent-registry');

// Host owns transports and room persistence; this scheduler owns task state and integration.
module.exports = function teamRuntime(host) {
  const active = new Map();
  const complete = next => {
    const report = validateCompletion(next?.completion);
    if (report.remaining.length || !report.checks.some(c => c.required && c.result === 'passed') || report.checks.some(c => c.required && c.result !== 'passed')) throw Error('ผลตรวจ task ยังไม่ครบ');
    return report;
  };
  async function execute(r, t) {
    t.status = 'running'; r.workflow.phase = 'working'; host.save(r);
    try {
      if (!t.workspace) t.workspace = workspace.prepare(r.dirs);
      const result = await host.run(r, t, 'write', t.owner, t.workspace.roots.map(x => x.copy), t.feedback || 'Implement only the approved task. Do not edit other task scopes.');
      if (result.error || result.killed) throw Error(result.error || 'หยุดระหว่างทำงาน ตรวจผลบางส่วนก่อนลองใหม่');
      const { body, next } = parseNext(result.text);
      host.post(r, t.owner, body, { taskId: t.id, mode: 'write' }, t.live?.steps);
      if (next?.to === 'user') {
        if (next.kind === 'approve') throw Error('task ขอเปลี่ยนขอบเขต ต้องอนุมัติแผนใหม่');
        if (!next.questions) throw Error('task ต้องส่งคำถามแบบแยกข้อ');
        r.questions.push(makeQuestion(t.owner, next.questions, { source: 'room', taskId: t.id }));
        t.status = 'waiting'; return;
      }
      if (next?.to !== 'done') throw Error('task ยังไม่ส่งผลตรวจเพื่อรวมงาน');
      t.completion = complete(next);
      if (!host.authorized(r)) throw Error('สิทธิ์อนุมัติหมดอายุ ยังไม่รวมไฟล์');
      t.changedFiles = workspace.integrate(t.workspace, t.files);
      t.revision++; r.changeRevision = (r.changeRevision || 0) + 1;
      r.lastWriter = t.owner; r.review = null; r.completion = null;
      t.status = 'review'; t.feedback = null;
      for(const prior of r.workflow.tasks) if(prior!==t && prior.status==='done' && prior.files.some(a=>t.changedFiles.some(b=>overlaps(a,b)))) { prior.status='review'; prior.review=null; }
      host.diff(r);
    } catch (error) { t.status = 'failed'; t.error = error.message; }
    finally { t.live = null; host.save(r); }
  }
  async function review(r, t) {
    const reviewer = host.members().find(id => id !== t.owner && host.available(id));
    if (!reviewer) { t.error = 'รอผู้ตรวจอิสระที่พร้อม'; return; }
    t.reviewer = reviewer; t.status = 'running'; r.workflow.phase = 'review'; host.save(r);
    try {
      const result = await host.run(r, t, 'read', reviewer, t.recovering && t.workspace ? t.workspace.roots.map(x=>x.copy) : r.dirs,
        `Independently review task ${t.id}, revision ${t.revision}, files ${JSON.stringify(t.files)}. The task owner is ${t.owner}. Inspect connected code and task diff at ${t.workspace.base}. Return to=done with review:{revision:${t.revision},status:passed|changes_requested,evidence:string} and completion. Do not edit.`);
      if (result.error || result.killed) throw Error(result.error || 'หยุดรีวิว');
      const {body,next} = parseNext(result.text);
      host.post(r, reviewer, body, { taskId:t.id, mode:'read', review:true }, t.live?.steps);
      if (!next?.review || next.review.revision !== t.revision || !['passed','changes_requested'].includes(next.review.status) || !String(next.review.evidence || '').trim()) throw Error('ไม่มีผลรีวิวฉบับปัจจุบัน');
      if(!host.authorized(r) || r.workflow.stopped) throw Error('พักงานแล้ว ยังไม่รับผลรีวิว');
      t.review = { ...next.review, by:reviewer };
      if (t.recovering) { t.recovering=false; t.status='pending'; t.feedback='The partial workspace was inspected in READ. Continue from existing effects; do not replay writes blindly. Review evidence: '+t.review.evidence; return; }
      if (t.review.status === 'changes_requested') {
        t.feedback = t.review.evidence;
        fs.rmSync(t.workspace.base,{recursive:true,force:true}); t.workspace = null; t.context = null;
        t.status = 'pending';
      } else { complete(next); t.status = 'done'; }
    } catch (error) { t.status = 'failed'; t.error = error.message; }
    finally { t.reviewer = null; t.live = null; host.save(r); }
  }
  async function verify(r) {
    r.workflow.phase = 'testing'; host.save(r);
    const choice=r.workflow.tasks.find(t=>t.owner===r.lead) || {};
    const t = {id:'integrated-check',owner:r.lead,model:choice.model,effort:choice.effort,files:r.dirs,revision:r.changeRevision};
    let checked;
    const testedRevision=r.changeRevision;
    try {
      checked=workspace.prepare(r.dirs);
      const result = await host.run(r,t,'write',r.lead,checked.roots.map(x=>x.copy),'All tasks have independent reviews. Run meaningful integration checks on the combined project. Do not modify project files. Return to=done with completion summary/checks/remaining. Report unavailable checks as not_run; never claim a pass.');
      if (result.error || result.killed) throw Error(result.error || 'หยุดทดสอบ');
      const {body,next}=parseNext(result.text); host.post(r,r.lead,body,{mode:'read',integrated:true},t.live?.steps);
      if (next?.to !== 'done') throw Error('ผลทดสอบรวมยังไม่ครบ');
      const report=complete(next);
      if (!host.authorized(r) || testedRevision!==r.changeRevision) throw Error('งานเปลี่ยนขอบเขตระหว่างทดสอบ ต้องตรวจแผน');
      for (const root of checked.roots) if (JSON.stringify(workspace.manifest(root.original))!==JSON.stringify(root.before)) throw Error('ไฟล์โปรเจกต์เปลี่ยนระหว่างทดสอบ ต้องตรวจฉบับใหม่');
      if (r.questions.some(q=>q.status==='pending')) throw Error('ยังมีคำถามค้าง');
      r.completion={...report,by:r.lead,at:Date.now(),review:{status:'passed',revision:r.changeRevision,tasks:r.workflow.tasks.map(t=>({id:t.id,review:t.review}))}};
      r.workflow.phase='delivered'; r.status='done'; r.waiting=null; r.approved=false; r.approval=null;
      host.post(r,'system','งานเสร็จตามผลรีวิวราย task และผลทดสอบรวมที่ทีมรายงาน');
    } catch(error) { r.status='waiting'; r.waiting={kind:'verify',from:r.lead}; host.post(r,'system','ยังส่งมอบไม่ได้: '+error.message); }
    if(checked) fs.rmSync(checked.base,{recursive:true,force:true});
    host.save(r);
  }
  function pump(r) {
    if (active.has(r.id) || !host.authorized(r) || r.workflow?.stopped || r.status === 'done') return;
    const running = new Set(); active.set(r.id,running);
    function schedule() {
      if (!host.authorized(r) || r.workflow.stopped || !host.exists(r)) { if (!running.size) active.delete(r.id); return; }
      const tasks=r.workflow.tasks;
      const busyOwners=new Set(tasks.filter(t=>t.status==='running').map(t=>t.reviewer || t.owner));
      const launches = runnable(tasks).filter(t=>host.available(t.owner) && !busyOwners.has(t.owner)).map(t=>({t,fn:execute}));
      // A review observes the combined project. Wait until writers settle before reviewing it.
      if (!running.size && !launches.length) {
        const t=tasks.find(t=>t.status==='review' && host.members().some(id=>id!==t.owner && host.available(id)));
        if(t) launches.push({t,fn:review});
      }
      for(const {t,fn} of launches) {
        const key=t.id; running.add(key);
        // execute/review synchronously reserves status before their first await.
        fn(r,t).finally(()=>{running.delete(key);schedule();});
      }
      if (running.size) {r.status='running';r.waiting=null;host.save(r);return;}
      active.delete(r.id);
      if(tasks.every(t=>t.status==='done')) { active.set(r.id,running); verify(r).finally(()=>active.delete(r.id)); return; }
      r.status='waiting';r.waiting={kind:tasks.some(t=>t.status==='waiting')?'ask':'retry',from:r.lead};host.save(r);
    }
    r.workflow.phase='working'; schedule();
  }
  return {pump, active};
};
