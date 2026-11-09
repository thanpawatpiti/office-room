'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const w=require('../task-workspace');
const root=fs.mkdtempSync(path.join(os.tmpdir(),'office-workspace-test-'));
const project=path.join(root,'project');fs.mkdirSync(project);fs.writeFileSync(path.join(project,'a'),'old');fs.writeFileSync(path.join(project,'b'),'untouched');
const copies=[];const copy=()=>{const c=w.prepare([project]);copies.push(c);return c;};
try {
 const c=copy();fs.writeFileSync(path.join(c.roots[0].copy,'a'),'new');
 assert.equal(fs.readFileSync(path.join(project,'a'),'utf8'),'old');
 w.integrate(c,[path.join(project,'a')]);assert.equal(fs.readFileSync(path.join(project,'a'),'utf8'),'new');
 const conflict=copy();fs.writeFileSync(path.join(conflict.roots[0].copy,'a'),'task');fs.writeFileSync(path.join(project,'a'),'human');
 assert.throws(()=>w.integrate(conflict,[path.join(project,'a')]),/ต้นฉบับ/);assert.equal(fs.readFileSync(path.join(project,'a'),'utf8'),'human');
 const escape=copy();fs.writeFileSync(path.join(escape.roots[0].copy,'b'),'unauthorized');assert.throws(()=>w.integrate(escape,[path.join(project,'a')]),/นอกขอบเขต/);
 assert.equal(fs.readFileSync(path.join(project,'b'),'utf8'),'untouched');
 const link=copy();fs.symlinkSync('/tmp',path.join(link.roots[0].copy,'link'));assert.throws(()=>w.integrate(link,[path.join(project,'link')]),/symbolic/);
 const remove=copy();fs.unlinkSync(path.join(remove.roots[0].copy,'a'));w.integrate(remove,[path.join(project,'a')]);assert(!fs.existsSync(path.join(project,'a')));
 console.log('Isolated workspaces, scoped integration, human-edit conflict, symlink rejection and deletion passed');
} finally {for(const c of copies)fs.rmSync(c.base,{recursive:true,force:true});fs.rmSync(root,{recursive:true,force:true});}
