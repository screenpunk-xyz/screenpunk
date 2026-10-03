import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import vm from 'node:vm';
import {fork,execFileSync} from 'node:child_process';
import {buildProject,kitRoot} from '../scripts/build.mjs';
import {snapshotTree,sourceLimits} from '../scripts/input-inventory.mjs';
import {phase} from '../scripts/phase-driver.mjs';
import {readInventory} from '../scripts/captured-store.mjs';
import {fixedEnvironment,identity,limits,manifestLimit,lineLimit} from '../scripts/runtime.mjs';
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
async function fixture(run){const root=await fsp.realpath(await fsp.mkdtemp(path.join(os.tmpdir(),'sp-production-test-'))),source=path.join(root,'project'),output=path.join(root,'output'),store=path.join(root,'snapshot');await fsp.mkdir(path.join(source,'src'),{recursive:true});await fsp.writeFile(path.join(root,'sentinel.ts'),'export const stolen="PROHIBITED_CONTENT_SENTINEL";');try{await run({root,source,output,store});}finally{await fsp.rm(root,{recursive:true,force:true});}}
function noReads(run){const read=fs.readSync;let count=0;fs.readSync=(...a)=>{count++;return read(...a);};try{run();assert.equal(count,0);}finally{fs.readSync=read;}}
async function captured(source,store,output){const s=await phase('snapshot',{source,sourceIdentity:Object.fromEntries(['dev','ino','mode'].map(k=>[k,fs.lstatSync(source)[k]])),store},120000);return {source,store,output,manifest:s.manifest,manifestSha256:s.manifestSha256,manifestIdentity:s.manifestIdentity};}
async function instrumented(name,job,{killReady=false,env=fixedEnvironment(job)}={}){
 const c=fork(new URL('support/read-sentinel.mjs',import.meta.url),[name],{execArgv:name==='bundle'?[]:['--jitless'],serialization:'advanced',env,stdio:['ignore','pipe','pipe','ipc']});let packet,ready,stdout='',stderr='',killAt;const start=performance.now();c.stdout.on('data',b=>stdout+=b);c.stderr.on('data',b=>stderr+=b);c.on('message',p=>{if(p.type==='ready'){ready=p;if(killReady){killAt=performance.now()-start;c.kill('SIGKILL');}}else packet=p;});const timer=setTimeout(()=>c.kill('SIGKILL'),60000);const exit=await new Promise((resolve,reject)=>{c.once('error',reject);c.once('close',(code,signal)=>resolve({code,signal}));});clearTimeout(timer);return {packet,ready,stdout,stderr,exit,killAt,elapsedMs:performance.now()-start};
}

test('source snapshot rejects symlinks/special files and limits before contents are read',async()=>fixture(async({root,source})=>{
 const sentinel=path.join(root,'sentinel.ts');for(const [name,create]of [['link.ts',p=>fs.symlinkSync(sentinel,p)],['directory',p=>fs.symlinkSync(root,p)],['pipe',p=>execFileSync('/usr/bin/mkfifo',[p])]]){const p=path.join(source,name);create(p);noReads(()=>assert.throws(()=>snapshotTree(source),/symlinks and special/));fs.unlinkSync(p);}
 const p=path.join(source,'large'),fd=fs.openSync(p,'w');fs.ftruncateSync(fd,sourceLimits.bytes+1);fs.closeSync(fd);noReads(()=>assert.throws(()=>snapshotTree(source),/limits exceeded/));fs.truncateSync(p,sourceLimits.bytes);assert.equal(snapshotTree(source).bytes,sourceLimits.bytes);fs.unlinkSync(p);
 for(let i=0;i<=sourceLimits.files;i++)fs.writeFileSync(path.join(source,String(i)),'');noReads(()=>assert.throws(()=>snapshotTree(source),/limits exceeded/));fs.unlinkSync(path.join(source,String(sourceLimits.files)));assert.equal(snapshotTree(source).files.size,sourceLimits.files);
}));

test('source mutation/replacement is detected and immutable snapshot survives later edits',async()=>fixture(async({source,root})=>{
 const a=path.join(source,'a.ts'),b=path.join(source,'b.ts');fs.writeFileSync(a,'first');fs.writeFileSync(b,'second');const target=fs.statSync(path.join(root,'sentinel.ts')),read=fs.readSync;let prohibited=0;fs.readSync=(fd,...args)=>{const s=fs.fstatSync(fd);if(s.dev===target.dev&&s.ino===target.ino){prohibited++;throw Error('sentinel read');}return read(fd,...args);};const open=fs.openSync;fs.openSync=(p,...args)=>{const fd=open(p,...args);if(p===a){fs.unlinkSync(b);fs.symlinkSync(path.join(root,'sentinel.ts'),b);}return fd;};try{assert.throws(()=>snapshotTree(source),/changed/);assert.equal(prohibited,0);}finally{fs.readSync=read;fs.openSync=open;}fs.unlinkSync(b);fs.writeFileSync(b,'second');fs.readSync=(fd,...args)=>{if(fs.fstatSync(fd).ino===fs.statSync(a).ino)fs.writeFileSync(a,'changed');return read(fd,...args);};try{assert.throws(()=>snapshotTree(source),/changed/);}finally{fs.readSync=read;}const s=snapshotTree(source);fs.writeFileSync(a,'later');assert.equal(s.files.get(a).toString(),'changed');
}));

test('guarded TypeScript triple-slash/type/import resolution does not read prohibited contents',async()=>fixture(async({root,source,store,output})=>{
 const sentinel=path.join(root,'sentinel.ts');for(const text of ['import {stolen} from "../../sentinel";console.log(stolen);',`import {stolen} from ${JSON.stringify(sentinel)};console.log(stolen);`,'/// <reference path="../../sentinel.ts" />\nconsole.log(1);',`/// <reference types=${JSON.stringify(sentinel.slice(0,-3))} />\nconsole.log(1);`]){await fsp.writeFile(path.join(source,'src/main.tsx'),text);const job=await captured(source,store,output),r=await instrumented('typecheck',job);assert.equal(r.packet.type,'failure');assert.match(r.packet.message,/not found|Cannot find/);assert.deepEqual(JSON.parse(r.stdout),{prohibitedReads:0});await fsp.rm(store,{recursive:true});}
}));

test('maintained package redirects, CSS imports/assets and URL imports cannot access outside inventory',async()=>fixture(async({root,source,store,output})=>{
 await fsp.mkdir(path.join(source,'src/redirect'));await fsp.writeFile(path.join(source,'src/redirect/package.json'),JSON.stringify({main:'../../../sentinel.ts',types:'../../../sentinel.ts'}));
 for(const [main,css]of [['import "./redirect";',''],['import "./style.css";','@import "../../sentinel.ts";'],['import "./style.css";',`body{background:url(${JSON.stringify(path.join(root,'sentinel.ts'))})}`],['import "./style.css";','body{background:url(https://example.org/private.png)}'],['import "https://example.org/private.js";','']]){await fsp.writeFile(path.join(source,'src/main.tsx'),main);await fsp.writeFile(path.join(source,'src/style.css'),css);const job=await captured(source,store,output),r=await instrumented('bundle',job);assert.equal(r.packet.type,'failure');assert.match(r.packet.message,/resolve|inventory/);assert.deepEqual(JSON.parse(r.stdout),{prohibitedReads:0});await fsp.rm(store,{recursive:true});}
}));

test('manifest bootstrap regularity, bounds, hash, UTF8, ranges and backing tampering fail closed',async()=>fixture(async({root,source})=>{
 const store=path.join(root,'manual');fs.mkdirSync(store);const backing=path.join(store,'00000');fs.writeFileSync(backing,'safe');const p=path.join(source,'src/main.tsx'),manifest=path.join(store,'manifest.ndjson');
 function write(lines){fs.writeFileSync(manifest,lines);return [manifest,hash(Buffer.from(lines)),identity(fs.statSync(manifest))];}
 function valid(){return write(JSON.stringify({version:1,source,kit:kitRoot,backing:{name:'00000',...identity(fs.statSync(backing))},entries:1})+'\n'+JSON.stringify([p,'00000',0,4,hash(Buffer.from('safe'))])+'\n');}
 let args=valid();let inv=readInventory(...args);assert.equal(inv.read(p).toString(),'safe');fs.renameSync(backing,backing+'.old');fs.writeFileSync(backing,'evil');assert.throws(()=>inv.read(p),/identity changed/);assert.equal(inv.audit().backingReads,1);fs.unlinkSync(backing);fs.renameSync(backing+'.old',backing);
 args=valid();inv=readInventory(...args);fs.truncateSync(backing,1);assert.throws(()=>inv.read(p),/identity changed/);assert.equal(inv.audit().backingReads,0);fs.writeFileSync(backing,'safe');
 args=valid();fs.appendFileSync(manifest,'bad');assert.throws(()=>readInventory(...args),/identity changed/);
 args=valid();const original=fs.readFileSync(manifest,'utf8'),lines=original.trim().split('\n'),entry=JSON.parse(lines[1]);entry[2]=1;args=write(lines[0]+'\n'+JSON.stringify(entry)+'\n');assert.throws(()=>readInventory(...args),/ranges/);
 args=write(lines[0]+'\n'+'x'.repeat(lineLimit+1));assert.throws(()=>readInventory(...args),/line exceeds/);
 fs.writeFileSync(manifest,'');fs.truncateSync(manifest,manifestLimit+1);args=[manifest,'a'.repeat(64),identity(fs.statSync(manifest))];assert.throws(()=>readInventory(...args),/identity changed/);
 args=valid();const originalRead=fs.readSync;let passes=0;fs.readSync=(fd,b,o,n,p)=>{const count=originalRead(fd,b,o,n,p);if(p===0&&++passes===2){const i=b.indexOf('main.tsx');if(i>=0)b[i+3]^=1;}return count;};try{const isolated=await import('../scripts/captured-store.mjs?second-pass-test');assert.throws(()=>isolated.readInventory(...args),/identity changed/);}finally{fs.readSync=originalRead;}
 args=valid();fs.renameSync(manifest,manifest+'.old');fs.symlinkSync(manifest+'.old',manifest);assert.throws(()=>readInventory(...args),/identity changed/);
}));

test('initialized bundler is killed after observed readiness and all channels close',async()=>fixture(async({source,store,output})=>{
 await fsp.writeFile(path.join(source,'src/main.tsx'),'import {ArrowRight} from "lucide-react";console.log(ArrowRight);');const job=await captured(source,store,output),r=await instrumented('bundle',job,{killReady:true});assert.ok(r.ready.initializedMs>0);assert.ok(r.killAt>0);assert.deepEqual(r.exit,{code:null,signal:'SIGKILL'});assert.ok(r.elapsedMs-r.killAt<5000);console.log('initialized-kill-receipt '+JSON.stringify({ready:r.ready,killAt:r.killAt,elapsedMs:r.elapsedMs,exit:r.exit}));
}));

test('fixed child environment rejects extra/changed values and spawn failure closes promptly',async()=>fixture(async({source,store,output})=>{
 await fsp.writeFile(path.join(source,'src/main.tsx'),'console.log(1);');const job=await captured(source,store,output);for(const env of [{...fixedEnvironment(job),NODE_OPTIONS:'--trace-warnings'},{...fixedEnvironment(job),UV_USE_IO_URING:'1'}]){const r=await instrumented('typecheck',job,{env});assert.equal(r.packet.type,'failure');assert.match(r.packet.message,/environment/);assert.deepEqual(JSON.parse(r.stdout),{prohibitedReads:0});}
 const original=process.execPath;try{Object.defineProperty(process,'execPath',{value:path.join(source,'missing-node'),configurable:true});await assert.rejects(phase('snapshot',{source,sourceIdentity:Object.fromEntries(['dev','ino','mode'].map(k=>[k,fs.lstatSync(source)[k]])),store},1000),e=>{assert.equal(e.code,'ENOENT');assert.equal(e.phaseReceipt.reaped,true);return true;});}finally{Object.defineProperty(process,'execPath',{value:original,configurable:true});}
}));

test('on-time compilation followed by late publication rolls back previous output and cleans owned work',async()=>fixture(async({source,output,root})=>{
 await fsp.writeFile(path.join(source,'src/main.tsx'),'console.log(1);');await fsp.mkdir(output);await fsp.writeFile(path.join(output,'previous'),'valid');const rename=fsp.rename,clock=globalThis.performance;let advance=0;globalThis.performance={now:()=>clock.now()+advance};fsp.rename=async(a,b)=>{await rename(a,b);if(b===output&&!a.endsWith('.previous'))advance=limits.jobMs;};try{await assert.rejects(buildProject(source,output),/deadline/);}finally{fsp.rename=rename;globalThis.performance=clock;}assert.equal(await fsp.readFile(path.join(output,'previous'),'utf8'),'valid');assert.deepEqual((await fsp.readdir(root)).filter(n=>n.startsWith('.screenpunk-build-')),[]);
}));

test('caller configs are hidden; maintained pure/mixed module semantics match baseline bytes',async()=>fixture(async({root,source,output})=>{
 const baseline=JSON.parse(await fsp.readFile(new URL('support/baseline-controls.json',import.meta.url),'utf8'));
 await fsp.writeFile(path.join(source,'tsconfig.json'),JSON.stringify({extends:path.join(root,'sentinel.ts'),compilerOptions:{alwaysStrict:true,paths:{escape:[path.join(root,'sentinel.ts')]}}}));await fsp.writeFile(path.join(source,'jsconfig.json'),'not JSON');await fsp.writeFile(path.join(source,'src/main.tsx'),'import "./interop.js";');
 for(const name of ['cjs','mixed']){await fsp.copyFile(new URL('support/'+name+'.txt',import.meta.url),path.join(source,'src/interop.js'));await buildProject(source,output);for(const f of baseline[name])assert.equal(hash(await fsp.readFile(path.join(output,f.path))),f.sha256,name+':'+f.path);}
}));

test('valid multiformat project emits contained imported CSS/JSON/JS/SVG/PNG/font assets',async()=>fixture(async({source,output})=>{
 const src=path.join(source,'src');await fsp.writeFile(path.join(src,'main.tsx'),'import {createRoot} from "react-dom/client";import {Card} from "@screenpunk/ui";import {value} from "./value.js";import data from "./data.json";import "./style.css";createRoot(document.getElementById("root")!).render(<Card>{value+data.value}</Card>);');await fsp.writeFile(path.join(src,'value.js'),'export const value=1;');await fsp.writeFile(path.join(src,'data.json'),'{"value":2}');await fsp.writeFile(path.join(src,'style.css'),'@import "./nested.css";body{background:url("./icon.svg")}');await fsp.writeFile(path.join(src,'nested.css'),'@font-face{font-family:test;src:url("./font.woff2")} .photo{background:url("./pixel.png")}');await fsp.writeFile(path.join(src,'icon.svg'),'<svg xmlns="http://www.w3.org/2000/svg"/>');await fsp.writeFile(path.join(src,'font.woff2'),'wOF2fixture');await fsp.writeFile(path.join(src,'pixel.png'),Buffer.from([137,80,78,71,13,10,26,10]));const r=await buildProject(source,output);assert.equal(r.files.filter(f=>f.path.startsWith('assets/')).length,3);assert.match(await fsp.readFile(path.join(output,'screen.css'),'utf8'),/assets\//);
}));

test('both full pinned golden examples preserve exact package inventories',async()=>fixture(async({root})=>{
 const baseline=JSON.parse(await fsp.readFile(new URL('support/baseline-controls.json',import.meta.url),'utf8'));for(const name of ['gallery','earthquakes']){const out=path.join(root,name),r=await buildProject(path.join(kitRoot,'templates',name),out);assert.deepEqual(Object.keys(r).sort(),['bytes','dependencies','files']);assert.equal(r.files.length,baseline[name].length);for(const f of baseline[name])assert.equal(hash(await fsp.readFile(path.join(out,f.path))),f.sha256,name+':'+f.path);console.log('golden-receipt '+JSON.stringify({name,bytes:r.bytes,files:baseline[name]}));}
}));

test('package.type preserves maintained CJS/default interop at runtime',async()=>fixture(async({source,output})=>{
 await fsp.writeFile(path.join(source,'src/main.tsx'),'import "./interop.js";');await fsp.writeFile(path.join(source,'src/interop.js'),'import legacy,{value} from "./legacy.cjs";globalThis.INTEROP={legacy,value};');await fsp.writeFile(path.join(source,'src/legacy.cjs'),'module.exports={__esModule:true,default:"decorated",value:"named"};');
 for(const type of ['commonjs','module']){await fsp.writeFile(path.join(source,'package.json'),JSON.stringify({type}));await buildProject(source,output);const context={};vm.runInNewContext(await fsp.readFile(path.join(output,'screen.js'),'utf8'),context);assert.deepEqual(JSON.parse(JSON.stringify(context.INTEROP)),{legacy:type==='module'?{__esModule:true,default:'decorated',value:'named'}:'decorated',value:'named'});}
}));

test('late initial setup and notice writes cannot publish; cleanup failure after commit is explicit',async()=>fixture(async({source,output,root})=>{
 await fsp.writeFile(path.join(source,'src/main.tsx'),'console.log(1);');await fsp.mkdir(output);await fsp.writeFile(path.join(output,'previous'),'valid');
 const clock=globalThis.performance,mkdtemp=fsp.mkdtemp,write=fsp.writeFile,rm=fsp.rm;let advance=0;
 globalThis.performance={now:()=>clock.now()+advance};fsp.mkdtemp=async(...a)=>{const result=await mkdtemp(...a);advance=limits.jobMs;return result;};try{await assert.rejects(buildProject(source,output),/deadline/);}finally{fsp.mkdtemp=mkdtemp;globalThis.performance=clock;}assert.equal(await fsp.readFile(path.join(output,'previous'),'utf8'),'valid');assert.deepEqual((await fsp.readdir(root)).filter(n=>n.startsWith('.screenpunk-build-')),[]);
 advance=0;globalThis.performance={now:()=>clock.now()+advance};fsp.writeFile=async(p,...a)=>{const r=await write(p,...a);if(String(p).endsWith('THIRD-PARTY-NOTICES.txt'))advance=limits.jobMs;return r;};try{await assert.rejects(buildProject(source,output),/deadline/);}finally{fsp.writeFile=write;globalThis.performance=clock;}assert.equal(await fsp.readFile(path.join(output,'previous'),'utf8'),'valid');assert.deepEqual((await fsp.readdir(root)).filter(n=>n.startsWith('.screenpunk-build-')),[]);
 fsp.rm=async(p,...a)=>{if(String(p).endsWith('.previous'))throw Error('test backup cleanup failure');return rm(p,...a);};try{await assert.rejects(buildProject(source,output),e=>{assert.equal(e.committed,true);assert.ok(e.commitMs<limits.jobMs);assert.match(e.message,/Output committed/);return true;});}finally{fsp.rm=rm;}assert.ok(fs.existsSync(path.join(output,'screen.js')));assert.ok((await fsp.readdir(root)).some(n=>n.endsWith('.previous')));
}));

test('selected parent aliases work; final-root symlinks and replacement before capture do not read new content',async()=>fixture(async({root,source,output})=>{
 await fsp.writeFile(path.join(source,'src/main.tsx'),'console.log(1);');await fsp.symlink(root,path.join(root,'parent-alias'));await buildProject(path.join(root,'parent-alias','project'),output);assert.ok(fs.existsSync(path.join(output,'screen.js')));
 const link=path.join(root,'final-link');await fsp.symlink(source,link);await assert.rejects(buildProject(link,output),/symlinks and special/);
 const realpath=fsp.realpath;let replaced=false;fsp.realpath=async p=>{if(p===source&&!replaced){replaced=true;await fsp.rename(source,source+'.old');await fsp.mkdir(path.join(source,'src'),{recursive:true});await fsp.writeFile(path.join(source,'src/main.tsx'),'PROHIBITED_REPLACEMENT_CONTENT');}return realpath(p);};try{await assert.rejects(buildProject(source,output),/root changed/);}finally{fsp.realpath=realpath;}
 assert.ok(fs.existsSync(path.join(output,'screen.js')));
 const original=fs.lstatSync(source+'.old'),expected={dev:original.dev,ino:original.ino,mode:original.mode};noReads(()=>assert.throws(()=>snapshotTree(source,{rootIdentity:expected}),/root changed/));
}));

test('renamed stage ownership ends at publication; combined cleanup retains primary cause and all failed paths',async()=>fixture(async({source,output})=>{
 await fsp.writeFile(path.join(source,'src/main.tsx'),'console.log(1);');const rm=fsp.rm;let staleStageRemovals=0;
 fsp.rm=async(p,...a)=>{if(path.basename(String(p)).startsWith('.screenpunk-build-')&&!String(p).endsWith('.previous')){staleStageRemovals++;throw Error('stale stage removal');}return rm(p,...a);};try{await buildProject(source,output);}finally{fsp.rm=rm;}assert.equal(staleStageRemovals,0);
 await fsp.writeFile(path.join(source,'src/main.tsx'),'const bad: number="bad";');const stageFailure=Error('stage cleanup blocked'),captureFailure=Error('capture cleanup blocked');let failedPaths=[];
 fsp.rm=async(p,...a)=>{if(path.basename(String(p)).startsWith('.screenpunk-build-')){failedPaths.push(p);throw stageFailure;}if(path.basename(String(p)).startsWith('screenpunk-capture-')){failedPaths.push(p);throw captureFailure;}return rm(p,...a);};try{await assert.rejects(buildProject(source,output),e=>{assert.ok(e instanceof AggregateError);assert.equal(e.errors[0],e.cause);assert.match(e.cause.message,/not assignable/);assert.ok(e.errors.includes(stageFailure));assert.ok(e.errors.includes(captureFailure));assert.deepEqual(e.cleanupPaths,failedPaths);assert.equal(e.committed,undefined);return true;});}finally{fsp.rm=rm;for(const p of failedPaths)await rm(p,{recursive:true,force:true});}assert.ok(fs.existsSync(path.join(output,'screen.js')));
}));
