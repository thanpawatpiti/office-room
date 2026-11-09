'use strict';
// Built-in transport fixtures only: no provider calls or real credentials.
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');
const id = path.basename(process.argv[1]);
const root = process.env.OFFICE_WORKFLOW_DIR;
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const record = value => fs.appendFileSync(path.join(root, 'calls.jsonl'), JSON.stringify({ id, ...value }) + '\n');
const caseName = text => (text.match(/CASE:([a-z-]+)/) || [])[1];
const report = extra => ({ summary: 'Fixture work checked', checks: [{ name: 'Fixture check', result: 'passed', evidence: 'Fixture result, not real inference' }], remaining: [], ...extra });
const answer = (next, text = 'Fixture result') => text + ' [[NEXT ' + JSON.stringify(next) + ']]';
function coordinator(prompt) {
  const name = caseName(prompt.split('TASK: ')[1] || prompt);
  const catalog = JSON.parse(prompt.split('Available catalog: ')[1].split('\nTASK:')[0]);
  const lead = (prompt.match(/user chose lead ([\w-]+)/) || [])[1] || catalog.find(member => member.ready).id;
  return { lead, model: lead === 'claude' ? 'opus' : 'fixture-model', effort: 'low', assignment: 'CASE:' + name + ' PHASE_ONE', reason: 'fixture transport check', summary: name, first_step: 'inspect fixture' };
}
function worker(prompt, mode, session, images = []) {
  const stateFile = path.join(root, session + '.json');
  const state = fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile)) : { count: 0 };
  const name = caseName(prompt) || state.name;
  if (name !== state.name) state.count = 0;
  state.count++; state.name = name; fs.writeFileSync(stateFile, JSON.stringify(state));
  record({ type: 'worker', name, count: state.count, prompt, mode, images, session });
  const complete = extra => ({ to: 'done', completion: report(extra) });
  const approve = { to: 'user', kind: 'approve', then: id, model: id === 'claude' ? 'opus' : 'fixture-model', effort: 'low' };
  if (['approval', 'reuse', 'write-error', 'write-limit', 'cancel', 'review-needed', 'stale-review'].includes(name) && id === 'claude' && state.count === 1) return { text: answer(approve, 'Scoped fixture plan: update one fixture file; verify its contents.' + (name === 'write-error' ? '\nPLAN_DETAIL_KEEP_ONCE'.repeat(200) : '')) };
  if (name === 'structured-question' && state.count === 1) return { text: answer({to:'user',kind:'ask',questions:[{id:'target',question:'ทำที่ไหน?',options:[{label:'macOS',description:'แอปในเครื่อง'},{label:'Web'}]}]}) };
  if (name === 'write-error' && mode === 'write') {
    fs.appendFileSync('partial.txt', 'once\n');
    return { text: '', error: 'fixture worker crashed after a write' };
  }
  if (name === 'write-error' && mode === 'read' && state.count === 3) return { text: answer({ to: id, model: 'opus', effort: 'low', mode: 'read', assignment: 'CASE:write-error finish recovery inspection', reason: 'finish recovery without replaying WRITE' }) };
  if (name === 'write-limit' && mode === 'write') { fs.appendFileSync('partial-limit.txt', 'once\n'); return { text: '', error: 'usage limit' }; }
  if (name === 'write-limit' && id === 'codex') return { text: answer({ ...complete(), review: { revision: +(prompt.match(/\[room change revision\] (\d+)/) || [])[1], status: 'passed', evidence: 'Fixture READ inspection of partial WRITE' } }) };
  if (mode === 'write') fs.writeFileSync('approved.txt', name);
  if (name === 'cancel' || name === 'reuse' || name === 'write-error') return { text: answer({ to: 'user', kind: 'ask', questions: [{ id: 'next', question: 'ทำอะไรต่อ?', options: [] }] }) };
  // Asks without structured questions: once fixed after the room's reminder, once never fixed.
  if (name === 'unstructured-ask' && state.count === 2) return { text: answer({ to: 'user', kind: 'ask', questions: [{ id: 'drink', question: 'ชอบเครื่องดื่มแบบไหน?', options: [{ label: 'ชา' }, { label: 'กาแฟ' }] }] }) };
  if (name === 'unstructured-ask' || name === 'stubborn-ask') return { text: answer({ to: 'user', kind: 'ask' }, 'ชอบเครื่องดื่มแบบไหน? 1) ชา 2) กาแฟ') };
  if (name === 'assignment') {
    if (id === 'codex' && state.count === 1) return { text: answer({ to: 'claude', model: 'opus', effort: 'low', mode: 'read', assignment: 'CASE:assignment intermediate review', reason: 'distinct review' }, 'Please continue') };
    if (id === 'claude') return { text: answer({ to: 'codex', model: 'fixture-model', effort: 'high', mode: 'read', assignment: 'CASE:assignment PHASE_TWO_ONLY_IN_FOOTER', reason: 'finish the distinct second phase' }, 'Please continue') };
  }
  if (name === 'review-needed' && id === 'claude' && mode === 'read') return { text: answer({ to: 'codex', model: 'fixture-model', effort: 'high', mode: 'read', assignment: 'CASE:review-needed review the fixture change', reason: 'independent review' }) };
  if (name === 'stale-review' && id === 'claude' && mode === 'write') return { text: answer({ to: 'codex', model: 'fixture-model', effort: 'low', mode: 'read', assignment: 'CASE:stale-review review the fixture change', reason: 'independent review' }) };
  if (['review-needed', 'stale-review'].includes(name) && id === 'codex') {
    const revision = +(prompt.match(/\[room change revision\] (\d+)/) || [])[1];
    return { text: answer({ ...complete(), review: { revision: name === 'stale-review' ? revision - 1 : revision, status: 'passed', evidence: 'Read and checked the fixture diff' } }) };
  }
  if (name === 'missing-completion') return { text: answer({ to: 'done' }) };
  if (name === 'failed-check') return { text: answer(complete({ checks: [{ name: 'Required check', result: 'failed', evidence: 'Fixture failure' }], remaining: ['Fix the fixture failure'] })) };
  if (name === 'optional') return { text: answer(complete({ checks: [{ name: 'Inspection', result: 'passed', evidence: 'Inspected the fixture' }, { name: 'Paid inference', result: 'not_run', required: false, evidence: 'Outside fixture scope' }] })) };
  return { text: answer(complete(mode === 'write' && name !== 'review-needed' ? { review: { status: 'not_required', reason: 'One trivial fixture file write with a content check' } } : {})), contextCase: name?.startsWith('context'), delay: name?.startsWith('late-') || name === 'steer-fail' || name === 'live-steer' ? 350 : 20 };
}
if (process.argv.includes('--version')) { console.log(id + ' fixture'); process.exit(0); }
if (process.argv.includes('auth')) { console.log(JSON.stringify({ loggedIn: true })); process.exit(0); }
if (process.argv.includes('login')) { console.log('Logged in using ChatGPT'); process.exit(0); }
if (id === 'codex' && !process.argv.includes('exec')) {
  let nextThread = 0;
  const threads = new Map();
  readline.createInterface({ input: process.stdin }).on('line', line => {
    const m = JSON.parse(line), p = m.params || {};
    if (m.id === undefined) return;
    if (m.method === 'model/list') return emit({ id: m.id, result: { data: [{ id: 'fixture-model', model: 'fixture-model', isDefault: true, defaultReasoningEffort: 'low', supportedReasoningEfforts: [{ reasoningEffort: 'low' }, { reasoningEffort: 'high' }] }], nextCursor: null } });
    if (m.method === 'account/read') return emit({ id: m.id, result: { account: { type: 'chatgpt' } } });
    if (m.method === 'thread/start') {
      const tid = 'fixture-' + (++nextThread); threads.set(tid, {}); record({ type: 'thread', tid });
      return emit({ id: m.id, result: { thread: { id: tid } } });
    }
    if (m.method === 'turn/steer') {
      record({ type: 'steer', input: p.input });
      if (threads.get(p.threadId)?.name === 'steer-fail') return emit({ id: m.id, error: { message: 'fixture steer rejected' } });
      return emit({ id: m.id, result: {} });
    }
    if (m.method === 'turn/start') {
      const prompt = p.input.filter(i => i.type === 'text').map(i => i.text).join('\n');
      const result = worker(prompt, p.sandboxPolicy?.type === 'workspaceWrite' ? 'write' : 'read', p.threadId, p.input.filter(i => i.type === 'localImage'));
      threads.get(p.threadId).name = caseName(prompt) || threads.get(p.threadId).name;
      emit({ id: m.id, result: { turn: { id: p.threadId + '-turn' } } });
      setTimeout(() => {
        if (result.contextCase) emit({ method: 'thread/tokenUsage/updated', params: { threadId: p.threadId, tokenUsage: { total: { inputTokens: 5000, cachedInputTokens: 0, outputTokens: 50 }, last: { inputTokens: 200000 } } } });
        emit({ method: 'item/completed', params: { threadId: p.threadId, item: { id: 'answer', type: 'agentMessage', text: result.text } } });
        emit({ method: 'turn/completed', params: { threadId: p.threadId, turn: result.error ? { status: 'failed', error: { message: result.error } } : { status: 'completed' } } });
      }, result.delay || 20);
      return;
    }
    return emit({ id: m.id, result: {} });
  });
} else if (process.argv.includes('--input-format')) {
  readline.createInterface({ input: process.stdin }).on('line', line => {
    const m = JSON.parse(line);
    if (m.type === 'control_request') return emit({ type: 'control_response', response: { subtype: 'success', response: { models: [{ value: 'opus', isDefault: true, supportsEffort: true, supportedEffortLevels: ['low', 'high'] }] } } });
    if (m.type === 'user') runClaude(m.message.content.filter(i => i.type === 'text').map(i => i.text).join('\n'), m.message.content.filter(i => i.type === 'image'));
  });
} else {
  let prompt = '';
  process.stdin.on('data', data => prompt += data);
  process.stdin.on('end', () => {
    if (process.cwd().endsWith('/data')) {
      const pick = JSON.stringify(coordinator(prompt));
      // Coordinator quota: Codex 1000 input - 900 cached + 7 output = 107; Claude 10 + 5 + 100 cache writes = 115.
      const send = () => {
        if (id === 'codex') { emit({ type: 'item.completed', item: { type: 'agent_message', text: pick } }); return emit({ type: 'turn.completed', usage: { input_tokens: 1000, cached_input_tokens: 900, output_tokens: 7 } }); }
        return emit({ type: 'result', result: pick, usage: { input_tokens: 10, output_tokens: 5, cache_creation_input_tokens: 100 } });
      };
      // brief-stop: ignore SIGTERM and finish late, so the user's stop lands mid-call but the call still spends quota.
      if (caseName(prompt.split('TASK: ')[1] || prompt) === 'brief-stop') { process.on('SIGTERM', () => { send(); process.exit(0); }); fs.writeFileSync(path.join(root, 'brief-stop.ready'), '1'); return setTimeout(() => process.exit(1), 30000); }
      return send();
    }
    runClaude(prompt);
  });
}
function runClaude(prompt, images = []) {
  const resume = process.argv.indexOf('--resume');
  const session = resume >= 0 ? process.argv[resume + 1] : 'claude-' + process.pid;
  const mode = process.argv.includes('--safe-mode') ? 'read' : 'write';
  const result = worker(prompt, mode, session, images);
  setTimeout(() => {
    if (result.contextCase) emit({ type: 'assistant', message: { usage: { input_tokens: 5, cache_read_input_tokens: 150000, cache_creation_input_tokens: 100 }, content: [] } });
    emit({ type: 'result', result: result.error || result.text, is_error: !!result.error, session_id: session });
    process.exit(result.error ? 1 : 0);
  }, result.delay || 20);
}
