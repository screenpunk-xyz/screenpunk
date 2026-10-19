import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { buildProject, kitRoot } from '../scripts/build.mjs';
test('production starter is local, has notices, and excludes unused carousel/motion code',async()=>{const tmp=await fs.mkdtemp(path.join(os.tmpdir(),'sp-build-'));try{const result=await buildProject(path.join(kitRoot,'templates/earthquakes'),tmp);assert.ok(result.bytes<50*1024*1024);const html=await fs.readFile(path.join(tmp,'index.html'),'utf8');assert.match(html,/src="screen.js"/);assert.doesNotMatch(html,/type="module"|https?:|data:/);const notices=await fs.readFile(path.join(tmp,'THIRD-PARTY-NOTICES.txt'),'utf8');assert.match(notices,/react@/);assert.match(notices,/recharts@/);assert.doesNotMatch(notices,/embla-carousel@|motion-dom@/)}finally{await fs.rm(tmp,{recursive:true,force:true})}});
test('type errors and escaping imports fail before output publication',async()=>{const tmp=await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(),'sp-source-')));try{await fs.mkdir(path.join(tmp,'src'));await fs.writeFile(path.join(tmp,'src/main.tsx'),'const x: number = "bad";');await assert.rejects(buildProject(tmp,path.join(tmp,'dist')),/not assignable/);await fs.writeFile(path.join(tmp,'src/main.tsx'),'import "https://example.org/code.js";');await assert.rejects(buildProject(tmp,path.join(tmp,'dist')))}finally{await fs.rm(tmp,{recursive:true,force:true})}});
test('Google TV declaration gate runs before output replacement and accepts optional provider',async()=>{
 const tmp=await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(),'sp-connection-build-')));
 try {
  await fs.mkdir(path.join(tmp,'src'));const output=path.join(tmp,'dist');await fs.mkdir(output);await fs.writeFile(path.join(output,'prior.txt'),'previous output');
  await fs.writeFile(path.join(tmp,'screen.json'),JSON.stringify({name:'TV',connections:[]}));
  await fs.writeFile(path.join(tmp,'src/main.tsx'),`const sp=(globalThis as any).screenpunk; sp.connections.request('googleTV','status',{}); export {};`);
  await assert.rejects(buildProject(tmp,output),/missing connection declaration for "googleTV"/);
  assert.equal(await fs.readFile(path.join(output,'prior.txt'),'utf8'),'previous output');
  await fs.writeFile(path.join(tmp,'screen.json'),JSON.stringify({name:'TV',connections:[{alias:'googleTV',required:false}]}));
  await buildProject(tmp,output);assert.ok((await fs.readFile(path.join(output,'screen.js'),'utf8')).includes('googleTV'));
 }finally{await fs.rm(tmp,{recursive:true,force:true})}
});
