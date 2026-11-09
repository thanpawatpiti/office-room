'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const { spawn, spawnSync } = require('node:child_process');
const { Registry, modelsFrom, validateChoice, capEffort, permittedModels, parseNext, executable, desktopCli } = require('../agent-registry');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'office-registry-'));
const project = path.join(temporary, 'project'); fs.mkdirSync(project);
const model = (id, efforts = ['low','high']) => ({ id, model:id, isDefault:true, defaultReasoningEffort:'low', supportedReasoningEfforts:efforts.map(reasoningEffort => ({reasoningEffort})) });
{ // desktop-app CLIs are found when nothing is on PATH
  const home = path.join(temporary, 'home'), bin = (f) => { fs.mkdirSync(path.dirname(f), { recursive:true }); fs.writeFileSync(f, '#!/bin/sh\n'); fs.chmodSync(f, 0o755); return fs.realpathSync(f); };
  assert.equal(desktopCli('claude', home), null); assert.equal(desktopCli('codex', home), null);
  const cc = path.join(home, 'Library/Application Support/Claude/claude-code');
  bin(path.join(cc, '2.1.9/claude.app/Contents/MacOS/claude')); const newest = bin(path.join(cc, '2.1.10/claude.app/Contents/MacOS/claude'));
  assert.equal(desktopCli('claude', home), newest, 'picks the newest bundled Claude Code');
  const codex = bin(path.join(home, 'Applications/Codex.app/Contents/Resources/codex'));
  assert.equal(desktopCli('codex', home), fs.existsSync('/Applications/Codex.app/Contents/Resources/codex') ? fs.realpathSync('/Applications/Codex.app/Contents/Resources/codex') : codex);
  assert.equal(desktopCli('gemini', home), null);
}
const record = { id:'third', models:modelsFrom([model('fixture')], 'codex') };
assert.equal(validateChoice(record, {}, { model:'fixture', effort:'high' }).effort, 'high');
assert.throws(() => validateChoice(record, {}, { model:'invented', effort:'high' }));
assert.throws(() => validateChoice(record, {}, { model:'fixture', effort:'ultra' }));
assert.throws(() => validateChoice(record, { maxEffort:'low' }, { model:'fixture', effort:'high' }));
assert.throws(() => validateChoice(record, { allowedEfforts:{fixture:['high']} }, { model:'fixture' }));
assert.deepEqual(permittedModels(record, { enabled:false }), []);
const deep = { id:'deep', models:modelsFrom([model('deep', ['low','medium','high','xhigh'])], 'codex') }, onlyHigh = { id:'oh', models:modelsFrom([model('oh', ['high'])], 'codex') };
assert.equal(capEffort(deep, {}, { model:'deep', effort:'xhigh' }, 'medium').effort, 'medium');
assert.equal(capEffort(record, {}, { model:'fixture', effort:'high' }, 'medium').effort, 'low', 'uses the deepest allowed level at or below the cap');
assert.equal(capEffort(deep, {}, { model:'deep', effort:'low' }, 'medium').effort, 'low', 'never raises');
assert.equal(capEffort(deep, {}, { model:'deep', effort:'medium' }, 'medium').effort, 'medium');
assert.equal(capEffort(deep, {}, { model:'deep', effort:'high' }, '').effort, 'high', 'empty cap disables');
assert.equal(capEffort(deep, {}, { model:'deep', effort:'high' }, 'bogus').effort, 'high', 'unknown cap is ignored');
assert.equal(capEffort(deep, {}, { model:'deep' }, 'medium').effort, undefined, 'runtime default is left alone');
assert.equal(capEffort(onlyHigh, {}, { model:'oh', effort:'high' }, 'medium').effort, 'high', 'no allowed level under the cap keeps the choice');
assert.equal(capEffort(deep, { allowedEfforts:{deep:['high','xhigh']} }, { model:'deep', effort:'xhigh' }, 'medium').effort, 'xhigh', 'user allow-list wins over the cap');
const unknown = { id:'unknown', models:modelsFrom([{value:'opaque'}], 'claude') };
assert.equal(validateChoice(unknown, {}, {model:'opaque'}).effort, undefined);
assert.throws(() => validateChoice(unknown, {maxEffort:'high'}, {model:'opaque'}));
assert.equal(parseNext('text [[NEXT {"to":"Third-Agent","model":"Case/Sensitive","reason":"ส่งงานใหม่"}]]').next.model, 'Case/Sensitive');
assert.equal(parseNext('tool mentions [[NEXT to=done]] then more text').next, null);
assert.equal(parseNext('[[NEXT {broken}]]').next, null);
assert.equal(parseNext('finished [[NEXT to=done]]').next.to, 'done');
assert.equal(executable('nonexistent-office-command', '/usr/bin:/bin'), null);
assert.throws(() => new Registry({settings:()=>({cliEntries:[{id:'user',command:'x',adapter:'office-jsonl'}]})}));
assert.throws(() => new Registry({settings:()=>({cliEntries:[{id:'constructor',command:'x',adapter:'office-jsonl'}]})}));

const wrappers = ['alpha','beta','gamma'].map(id => {
  const command = path.join(temporary, id + ' adapter');
  fs.writeFileSync(command, `#!${process.execPath}
const fs=require('fs'),path=require('path');
const id=${JSON.stringify(id)}, root=${JSON.stringify(temporary)};
const emit=o=>process.stdout.write(JSON.stringify(o)+'\\n');
if(process.argv.includes('--version')){console.log(id+' 1.0');process.exit(0)}
if(process.argv.includes('--office-capabilities')){emit({type:'capabilities',authState:'loggedIn',quotaGroup:id==='alpha'?'independent-fixture':'shared-fixture',permissions:{readOnly:true,workspaceWrite:true},models:[{id:id+'-model',isDefault:true,defaultEffort:'low',supportedEfforts:['low','high']}]});process.exit(0)}
require('readline').createInterface({input:process.stdin}).on('line',line=>{
 const request=JSON.parse(line);
 if(request.role==='coordinator'){
  if(request.prompt.includes('TASK: slow coordinator'))return setTimeout(()=>process.exit(0),30000);
  const catalog=JSON.parse(request.prompt.split('Available catalog: ')[1].split('\\nTASK:')[0]);
  const pin=(request.prompt.match(/user chose lead ([\\w-]+)/)||[])[1];
  const lead=pin||(['alpha','beta','gamma'].find(key=>catalog.some(c=>c.id===key&&c.ready)));
  emit({type:'result',text:JSON.stringify({lead,model:lead+'-model',effort:'low',assignment:'distinct fixture step',reason:'catalog and remaining work',summary:'fixture brief',first_step:'inspect fixture'})});process.exit(0);
 }
 fs.appendFileSync(path.join(root,'worker-calls'),JSON.stringify({id,mode:request.mode,model:request.model,effort:request.effort,checkpoint:request.prompt.includes('[room checkpoint]')})+'\\n');
 if(request.prompt.includes('all limit')||(request.prompt.includes('limit fixture')&&id==='alpha')){emit({type:'limit',resetsAt:Date.now()+60000});emit({type:'result',text:'',error:'usage limit'});process.exit(1)}
 if(request.mode==='read'){
  let denied=false;try{fs.writeFileSync('must-not-write','denied')}catch(e){denied=e.code==='EPERM'||e.code==='EACCES'}
  fs.appendFileSync(path.join(root,'permission-proof'),JSON.stringify({id,denied})+'\\n');
 }
 if(request.prompt.includes('approval fixture')&&request.mode==='read'){emit({type:'result',text:'Approve scoped fixture [[NEXT {"to":"user","kind":"approve","then":"gamma","model":"gamma-model","effort":"high"}]]'});process.exit(0)}
 if(request.mode==='write')fs.writeFileSync('approved.txt','approved scope');
 emit({type:'result',text:'Verified fixture [[NEXT '+JSON.stringify({to:'done',completion:{summary:'Fixture checked',checks:[{name:'Fixture check',result:'passed',evidence:'Fixture writes and permissions checked'}],remaining:[],review:{status:'not_required',reason:'Trivial isolated fixture file'}}})+']]',sessionId:id+'-session'});process.exit(0);
});
`, {mode:0o755});
  return {id,command,adapter:'office-jsonl'};
});
const delay = ms => new Promise(resolve => setTimeout(resolve,ms));
(async () => {
  const oldPath = process.env.PATH; process.env.PATH = '/usr/bin:/bin';
  try {
    const registry = new Registry({settings:()=>({cliEntries:wrappers}),cwd:temporary});
    await registry.refresh();
    assert.deepEqual(Object.keys(registry.records).filter(id=>registry.eligible(id)).sort(), ['alpha','beta','gamma']);
    assert.equal(registry.records.gamma.models[0].selector, 'gamma-model');
    assert.equal(registry.records.gamma.models[0].supportedEfforts.length, 2);
    const identity = registry.records.gamma;
    await Promise.all([registry.refresh(),registry.refresh()]);
    assert.equal(registry.records.gamma,identity,'concurrent rescans must retain the metadata target identity');
    const duplicate = new Registry({settings:()=>({cliEntries:[...wrappers,{id:'gamma-alias',command:wrappers[2].command,adapter:'office-jsonl'}]}),cwd:temporary});
    await duplicate.refresh();assert.equal(duplicate.records['gamma-alias'].duplicateOf,'gamma');assert.equal(duplicate.eligible('gamma-alias'),false);
  } finally { process.env.PATH = oldPath; }
  for (const file of ['server.js','team-workflow.js','team-runtime.js','task-workspace.js','agent-registry.js','agent-tracker.js','claude-usage.js','codex-usage.js','image-attachments.js','skill-catalog.js']) fs.copyFileSync(path.join(__dirname,'..',file),path.join(temporary,file));
  // This suite tests legacy room lifecycle; team workflow has a separate integration suite.
  const serverFile=path.join(temporary,'server.js');
  fs.writeFileSync(serverFile,fs.readFileSync(serverFile,'utf8').replace("workflow: { phase: 'meeting', participants: [], tasks: [], documents: [] }, questions: [],",'workflow: null, questions: [],'));
  fs.mkdirSync(path.join(temporary,'data'));
  const legacySettings=JSON.stringify({cliEntries:wrappers,dispatcher:{agent:'alpha',model:'alpha-model',effort:'low'},leadGuide:'legacy user guide',maxAutoTurns:0,customKey:'preserve me'});
  fs.writeFileSync(path.join(temporary,'data/settings.json'),legacySettings);
  fs.mkdirSync(path.join(temporary,'data/rooms'));
  const history=JSON.stringify({id:'history',title:'legacy room',dirs:[project],status:'done',messages:[],sessions:{},usage:{}});
  fs.writeFileSync(path.join(temporary,'data/rooms/history.json'),history);
  const port = await new Promise(resolve=>{const listener=net.createServer();listener.listen(0,'127.0.0.1',()=>{const port=listener.address().port;listener.close(()=>resolve(port));});});
  const server = spawn(process.execPath,[path.join(temporary,'server.js')],{cwd:temporary,env:{...process.env,PATH:'/usr/bin:/bin',OFFICE_PORT:String(port)},stdio:['ignore','ignore','pipe']});
  let errors='';server.stderr.on('data',data=>errors+=data);
  const base='http://127.0.0.1:'+port;
  async function request(route, body) { const response=await fetch(base+route,{method:body===undefined?'GET':'POST',headers:{'x-office':'1','content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});const data=await response.json();assert(response.ok,JSON.stringify(data));return data; }
  async function waitRoom(id, status) { for(let n=0;n<200;n++){const room=await request('/api/rooms/'+id);if(room.status===status)return room;await delay(30);}throw Error('room did not reach '+status+': '+JSON.stringify(await request('/api/rooms/'+id))); }
  try {
    let ready=false;for(let n=0;n<100;n++){try{await request('/api/ping');ready=true;break}catch{}await delay(30)}assert(ready,errors);
    const state=await request('/api/agents/discover',{});
    assert.equal(Object.values(state).filter(a=>a.ready).length,3);
    const room=await request('/api/rooms',{task:'approval fixture',dirs:[project],lead:'gamma'});
    const waiting=await waitRoom(room.id,'waiting');assert.equal(waiting.waiting.kind,'approve',JSON.stringify({waiting:waiting.waiting,messages:waiting.messages,errors}));assert(!fs.existsSync(path.join(project,'must-not-write')));
    const backups=fs.readdirSync(path.join(temporary,'data')).filter(f=>f.startsWith('settings.json.pre-v2-'));assert.equal(backups.length,1);assert.equal(fs.readFileSync(path.join(temporary,'data',backups[0]),'utf8'),legacySettings);
    const migrated=JSON.parse(fs.readFileSync(path.join(temporary,'data/settings.json')));assert.equal(migrated.schemaVersion,2);assert.equal(migrated.customKey,'preserve me');assert.equal(migrated.legacyRouting.leadGuide,'legacy user guide');assert.equal(fs.readFileSync(path.join(temporary,'data/rooms/history.json'),'utf8'),history);
    const proof=fs.readFileSync(path.join(temporary,'permission-proof'),'utf8').trim().split('\n').map(JSON.parse);assert(proof.every(x=>x.denied),'READ must reject a shell filesystem write inside the project');
    await request('/api/rooms/'+room.id+'/decide',{action:'approve'});
    const done=await waitRoom(room.id,'done');assert.equal(fs.readFileSync(path.join(project,'approved.txt'),'utf8'),'approved scope');assert.equal(done.assignments.gamma.effort,'high');
    const limited=await request('/api/rooms',{task:'limit fixture',dirs:[project]});const resumed=await waitRoom(limited.id,'done');assert.equal(resumed.lead,'beta');assert.equal(resumed.checkpoint,null);assert(fs.readFileSync(path.join(temporary,'worker-calls'),'utf8').trim().split('\n').map(JSON.parse).some(call=>call.id==='beta'&&call.checkpoint),'takeover must receive the checkpoint before it is cleared');
    const all=await request('/api/rooms',{task:'all limit',dirs:[project]});const paused=await waitRoom(all.id,'waiting');assert.equal(paused.waiting.kind,'limit');
    const shared=(await request('/api/state')).agents;assert(shared.beta.restingUntil>Date.now()&&shared.gamma.restingUntil>Date.now(),'reported shared quotas must rest every adapter in the same group');
    const calls=fs.readFileSync(path.join(temporary,'worker-calls'),'utf8').trim().split('\n').map(JSON.parse);assert.equal(calls.filter(x=>x.id==='alpha').length,1,'a resting candidate must not be retried');
    const res=await fetch(base+'/api/agents/nonexistent/refresh',{method:'POST',headers:{'x-office':'1'}});assert.equal(res.status,404);
    await request('/api/agents/beta/reset',{});
    const slow=await request('/api/rooms',{task:'slow coordinator',dirs:[project]});
    for(let n=0;n<50;n++){const room=await request('/api/rooms/'+slow.id);if(room.running?.role==='coordinator')break;await delay(20);}
    await request('/api/rooms/'+slow.id+'/stop',{});const stopped=await waitRoom(slow.id,'waiting');assert.equal(stopped.running,null,'stopping a coordinator must not leave the room running');
    console.log('Registry discovery for three CLIs, per-model policy, strict routing, READ denial/approved WRITE, N-agent limit takeover and exhaustion passed');
  } finally { server.kill('SIGTERM');await new Promise(resolve=>server.on('exit',resolve)); }
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>fs.rmSync(temporary,{recursive:true,force:true}));
