'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const inProcess=require('./fixtures/in-process-server');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'office-team-integration-'));
const project=path.join(temp,'project');fs.mkdirSync(project);
for(const f of ['server.js','team-workflow.js','team-runtime.js','task-workspace.js','agent-registry.js','agent-tracker.js','claude-usage.js','codex-usage.js','image-attachments.js','skill-catalog.js'])fs.copyFileSync(path.join(__dirname,'..',f),path.join(temp,f));
fs.mkdirSync(path.join(temp,'data'));
const entries=['a','b'].map(id=>{
 const command=path.join(temp,id);
 fs.writeFileSync(command,`#!${process.execPath}
const fs=require('fs'),path=require('path'); const id=${JSON.stringify(id)},project=${JSON.stringify(project)},log=${JSON.stringify(path.join(temp,'calls'))};
const emit=o=>process.stdout.write(JSON.stringify(o)+'\\n');
if(process.argv.includes('--version')){console.log('fixture');process.exit(0)}
if(process.argv.includes('--office-capabilities')){emit({type:'capabilities',authState:'loggedIn',permissions:{readOnly:true,workspaceWrite:true},models:[{id:'fixture',isDefault:true,supportedEfforts:['low'],defaultEffort:'low'}]});process.exit(0)}
const completion={summary:'fixture report',checks:[{name:'fixture check',result:'passed',evidence:'transport fixture only'}],remaining:[]};
const result=n=>{emit({type:'result',text:'fixture result [[NEXT '+JSON.stringify(n)+']]'});process.exit(0)};
require('readline').createInterface({input:process.stdin}).on('line',line=>{
 const r=JSON.parse(line);fs.appendFileSync(log,JSON.stringify({id,mode:r.mode,prompt:r.prompt,roots:r.writableRoots,at:Date.now()})+'\\n');
 if(r.role==='coordinator'){emit({type:'result',text:JSON.stringify({lead:'a',model:'fixture',effort:'low',assignment:'inspect fixture',reason:'fixture',summary:'user brief',first_step:'meeting'})});return process.exit(0)}
 if(r.prompt.includes('All tasks have independent reviews')) return result({to:'done',completion});
 if(r.prompt.includes('Independently review task')) { const revision=+(r.prompt.match(/revision (\\d+)/)||[])[1];return result({to:'done',review:{revision,status:'passed',evidence:'fixture inspected merged scope'},completion}); }
 if(r.prompt.includes('This is isolated task')){
  const task=(r.prompt.match(/This is isolated task ([\\w-]+)/)||[])[1];
  if(task==='api'&&r.prompt.includes('partial crash fixture')&&!r.prompt.includes('partial workspace was inspected in READ')) { fs.writeFileSync(path.join(r.writableRoots[0],task+'.txt'),'partial');emit({type:'result',text:'',error:'fixture partial failure'});return process.exit(1); }
  if(task==='api'&&!r.prompt.includes('User answered:')) return setTimeout(()=>result({to:'user',kind:'ask',questions:[{id:'target',question:'เลือกอะไร?',options:[{label:'macOS'},{label:'Web'}]}]}),80);
  fs.writeFileSync(path.join(r.writableRoots[0],task+'.txt'),'from '+id);
  emit({type:'step',text:'writing '+task});return setTimeout(()=>result({to:'done',completion}),120);
 }
 return result({to:'user',kind:'approve',teamPlan:{summary:'two distinct tasks',flow:'flowchart TD\\n A[Brief] --> B[Tasks]',tasks:[{id:'api',owner:'a',model:'fixture',effort:'low',assignment:'API file',reason:'distinct API',files:[path.join(project,'api.txt')],dependsOn:[]},{id:'native',owner:'b',model:'fixture',effort:'low',assignment:'Native file',reason:'distinct native',files:[path.join(project,'native.txt')],dependsOn:[]}]}});
});
`,{mode:0o755});return{id,command,adapter:'office-jsonl'};
});
fs.writeFileSync(path.join(temp,'data/settings.json'),JSON.stringify({schemaVersion:2,cliEntries:entries}));
const oldPath=process.env.PATH;process.env.PATH='/usr/bin:/bin';
const server=inProcess(temp);
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function request(url,body){const out=await server.request(url,body);assert.equal(out.status,200,JSON.stringify(out));return out.value;}
async function until(fn){for(let n=0;n<300;n++){const value=await fn();if(value)return value;await delay(25);}throw Error('Timeout: '+JSON.stringify(server.errors));}
(async()=>{
 try{
 await until(async()=>{try{return Object.values((await request('/api/state')).agents).filter(x=>x.ready).length===2;}catch{return false;}});
 const r=await request('/api/rooms',{task:'team fixture',dirs:[project]});
 const room=()=>request('/api/rooms/'+r.id);
 const planned=await until(async()=>{const v=await room();return v.waiting?.kind==='approve'&&v;});
 assert.deepEqual([...planned.workflow.participants].sort(),['a','b']);
 assert(!fs.existsSync(path.join(project,'api.txt')),'meeting must not write');
 assert.equal(planned.workflow.phase,'planning');
 await request('/api/rooms/'+r.id+'/decide',{action:'approve'});
 const asking=await until(async()=>{const v=await room();return v.questions.some(q=>q.status==='pending')&&v;});
 const pending=asking.questions.find(q=>q.status==='pending');
 const unrelated=await until(async()=>{const v=await room();return v.workflow.tasks.find(t=>t.id==='native').status==='done'&&v;});
 assert.equal(unrelated.workflow.tasks.find(t=>t.id==='api').status,'waiting');
 assert.equal(fs.readFileSync(path.join(project,'native.txt'),'utf8'),'from b');
 const doc=await request('/api/rooms/'+r.id+'/documents/plan');assert.match(doc.content,/two distinct tasks/);
 assert.equal((await server.request('/api/rooms/'+r.id+'/documents/not-registered')).status,400);
 await request('/api/rooms/'+r.id+'/answer',{questionId:pending.id,answers:{target:{selected:['o1']}}});
 const done=await until(async()=>{const v=await room();if(v.workflow.tasks.some(t=>t.status==='failed'))throw Error(JSON.stringify(v.workflow.tasks));return v.status==='done'&&v;});
 assert.equal(done.workflow.phase,'delivered');assert(done.workflow.tasks.every(t=>t.review.by!==t.owner&&t.review.status==='passed'));
 assert.equal(fs.readFileSync(path.join(project,'api.txt'),'utf8'),'from a');assert.equal(done.approved,false);
 const calls=fs.readFileSync(path.join(temp,'calls'),'utf8').trim().split('\n').map(JSON.parse);
 const writers=calls.filter(c=>c.prompt.includes('This is isolated task')&&c.mode==='write'&&!c.prompt.includes('All tasks have independent reviews'));
 assert(writers.length>=3);assert(Math.abs(writers[0].at-writers[1].at)<150,'independent tasks should start concurrently');
 assert(writers.every(c=>c.roots[0]!==project),'writers must use isolated copies');

 const broken=await request('/api/rooms',{task:'partial crash fixture',dirs:[project]});
 const brokenRoom=()=>request('/api/rooms/'+broken.id);
 await until(async()=>{const v=await brokenRoom();return v.waiting?.kind==='approve';});
 await request('/api/rooms/'+broken.id+'/decide',{action:'approve'});
 const failed=await until(async()=>{const v=await brokenRoom();return v.workflow.tasks.find(t=>t.id==='api').status==='failed'&&v.workflow.tasks.find(t=>t.id==='native').status==='done'&&v;});
 assert.equal(fs.readFileSync(path.join(project,'api.txt'),'utf8'),'from a','partial writes stay isolated');
 await delay(200);assert.equal((await brokenRoom()).workflow.tasks.find(t=>t.id==='api').status,'failed','failed WRITE must not replay');
 await request('/api/rooms/'+broken.id+'/decide',{action:'retry'});
 const resumed=await until(async()=>{const v=await brokenRoom();return v.questions.some(q=>q.status==='pending')&&v;});
 assert.equal(resumed.workflow.tasks.find(t=>t.id==='api').recovering,false,'retry must pass through READ inspection');
 const recoveryQuestion=resumed.questions.find(q=>q.status==='pending');
 await request('/api/rooms/'+broken.id+'/answer',{questionId:recoveryQuestion.id,answers:{target:{selected:['o1']}}});
 const recovered=await until(async()=>{const v=await brokenRoom();if(v.workflow.tasks.some(t=>t.status==='failed'))throw Error(JSON.stringify(v.workflow.tasks));return v.status==='done'&&v;});
 const stopped=await request('/api/rooms',{task:'stop fixture',dirs:[project]});
 const stoppedRoom=()=>request('/api/rooms/'+stopped.id);
 await until(async()=>{const v=await stoppedRoom();return v.waiting?.kind==='approve';});
 await request('/api/rooms/'+stopped.id+'/decide',{action:'approve'});
 await until(async()=>{const v=await stoppedRoom();return v.workflow.tasks.some(t=>t.status==='running');});
 await request('/api/rooms/'+stopped.id+'/stop',{});await delay(300);
 const stoppedState=await stoppedRoom();assert.equal(stoppedState.status,'waiting');assert(stoppedState.workflow.stopped);
 assert(!stoppedState.workflow.tasks.some(t=>t.status==='running'),'stop must settle both task transports');
 for(const roomState of [done,recovered,stoppedState])for(const t of roomState.workflow.tasks)if(t.workspace)fs.rmSync(t.workspace.base,{recursive:true,force:true});
 console.log('Partial task writes stay isolated; no automatic replay; manual retry inspects in READ; stop settles parallel transports');

 console.log('Real meeting participation, approval, parallel writers, independent work during question, scoped integration, documents, cross-review and combined verification passed');
 }finally{await server.close();process.env.PATH=oldPath;fs.rmSync(temp,{recursive:true,force:true});}
})().catch(error=>{console.error(error);process.exitCode=1;});
