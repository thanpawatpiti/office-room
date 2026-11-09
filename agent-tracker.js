'use strict';

// Track only observed agent lifecycles, never infer agents from regular tool calls.
function claudeMembers(members, ev) {
  let changed = false;
  const add = (id, label) => { if (id && !members[id]) { members[id] = { id, agent: 'claude', label: label || 'Agent' }; changed = true; } };
  const remove = (id) => { if (id && members[id]) { delete members[id]; changed = true; } };
  if (ev.type === 'stream_event' && ev.event?.type === 'content_block_start') {
    const b = ev.event.content_block || {}; if (b.type === 'tool_use' && ['Agent', 'Task'].includes(b.name)) add(b.id);
  }
  if (ev.type === 'assistant') for (const b of ev.message?.content || []) {
    if (b.type === 'tool_use' && ['Agent', 'Task'].includes(b.name)) add(b.id, b.input?.description || b.input?.subagent_type);
  }
  if (ev.type === 'user') for (const b of ev.message?.content || []) if (b.type === 'tool_result' && !members[b.tool_use_id]?.background) remove(b.tool_use_id);
  if (ev.type === 'system' && ev.subtype === 'task_started') {
    const id = ev.tool_use_id;
    if (id && (members[id] || /agent/i.test(ev.task_type || ''))) {
      add(id, ev.description); members[id].background = true; members[id].taskId = ev.task_id;
    }
  }
  if (ev.type === 'system' && ev.subtype === 'task_notification') {
    const id = ev.tool_use_id || Object.keys(members).find(k => members[k].taskId === ev.task_id);
    remove(id);
  }
  return changed;
}
function codexMembers(members, item) {
  let changed = false;
  const add = (id) => { if (id && !members[id]) { members[id] = { id, agent: 'codex', label: 'Agent' }; changed = true; } };
  const remove = (id) => { if (id && members[id]) { delete members[id]; changed = true; } };
  if (item.type === 'subAgentActivity') {
    if (item.kind === 'started' || item.kind === 'interacted') add(item.agentThreadId);
    if (item.kind === 'completed' || item.kind === 'interrupted') remove(item.agentThreadId);
  }
  if (item.type === 'collabAgentToolCall') {
    if (['spawnAgent', 'resumeAgent', 'followupTask'].includes(item.tool)) for (const id of item.receiverThreadIds || []) add(id);
    if (['closeAgent', 'interruptAgent'].includes(item.tool) && item.status !== 'inProgress') for (const id of item.receiverThreadIds || []) remove(id);
    for (const [id, state] of Object.entries(item.agentsStates || {})) {
      if (['pendingInit', 'running'].includes(state.status)) add(id);
      if (['completed', 'interrupted', 'errored', 'shutdown', 'notFound'].includes(state.status)) remove(id);
    }
  }
  return changed;
}
module.exports = { claudeMembers, codexMembers };
