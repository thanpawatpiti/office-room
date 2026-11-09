'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { spawn } = require('node:child_process');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'office-room-test-'));
const project = path.join(tmp, 'project'), offline = path.join(tmp, 'offline'), bin = path.join(tmp, 'bin');
fs.mkdirSync(project); fs.mkdirSync(offline); fs.mkdirSync(bin);
const skillPath=path.join(project,'.agents/skills/fixture-skill/SKILL.md');
fs.mkdirSync(path.dirname(skillPath),{recursive:true});fs.writeFileSync(skillPath,'---\nname: office-fixture-skill\ndescription: Fixture instructions\n---\nRead the selected fixture skill.');
for (const name of ['server.js','team-workflow.js','team-runtime.js','task-workspace.js','agent-tracker.js','image-attachments.js','claude-usage.js','codex-usage.js','agent-registry.js','skill-catalog.js']) fs.copyFileSync(path.join(__dirname,'..',name), path.join(tmp,name));
// Exercise the real reader through a fake account service; never access the real Keychain.
fs.renameSync(path.join(tmp,'claude-usage.js'),path.join(tmp,'claude-usage-reader.js'));
fs.writeFileSync(path.join(tmp,'usage-response.json'),JSON.stringify({five_hour:{utilization:12},seven_day:{utilization:40}}));
fs.writeFileSync(path.join(tmp,'claude-usage.js'), `
const fs=require('fs'),reader=require('./claude-usage-reader');
module.exports={createUsageReader:()=>reader.createUsageReader({credentials:async()=>'fixture-token',request:async()=>{
  fs.appendFileSync(__dirname+'/usage-calls','x');
  await new Promise(resolve=>setTimeout(resolve,100));
  const data=JSON.parse(fs.readFileSync(__dirname+'/usage-response.json','utf8'));
  return {ok:!data.status,status:data.status,json:async()=>data};
}})};
`);
{ // A Codex session file written by another Codex session on this machine.
  const d=new Date(), dir=path.join(tmp,'codex-home','sessions',String(d.getFullYear()),String(d.getMonth()+1).padStart(2,'0'),String(d.getDate()).padStart(2,'0'));
  fs.mkdirSync(dir,{recursive:true});
  fs.writeFileSync(path.join(dir,'rollout-fixture.jsonl'),JSON.stringify({timestamp:new Date().toISOString(),type:'event_msg',payload:{type:'token_count',rate_limits:{limit_id:'codex',primary:{used_percent:33,window_minutes:300,resets_at:2000000000},secondary:{used_percent:21,window_minutes:10080,resets_at:2000500000}}}})+'\n');
}
const choice = (lead='claude') => ({lead,model:lead==='codex'?'codex-fixture':'opus',effort:'low',assignment:'ตรวจไฟล์ก่อน',summary:'สรุปโจทย์ทดสอบ',first_step:'ตรวจไฟล์ก่อน',reason:'เหมาะกับงาน'});
fs.writeFileSync(path.join(bin,'codex'), `#!/opt/homebrew/Cellar/node/26.13.0_2/bin/node
const emit=o=>process.stdout.write(JSON.stringify(o)+'\\n');
if(process.argv.includes('--version')){console.log('codex fixture');process.exit(0)}
if(process.argv.includes('login')){console.log('Logged in using ChatGPT');process.exit(0)}
if(process.argv.includes('exec')){let input='';process.stdin.on('data',d=>input+=d);process.stdin.on('end',()=>{const lead=(input.match(/user chose lead ([\\w-]+)/)||[])[1]||'claude';emit({type:'item.completed',item:{type:'agent_message',text:JSON.stringify({lead,model:lead==='codex'?'codex-fixture':'opus',effort:'low',assignment:'ตรวจไฟล์ก่อน',summary:'สรุปโจทย์ทดสอบ',first_step:'ตรวจไฟล์ก่อน',reason:'เหมาะกับงาน'})}})});return;}
const rl=require('node:readline').createInterface({input:process.stdin});
rl.on('line',line=>{const m=JSON.parse(line);if(m.id===undefined)return;
if(m.method==='model/list')emit({id:m.id,result:{data:[{id:'codex-fixture',model:'codex-fixture',isDefault:true,defaultReasoningEffort:'low',supportedReasoningEfforts:[{reasoningEffort:'low'},{reasoningEffort:'high'}]}],nextCursor:null}});
else if(m.method==='account/read')emit({id:m.id,result:{account:{type:'chatgpt'}}});
else if(m.method==='thread/start')emit({id:m.id,result:{thread:{id:'image-thread'}}});
else if(m.method==='turn/start'){
require('fs').appendFileSync('../codex-images.jsonl',JSON.stringify(m.params.input)+'\\n');
emit({id:m.id,result:{turn:{id:'image-turn'}}});
setTimeout(()=>{emit({method:'item/completed',params:{threadId:'image-thread',item:{id:'answer',type:'agentMessage',text:'ดูภาพแล้ว [[NEXT to=user kind=ask]]'}}});emit({method:'turn/completed',params:{threadId:'image-thread',turn:{status:'completed'}}});},100);
}else emit({id:m.id,result:{}});
});
`, {mode:0o755});
fs.writeFileSync(path.join(bin,'claude'), `#!/opt/homebrew/Cellar/node/26.13.0_2/bin/node
const out=e=>process.stdout.write(JSON.stringify(e)+'\\n');
if(process.argv.includes('--version')){console.log('claude fixture');process.exit(0)}
if(process.argv.includes('auth')){console.log(JSON.stringify({loggedIn:true}));process.exit(0)}
if(process.env.OFFICE_PARENT_PIPE)process.exit(9);
if(process.argv.includes('--input-format')){
let input='';require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
const m=JSON.parse(line);
if(m.type==='control_request'){out({type:'control_response',response:{subtype:'success',response:{models:[{value:'default',resolvedModel:'opus',supportsEffort:true,supportedEffortLevels:['low','high']},{value:'opus',supportsEffort:true,supportedEffortLevels:['low','high']}]}}});return;}
if(m.type==='user'){require('fs').writeFileSync(require('path').join(require('path').dirname(process.env.OFFICE_TEST_CLAUDE_CALLS),'claude-image-input.json'),line);worker();}
});
return;
}
if(process.cwd().endsWith('data')){
let input='';process.stdin.on('data',d=>input+=d);process.stdin.on('end',()=>{const lead=(input.match(/user chose lead ([\\w-]+)/)||[])[1]||'claude';out({type:'result',result:JSON.stringify({lead,model:lead==='codex'?'codex-fixture':'opus',effort:'low',assignment:'ตรวจไฟล์ก่อน',summary:'สรุปโจทย์ทดสอบ',first_step:'ตรวจไฟล์ก่อน',reason:'เหมาะกับงาน'})})});return;
}
worker();
function worker(){
require('fs').writeFileSync(require('path').join(require('path').dirname(process.env.OFFICE_TEST_CLAUDE_CALLS),'claude-worker-args.json'),JSON.stringify(process.argv));
require('fs').appendFileSync(process.env.OFFICE_TEST_CLAUDE_CALLS,'x');
if(process.cwd().endsWith('offline')){
require('fs').appendFileSync(require('path').join(require('path').dirname(process.env.OFFICE_TEST_CLAUDE_CALLS),'offline-calls'),'x');out({type:'system',subtype:'api_retry',attempt:1,max_retries:10,retry_delay_ms:500,error_status:null,error:'unknown',session_id:'net'});
setTimeout(()=>{out({type:'result',is_error:true,result:'API Error: Connection error.',session_id:'net'});process.exit(1)},300);return;}
setTimeout(()=>out({type:'stream_event',event:{type:'content_block_start',index:0,content_block:{type:'tool_use',name:'Agent',id:'sub1'}}}),150);
setTimeout(()=>out({type:'rate_limit_event',rate_limit_info:{unifiedWindows:{five_hour:{utilization:0.09},seven_day:{utilization:0.39}}}}),180);
setTimeout(()=>out({type:'assistant',message:{content:[{type:'tool_use',name:'Agent',id:'sub1',input:{description:'test'}}]}}),220);
setTimeout(()=>out({type:'system',subtype:'task_started',tool_use_id:'sub1',task_id:'task1',task_type:'local_agent'}),300);
setTimeout(()=>out({type:'user',message:{content:[{type:'tool_result',tool_use_id:'sub1',content:'running'}]}}),380);
setTimeout(()=>out({type:'system',subtype:'task_notification',task_id:'task1'}),500);
setTimeout(()=>{out({type:'result',result:'ทำเสร็จแล้ว [[NEXT to=user kind=ask]]',session_id:'fake'});process.exit(0)},650);
}
`, {mode:0o755});
const delay = ms => new Promise(r => setTimeout(r,ms));
(async () => {
  const port = await new Promise(resolve => { const s=net.createServer(); s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>resolve(p));}); });
  const root=`http://127.0.0.1:${port}`;
  const server=spawn(process.execPath,[path.join(tmp,'server.js')],{cwd:tmp,env:{...process.env,CODEX_HOME:path.join(tmp,'codex-home'),OFFICE_USAGE_MIN_GAP_MS:'0',OFFICE_USAGE_BACKOFF_MS:'300',OFFICE_PORT:String(port),OFFICE_TEST_CLAUDE_CALLS:path.join(tmp,'claude-calls'),OFFICE_PARENT_PIPE:'1',PATH:`${bin}:/usr/bin:/bin`},stdio:['pipe','ignore','pipe']});
  let errors=''; server.stderr.on('data',x=>errors+=x);
  try {
    let ready=false; for(let n=0;n<50;n++){try{const r=await fetch(root+'/api/ping');if(r.ok){ready=true;break}}catch{} await delay(50)}
    assert(ready, `server failed: ${errors}`);
    const controller=new AbortController(); const stream=await fetch(root+'/api/events',{signal:controller.signal}); const reader=stream.body.getReader();
    const received=[]; let buf='';
    const reading=(async()=>{try{for(;;){const {done,value}=await reader.read();if(done)break;buf+=Buffer.from(value).toString();let i;while((i=buf.indexOf('\n\n'))>=0){const block=buf.slice(0,i);buf=buf.slice(i+2);if(block.startsWith('data: '))received.push(JSON.parse(block.slice(6)));}}}catch(e){if(e.name!=='AbortError')throw e}})();
    const refresh=()=>fetch(root+'/api/agents/claude/refresh',{method:'POST',headers:{'x-office':'1'}}).then(r=>r.json());
    await refresh(); // Finish startup refresh before checking concurrent requests.
    const calls=fs.readFileSync(path.join(tmp,'usage-calls'),'utf8').length;
    const [usage,duplicate]=await Promise.all([refresh(),refresh()]);
    assert.deepEqual(usage.windows.map(w=>w.used),[12,40]);
    assert.deepEqual(usage,duplicate);
    assert.equal(usage.source,'Claude usage service');
    assert.equal(fs.readFileSync(path.join(tmp,'usage-calls'),'utf8').length,calls+1,'concurrent refresh must share one request');
    assert(!fs.existsSync(path.join(tmp,'claude-calls')),'usage refresh must not launch a Claude inference');
    const discovered=await fetch(root+'/api/skills',{method:'POST',headers:{'content-type':'application/json','x-office':'1'},body:JSON.stringify({dirs:[project]})}).then(r=>r.json());
    const selectedSkill=discovered.skills.find(s=>s.name==='office-fixture-skill');assert(selectedSkill&&selectedSkill.path===fs.realpathSync(skillPath));
    const rejectedSkill=await fetch(root+'/api/rooms',{method:'POST',headers:{'content-type':'application/json','x-office':'1'},body:JSON.stringify({task:'invalid skill',dirs:[project],skills:['/etc/passwd']})});assert.equal(rejectedSkill.status,400);
    assert(!fs.existsSync(path.join(tmp,'claude-calls')),'skill listing and rejected selection must not launch inference');
    fs.writeFileSync(path.join(tmp,'usage-response.json'),JSON.stringify({status:429}));
    const stale=await refresh();
    assert.deepEqual(stale.windows,usage.windows);
    assert.equal(stale.updatedAt,usage.updatedAt);
    assert.equal(stale.refreshing,false);
    assert.match(stale.refreshError,/HTTP 429/);
    const callsAt429=fs.readFileSync(path.join(tmp,'usage-calls'),'utf8').length;
    const backedOff=await refresh();
    assert.equal(fs.readFileSync(path.join(tmp,'usage-calls'),'utf8').length,callsAt429,'after a 429 the provider is not asked again until the back-off ends');
    assert.match(backedOff.refreshError,/เว้นระยะ/);
    fs.writeFileSync(path.join(tmp,'usage-response.json'),JSON.stringify({five_hour:{utilization:14},seven_day:{utilization:41}}));
    await delay(350);
    const recovered=await refresh();
    assert.deepEqual(recovered.windows.map(w=>w.used),[14,41]);
    assert.equal(recovered.refreshError,undefined);
    assert(recovered.updatedAt>usage.updatedAt);
    for(let n=0;n<20 && !received.some(e=>e.type==='agents' && e.agents.claude.updatedAt===recovered.updatedAt);n++)await delay(10);
    assert(received.some(e=>e.type==='agents' && e.agents.claude.updatedAt===recovered.updatedAt),'updated usage must reach native clients via SSE');
    console.log('Account usage refresh, deduplication, stale errors, recovery and SSE passed without inference');
    const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
    const uploaded=await fetch(root+'/api/images',{method:'POST',headers:{'content-type':'application/json','x-office':'1'},body:JSON.stringify({data:png})});
    assert(uploaded.ok);const image=await uploaded.json();assert(fs.existsSync(image.path));
    const invalid=await fetch(root+'/api/images',{method:'POST',headers:{'content-type':'application/json','x-office':'1'},body:JSON.stringify({data:'bad-data'})});assert.equal(invalid.status,400);
    const response=await fetch(root+'/api/rooms',{method:'POST',headers:{'content-type':'application/json','x-office':'1'},body:JSON.stringify({task:'fixture only',dirs:[project],lead:'claude',skills:[selectedSkill.id],images:[image.id]})});
    assert(response.ok,await response.text());
    for(let n=0;n<60 && !received.some(e=>e.type==='room' && e.room?.status==='waiting');n++)await delay(50);
    const changes=received.filter(e=>e.type==='live' && e.op==='subagents');
    assert(changes.some(e=>Object.keys(e.subagents).length===1),JSON.stringify(changes));
    assert(changes.some(e=>Object.keys(e.subagents).length===0),JSON.stringify(changes));
    assert(received.some(e=>e.type==='room' && e.room?.messages?.some(m=>m.text?.includes('ทำเสร็จแล้ว'))));
    const completed = received.find(e=>e.type==='room' && e.room?.messages?.some(m=>m.text?.includes('ทำเสร็จแล้ว'))).room;
    const briefIndex = completed.messages.findIndex(m=>m.from==='coordinator');
    assert(briefIndex >= 0 && briefIndex < completed.messages.findIndex(m=>m.from==='claude'));
    assert.equal(completed.briefing.lead, 'claude');
    assert.deepEqual(completed.skills,['office-fixture-skill']);assert.equal(completed.skillRefs[0].path,fs.realpathSync(skillPath));
    const workerArgs=JSON.parse(fs.readFileSync(path.join(tmp,'claude-worker-args.json'),'utf8'));
    const instructions=workerArgs[workerArgs.indexOf('--append-system-prompt')+1];
    assert(instructions.includes(skillPath)&&instructions.includes('Read each selected SKILL.md'),'worker must receive selected skill instructions and path');
    assert(workerArgs.includes('--add-dir')&&workerArgs.includes(path.dirname(fs.realpathSync(skillPath))),'worker must be able to read selected skill resources');
    const claudeInput=JSON.parse(fs.readFileSync(path.join(tmp,'claude-image-input.json'),'utf8'));
    assert.equal(claudeInput.message.content[1].type,'image');assert.equal(claudeInput.message.content[1].source.data,png);
    assert(claudeInput.message.content[0].text.includes('fixture only'));
    assert.equal(completed.messages[0].images[0].id,image.id);
    const state=await fetch(root+'/api/state').then(r=>r.json());
    assert.deepEqual(state.agents.claude.windows.map(w=>w.used),[9,39],'a rate_limit_event from a run is newer than the last account reading');
    assert.equal(state.agents.claude.source,'Claude CLI');
    assert.equal(state.agents.codex.source,'Codex session file','Codex usage comes from the local session file before any provider call');
    assert.deepEqual(state.agents.codex.windows.map(w=>[w.key,w.used]),[['5h',33],['7d',21]]);
    console.log('Isolated server SSE, briefing order and background agent lifecycle passed');
    received.length=0;
    const auto = await fetch(root+'/api/rooms',{method:'POST',headers:{'content-type':'application/json','x-office':'1'},body:JSON.stringify({task:'auto brief fixture',dirs:[project],lead:'auto'})});
    assert(auto.ok);
    for(let n=0;n<80 && !received.some(e=>e.type==='room' && e.room?.status==='waiting');n++)await delay(50);
    const autoRoom = received.find(e=>e.type==='room' && e.room?.status==='waiting').room;
    assert.equal(autoRoom.briefing.summary,'สรุปโจทย์ทดสอบ');
    assert.equal(autoRoom.briefing.firstStep,'ตรวจไฟล์ก่อน');
    console.log('Existing dispatcher summary and initial owner briefing passed');
    received.length=0;
    const codexRoom=await fetch(root+'/api/rooms',{method:'POST',headers:{'content-type':'application/json','x-office':'1'},body:JSON.stringify({task:'',dirs:[project],lead:'codex',images:[image.id]})});assert(codexRoom.ok);
    for(let n=0;n<80 && !received.some(e=>e.type==='room' && e.room?.status==='waiting');n++)await delay(50);
    const codexInputs=fs.readFileSync(path.join(tmp,'codex-images.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
    assert(codexInputs.some(input=>input.some(i=>i.type==='localImage' && i.path===image.path)));
    console.log('Image upload, rejection, Claude image blocks and Codex localImage delivery passed');
    received.length=0;
    const net=await fetch(root+'/api/rooms',{method:'POST',headers:{'content-type':'application/json','x-office':'1'},body:JSON.stringify({task:'offline fixture',dirs:[offline],lead:'claude'})});
    assert(net.ok,await net.text());
    const offlineDone=()=>received.some(e=>e.type==='room' && e.room?.messages?.some(m=>m.from==='system' && m.text?.includes('เชื่อมต่ออินเทอร์เน็ตไม่ได้')));
    for(let n=0;n<80 && !offlineDone();n++)await delay(50);
    assert(received.some(e=>e.type==='live' && /กำลังลองใหม่/.test(e.step?.title||'')),'retry must show as a live step');
    assert(offlineDone(),'network failure must tell the user to check the connection');
    assert.equal(fs.readFileSync(path.join(tmp,'offline-calls'),'utf8'),'x','network failure must not start a second full attempt');
    controller.abort(); await reading;
    console.log('Network retry status and offline message passed');
  } finally { server.kill('SIGTERM'); await new Promise(r=>server.on('exit',r)); fs.rmSync(tmp,{recursive:true,force:true}); }
})().catch(e=>{console.error(e);process.exitCode=1});
