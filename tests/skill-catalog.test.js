'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { discoverSkills, resolveSkills } = require('../skill-catalog');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'office-skills-'));
try {
  const home = path.join(tmp, 'home'), project = path.join(tmp, 'project');
  function skill(file, content) { fs.mkdirSync(path.dirname(file), {recursive:true}); fs.writeFileSync(file, content); }
  const global = path.join(home,'.agents/skills');
  skill(path.join(global,'engineering/SKILL.md'),'---\nname: senior-fullstack\ndescription: >-\n  Build software\n  from repository evidence.\n---\nNever execute this body while listing skills.');
  skill(path.join(global,'.system/tool/SKILL.md'),'---\r\nname: "tool:builder"\r\ndescription: "A quoted description"\r\n---\r\nbody');
  skill(path.join(global,'.trash/retired/SKILL.md'),'---\nname: deleted-skill\n---\n');
  skill(path.join(global,'synced/.staging/pending/SKILL.md'),'---\nname: not-installed-yet\n---\n');
  skill(path.join(global,'engineering/references/example/SKILL.md'),'---\nname: fixture-not-installed\n---\n');
  skill(path.join(project,'.claude/skills/local/SKILL.md'),"---\nname: senior-fullstack\ndescription: 'Project''s engineering rules'\n---\n");
  fs.mkdirSync(path.join(home,'.claude'),{recursive:true});fs.symlinkSync(global,path.join(home,'.claude/skills'));
  fs.mkdirSync(path.join(global,'cycle'));fs.symlinkSync(global,path.join(global,'cycle/back'));
  const personal=discoverSkills({home});
  assert.equal(personal.length,2,'aliases, trash, embedded fixtures and cycles must not fabricate more installed skills');
  assert.equal(personal.find(s=>s.name==='senior-fullstack').description,'Build software from repository evidence.');
  assert.equal(personal.find(s=>s.name==='tool:builder').description,'A quoted description');
  const catalog=discoverSkills({home,dirs:[project]});
  assert.equal(catalog.length,3);assert(catalog.some(s=>s.scope==='project'&&s.description==="Project's engineering rules"));
  assert.deepEqual(discoverSkills({home,dirs:[project]}).map(s=>s.id),catalog.map(s=>s.id),'IDs must survive a rescan');
  const chosen=catalog.filter(s=>s.scope==='project'||s.name==='tool:builder');
  assert.deepEqual(resolveSkills(chosen.map(s=>s.id),catalog).map(s=>s.path),chosen.map(s=>s.path));
  assert.equal(resolveSkills([chosen[0].id,chosen[0].id],catalog).length,1);
  assert.throws(()=>resolveSkills('senior-fullstack',catalog),/ชื่อสกิลซ้ำ/);
  assert.throws(()=>resolveSkills(['/etc/passwd'],catalog),/ไม่พบสกิล/);
  assert.throws(()=>resolveSkills([{}],catalog),/ไม่ถูกต้อง/);
  assert.deepEqual(resolveSkills(undefined,catalog),[]);
  assert.equal(resolveSkills('tool:builder',catalog)[0].name,'tool:builder','legacy names can still resolve when unambiguous');
  console.log('Installed/project skill discovery, descriptions, stable selection IDs, symlink deduplication and validated legacy selection passed');
} finally { fs.rmSync(tmp,{recursive:true,force:true}); }
