'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const inProcessServer = require('./fixtures/in-process-server');
const { validateCompletion } = require('../agent-registry');
assert.throws(() => validateCompletion(null));
assert.throws(() => validateCompletion({ summary: 'x', checks: [{ name: 'test', result: 'passed' }], remaining: [] }));
assert.throws(() => validateCompletion({ summary: 'x', checks: [], remaining: [123] }));
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'office-workflow-'));
const bin = path.join(temp, 'bin'); fs.mkdirSync(bin);
for (const file of ['server.js', 'team-workflow.js','team-runtime.js','task-workspace.js', 'agent-registry.js', 'agent-tracker.js', 'claude-usage.js','codex-usage.js', 'image-attachments.js', 'skill-catalog.js']) fs.copyFileSync(path.join(__dirname, '..', file), path.join(temp, file));
// Keep account polling entirely inside the fixture as well.
fs.writeFileSync(path.join(temp, 'claude-usage.js'), 'module.exports={createUsageReader:()=>async()=>[]}');
const fixture = fs.readFileSync(path.join(__dirname, 'fixtures/workflow-cli.js'), 'utf8');
for (const id of ['claude', 'codex']) fs.writeFileSync(path.join(bin, id), '#!' + process.execPath + '\n' + fixture, { mode: 0o755 });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const calls = () => fs.existsSync(path.join(temp, 'calls.jsonl')) ? fs.readFileSync(path.join(temp, 'calls.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
(async () => {
  const originalPath = process.env.PATH, originalFixture = process.env.OFFICE_WORKFLOW_DIR;
  process.env.PATH = bin + ':/usr/bin:/bin'; process.env.OFFICE_WORKFLOW_DIR = temp;
  const server = inProcessServer(temp, { legacyWorkflow: true });
  async function request(route, body) {
    const { status, value } = await server.request(route, body); assert(status >= 200 && status < 300, JSON.stringify(value)); return value;
  }
  async function until(predicate) { for (let n = 0; n < 160; n++) { const value = await predicate(); if (value) return value; await delay(30); } throw Error('Fixture timed out: ' + server.errors.join('\n')); }
  const room = id => request('/api/rooms/' + id);
  const wait = async (id, status, kind) => {
    try { return await until(async () => { const r = await room(id); return r.status === status && (!kind || r.waiting?.kind === kind) && r; }); }
    catch (error) { throw new Error(error.message + '\nLast room: ' + JSON.stringify(await room(id))); }
  };
  const action = (id, action) => request('/api/rooms/' + id + '/decide', { action });
  async function create(name, lead = 'claude') {
    const project = path.join(temp, 'project-' + name); fs.mkdirSync(project);
    return request('/api/rooms', { task: 'CASE:' + name, dirs: [project], lead });
  }
  try {
    await until(async () => { try { return await request('/api/ping'); } catch { return false; } });
    const qr = await create('structured-question');
    const asking = await wait(qr.id, 'waiting', 'ask');
    const question = asking.questions[0];
    assert.equal(question.status, 'pending');
    const bad = await server.request('/api/rooms/' + qr.id + '/answer', {questionId:question.id,answers:{target:{selected:['invalid']}}});
    assert.equal(bad.status,400);
    const answerBody = {questionId:question.id,answers:{target:{selected:['o1']}}};
    await request('/api/rooms/' + qr.id + '/answer',answerBody);
    const answered = await wait(qr.id,'done');
    await request('/api/rooms/' + qr.id + '/answer',answerBody);
    assert.equal((await room(qr.id)).messages.filter(m=>m.meta?.questionId===question.id).length,1);
    assert.equal(answered.questions[0].answers.target.selected[0],'o1');
    console.log('Structured question HTTP answer validation, resume and duplicate submission passed');
    const loose = await create('unstructured-ask');
    const restated = await until(async () => { const r = await room(loose.id); return r.status === 'waiting' && r.questions?.length && r; });
    assert.equal(restated.waiting.kind, 'ask');
    assert.deepEqual(restated.questions[0].questions[0].options.map(o => o.label), ['ชา', 'กาแฟ']);
    const looseCalls = calls().filter(c => c.name === 'unstructured-ask' && c.type === 'worker');
    assert.equal(looseCalls.length, 2); assert(looseCalls[1].prompt.includes('no structured questions'));
    const stubborn = await create('stubborn-ask');
    const plain = await wait(stubborn.id, 'waiting', 'ask');
    await delay(100);
    assert.equal(calls().filter(c => c.name === 'stubborn-ask' && c.type === 'worker').length, 2, 'only one restate request, then the plain question');
    assert.equal(plain.questions.length, 0);
    console.log('Question without options is restated once as structured options, then falls back to text');
    for (const [name, agent] of [['late-claude', 'claude'], ['steer-fail', 'codex'], ['live-steer', 'codex']]) {
      const r = await create(name, agent);
      await until(() => calls().some(c => c.name === name && c.type === 'worker'));
      await delay(30); // Let turn/start acknowledge its ID before attempting steer.
      const marker = 'LATEST_USER_INSTRUCTION_' + name;
      let image;
      if (name === 'late-claude') image = await request('/api/images', { data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=' });
      await request('/api/rooms/' + r.id + '/message', { text: marker, images: image ? [image.id] : [] });
      const done = await wait(r.id, 'done');
      const workers = calls().filter(c => c.name === name && c.type === 'worker');
      assert.equal(workers.length, name === 'live-steer' ? 1 : 2, name + ': queued instructions must be processed once');
      if (name !== 'live-steer') assert(workers[1].prompt.includes(marker), name + ': worker must receive the queued instruction');
      if (image) { assert.equal(workers[0].images.length, 0); assert.equal(workers[1].images.length, 1, 'late image and its instruction must be delivered together'); }
      assert(done.messages.find(m => m.text === marker).deliveredTo.includes(agent));
    }
    console.log('Queued Claude messages, failed Codex steer and successful live steer passed');
    const assigned = await create('assignment', 'codex'); await wait(assigned.id, 'done');
    const phases = calls().filter(c => c.name === 'assignment' && c.id === 'codex' && c.type === 'worker');
    assert.equal(phases.length, 2); assert.equal(phases[0].session, phases[1].session);
    assert(phases[1].prompt.includes('PHASE_TWO_ONLY_IN_FOOTER'), 'loaded Codex thread must receive current assignment');
    console.log('Loaded Codex thread receives footer-only assignment updates passed');
    const assignedRoom = await room(assigned.id);
    const phaseTwo = assignedRoom.messages.find(m => m.meta?.assignment?.includes('PHASE_TWO_ONLY_IN_FOOTER'));
    assert.equal(phaseTwo.meta.effort, 'low', 'READ turn before any WRITE: requested high is lowered to the deepest allowed level at or below the medium cap');
    const coordinatorTokens = assignedRoom.coordinator === 'claude' ? 115 : 107;
    assert.equal(assignedRoom.usage.claude.tokens + assignedRoom.usage.codex.tokens, coordinatorTokens, 'coordinator call tokens are counted once');
    console.log('READ effort cap and coordinator usage passed');
    for (const [name, agent, expectedCtx] of [['context-codex', 'codex', 200000], ['context-claude', 'claude', 150105]]) {
      const c = await create(name, agent); const contextDone = await wait(c.id, 'done');
      assert.equal(contextDone.usage[agent].ctx, expectedCtx);
      assert.equal(contextDone.messages.filter(m => m.from === 'system' && m.text.includes('บริบทของ ' + agent)).length, 1, name + ': one new-room advisory');
    }
    console.log('Long session context advisory passed');
    const stopRoom = await create('brief-stop', 'claude');
    await until(() => fs.existsSync(path.join(temp, 'brief-stop.ready'))); // fixture installed its SIGTERM handler
    await request('/api/rooms/' + stopRoom.id + '/stop', {});
    await wait(stopRoom.id, 'waiting', 'ask');
    const roomFile = path.join(temp, 'data/rooms', stopRoom.id + '.json');
    const savedUsage = () => { try { const u = JSON.parse(fs.readFileSync(roomFile, 'utf8')).usage; return Object.values(u).find(x => x.calls); } catch { return null; } };
    const persisted = await until(savedUsage); // the late coordinator result is booked and saved to disk
    assert.equal(persisted.calls, 1);
    const afterStop = await room(stopRoom.id);
    assert.equal(afterStop.status, 'waiting'); assert.equal(afterStop.waiting.kind, 'ask');
    assert(!calls().some(c => c.name === 'brief-stop' && c.type === 'worker'), 'stopped briefing result must not start a worker');
    const booked = afterStop.usage[afterStop.coordinator];
    assert.equal(booked?.calls, 1, 'stopped coordinator call is still booked once');
    assert.equal(booked.tokens, afterStop.coordinator === 'claude' ? 115 : 107);
    console.log('Stopped briefing keeps its usage but drops its result passed');
    const approved = await create('approval'); await wait(approved.id, 'waiting', 'approve'); await action(approved.id, 'approve');
    const closed = await wait(approved.id, 'done'); assert.equal(closed.approved, false); assert.equal(closed.approval, null);
    await request('/api/rooms/' + approved.id + '/message', { text: 'CASE:reuse' });
    const reused = await wait(approved.id, 'waiting', 'approve'); assert.equal(reused.approved, false); assert.equal(reused.base, null); assert.equal(reused.taskRevision, 1);
    assert(calls().filter(c => c.name === 'reuse' && c.type === 'worker').every(c => c.mode === 'read'));
    const cancel = await create('cancel'); await wait(cancel.id, 'waiting', 'approve'); await action(cancel.id, 'approve'); await wait(cancel.id, 'waiting', 'ask');
    await action(cancel.id, 'cancel'); assert.equal((await room(cancel.id)).approved, false);
    console.log('Approval expires after done/cancel and reused rooms start READ passed');
    const failed = await create('write-error'); await wait(failed.id, 'waiting', 'approve'); await action(failed.id, 'approve');
    const stopped = await wait(failed.id, 'waiting', 'retry');
    assert.equal(stopped.waiting.opts.mode, 'read'); assert(stopped.checkpoint.note.includes('partial'));
    assert.equal(calls().filter(c => c.name === 'write-error' && c.mode === 'write').length, 1);
    assert.equal(fs.readFileSync(path.join(temp, 'project-write-error/partial.txt'), 'utf8'), 'once\n');
    await action(failed.id, 'retry'); await wait(failed.id, 'waiting', 'ask');
    const recoveryCalls = calls().filter(c => c.name === 'write-error' && c.type === 'worker');
    const recovery = recoveryCalls.find(c => c.count === 3);
    assert.equal(recovery.mode, 'read'); assert(recovery.prompt.includes('partial effects'));
    const following = recoveryCalls.at(-1);
    assert.equal(following.count, 4); assert(!following.prompt.includes('[room checkpoint]'), 'consumed recovery instructions must not persist');
    assert(recovery.prompt.includes('PLAN_DETAIL_KEEP_ONCE')); assert(!following.prompt.includes('PLAN_DETAIL_KEEP_ONCE'));
    const compactPlan = JSON.parse(following.prompt.split('[room approval] ')[1].split('\n')[0]);
    assert(compactPlan.unchanged && compactPlan.planHash && !compactPlan.plan, 'unchanged approved plan is referenced by hash');
    assert.equal(compactPlan.planField, 'approval.plan'); assert.equal(JSON.parse(fs.readFileSync(compactPlan.planFile)).approval.plan.includes('PLAN_DETAIL_KEEP_ONCE'), true, 'the full plan stays readable after context compaction');
    assert.equal((await room(failed.id)).checkpoint, null);
    console.log('Partial WRITE failure is not automatically replayed; retry inspects in READ passed');
    const missing = await create('missing-completion'); await wait(missing.id, 'waiting', 'verify');
    assert.equal(calls().filter(c => c.name === 'missing-completion' && c.type === 'worker').length, 2);
    const check = await create('failed-check'); const notDone = await wait(check.id, 'waiting', 'verify'); assert.equal(notDone.completion.checks[0].result, 'failed');
    const optional = await create('optional'); const optionalDone = await wait(optional.id, 'done'); assert.equal(optionalDone.completion.checks[1].required, false);
    console.log('Missing reports and failed required checks block done; optional limits stay visible passed');
    const reviewed = await create('review-needed'); await wait(reviewed.id, 'waiting', 'approve'); await action(reviewed.id, 'approve');
    const reviewedDone = await wait(reviewed.id, 'done'); assert.equal(reviewedDone.review.by, 'codex'); assert.equal(reviewedDone.review.revision, reviewedDone.changeRevision);
    assert.equal(reviewedDone.messages.find(m => m.from === 'codex' && m.meta?.assignment?.includes('review the fixture change')).meta.effort, 'high', 'review after a WRITE keeps the requested effort');
    const stale = await create('stale-review'); await wait(stale.id, 'waiting', 'approve'); await action(stale.id, 'approve');
    const staleWait = await wait(stale.id, 'waiting', 'verify'); assert.equal(staleWait.review, null);
    console.log('Independent review is tied to the latest WRITE revision; stale reviews rejected passed');
    const limitedWrite = await create('write-limit'); await wait(limitedWrite.id, 'waiting', 'approve'); await action(limitedWrite.id, 'approve');
    const recoveredLimit = await wait(limitedWrite.id, 'done');
    const takeover = calls().find(c => c.name === 'write-limit' && c.id === 'codex' && c.type === 'worker');
    assert.equal(takeover.mode, 'read'); assert(takeover.prompt.includes('[room checkpoint]')); assert.equal(recoveredLimit.checkpoint, null);
    assert.equal(fs.readFileSync(path.join(temp, 'project-write-limit/partial-limit.txt'), 'utf8'), 'once\n');
    console.log('Partial WRITE limit takeover starts READ and consumes the checkpoint passed');
    assert.deepEqual(server.errors, []);
  } finally {
    await server.close(); process.env.PATH = originalPath;
    if (originalFixture === undefined) delete process.env.OFFICE_WORKFLOW_DIR; else process.env.OFFICE_WORKFLOW_DIR = originalFixture;
  }
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => fs.rmSync(temp, { recursive: true, force: true }));
