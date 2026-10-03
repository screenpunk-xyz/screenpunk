import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import {phase} from './phase-driver.mjs';
import {readInventory} from './captured-store.mjs';
import {kitRoot,limits,assertRuntime,validPath,exactKeys} from './runtime.mjs';
export {kitRoot};
const html='<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="screen.css"><title>Screenpunk</title></head><body><div id="root"></div><script src="screen.js"></script></body></html>';
function capturedNotices(inventory,inputs,check) {
 const roots=new Set();for(const input of inputs){const marker=input.lastIndexOf('/node_modules/');if(marker<0)continue;const tail=input.slice(marker+14).split('/');roots.add(input.slice(0,marker+14)+tail.slice(0,tail[0].startsWith('@')?2:1).join('/'));}
 const sections=[];let total=0;
 const decode=p=>{check();const b=inventory.read(p);if(!b)throw Error('Notice input is not captured');if(b.length>limits.outputBytes-total)throw Error('Screenpunk package limits exceeded');return b.toString('utf8');};
 const add=s=>{total+=Buffer.byteLength(s);if(total>limits.outputBytes)throw Error('Screenpunk package limits exceeded');sections.push(s);};
 const paths=[...inventory.files.keys()];
 for(const root of [...roots].sort()){
  check();const pkg=JSON.parse(decode(root+'/package.json')),licenses=paths.filter(p=>path.dirname(p)===root&&/^(licen[cs]e|notice|copying)/i.test(path.basename(p))).sort();
  if(!licenses.length){add(`${pkg.name}@${pkg.version} (${pkg.license})\n${decode(kitRoot+'/licenses/'+pkg.name.replaceAll('/','__')+'.txt')}`);if(pkg.name==='victory-vendor'){const names=new Set(paths.filter(p=>p.startsWith(root+'/lib-vendor/')).map(p=>p.slice((root+'/lib-vendor/').length).split('/')[0]));for(const n of [...names].sort()){const p=root+'/lib-vendor/'+n+'/LICENSE';if(inventory.files.has(p))add(`${n} (vendored)\n${decode(p)}`);}}}
  else add(`${pkg.name}@${pkg.version} (${pkg.license})\n${licenses.map(decode).join('\n')}`);
 }
 add(decode(kitRoot+'/ui/NOTICE.txt'));return sections.join('\n\n----------------------------------------\n\n');
}
export async function buildProject(source,output) {
 const started=performance.now();let committed=false,commitMs,stage,capture,backup,oldMoved=false,published=false,primaryError;const cleanupErrors=[];
 const check=()=>{if(performance.now()-started>=limits.jobMs)throw Error('Full build publication deadline exceeded');};
 // Async filesystem operations cannot be cancelled by a JavaScript timer.
 // Observe their completion and deadline before further work/publication.
 const step=async operation=>{check();const result=await operation();check();return result;};
 try {
  assertRuntime();source=path.resolve(source);output=path.resolve(output);
  if(!validPath(source)||!validPath(output))throw Error('Compiler path exceeds bounds');
  const sourceStat=await step(()=>fs.lstat(source));if(!sourceStat.isDirectory()||sourceStat.isSymbolicLink())throw Error('Source symlinks and special files are not allowed');
  // Parent aliases selected by the caller may resolve; bind the canonical root
  // to the originally selected final directory entry before any content read.
  const selected=source;source=await step(()=>fs.realpath(selected));
  const selectedAgain=await step(()=>fs.lstat(selected)),canonical=await step(()=>fs.lstat(source));
  if(!selectedAgain.isDirectory()||selectedAgain.isSymbolicLink()||!canonical.isDirectory()||['dev','ino','mode'].some(k=>sourceStat[k]!==selectedAgain[k]||sourceStat[k]!==canonical[k]))throw Error('Selected project root changed');
  const sourceIdentity={dev:sourceStat.dev,ino:sourceStat.ino,mode:sourceStat.mode};
  const unsafe=()=>output===path.parse(output).root||output===source||source.startsWith(output+path.sep)||output===kitRoot||kitRoot.startsWith(output+path.sep)||(output.startsWith(source+path.sep)&&!output.startsWith(path.join(source,'dist')+path.sep)&&output!==path.join(source,'dist'));
  if(unsafe())throw Error('Unsafe output directory');
  await step(()=>fs.mkdir(path.dirname(output),{recursive:true}));
  output=path.join(await step(()=>fs.realpath(path.dirname(output))),path.basename(output));if(unsafe())throw Error('Unsafe output directory');
  try{const s=await step(()=>fs.lstat(output));if(s.isSymbolicLink()||!s.isDirectory())throw Error('Unsafe output directory');}catch(e){if(e.code!=='ENOENT')throw e;}
  // Set ownership before post-operation deadline checks so finally can remove a
  // mkdtemp that completed after the deadline instead of leaking it.
  check();stage=await fs.mkdtemp(path.join(path.dirname(output),'.screenpunk-build-'));check();
  const temp=await step(()=>fs.realpath(os.tmpdir()));check();capture=await fs.mkdtemp(path.join(temp,'screenpunk-capture-'));check();
  const store=path.join(capture,'snapshot'),common={source,store,output:stage};
  const run=async(name,data)=>{check();const packet=await phase(name,data,limits.jobMs-(performance.now()-started));check();return packet;};
  const snapshot=await run('snapshot',{source,sourceIdentity,store});
  if(snapshot.manifest!==path.join(store,'manifest.ndjson'))throw Error('Invalid snapshot controller response');
  const captured={...common,manifest:snapshot.manifest,manifestSha256:snapshot.manifestSha256,manifestIdentity:snapshot.manifestIdentity};
  await run('typecheck',captured);
  const bundled=await run('bundle',captured);
  if(!exactKeys(bundled.result,['metafile','outputFiles'])||!Array.isArray(bundled.result.outputFiles))throw Error('Invalid compiler output response');
  let bytes=0;const names=new Set();
  for(const f of bundled.result.outputFiles){
   check();if(!exactKeys(f,['path','contents'])||typeof f.path!=='string'||!Buffer.isBuffer(f.contents))throw Error('Invalid compiler output');
   const relative=path.relative(stage,f.path);
   if(!relative||relative.split(path.sep).includes('..')||path.isAbsolute(relative)||names.has(relative)||names.size>=limits.outputFiles||f.contents.length>limits.outputBytes-bytes)throw Error('Screenpunk package limits exceeded');
   bytes+=f.contents.length;names.add(relative);await step(()=>fs.mkdir(path.dirname(f.path),{recursive:true}));await step(()=>fs.writeFile(f.path,f.contents,{flag:'wx'}));
  }
  if(!names.has('screen.js'))throw Error('Missing compiler output');
  if(!names.has('screen.css'))await step(()=>fs.writeFile(path.join(stage,'screen.css'),'',{flag:'wx'}));
  await step(()=>fs.writeFile(path.join(stage,'index.html'),html,{flag:'wx'}));
  const inputs=[...new Set(Object.values(bundled.result.metafile.outputs).flatMap(o=>Object.entries(o.inputs).filter(([,v])=>v.bytesInOutput>0).map(([f])=>path.resolve(kitRoot,f))))];
  check();const inventory=readInventory(snapshot.manifest,snapshot.manifestSha256,snapshot.manifestIdentity);check();
  const notice=capturedNotices(inventory,inputs,check);check();await step(()=>fs.writeFile(path.join(stage,'THIRD-PARTY-NOTICES.txt'),notice,{flag:'wx'}));
  const files=[];bytes=0;
  async function walk(dir){for(const item of await step(()=>fs.readdir(dir,{withFileTypes:true}))){const p=path.join(dir,item.name);if(item.isDirectory())await walk(p);else{const s=await step(()=>fs.lstat(p));if(!s.isFile()||s.isSymbolicLink()||files.length>=limits.outputFiles||s.size>limits.outputBytes-bytes)throw Error('Screenpunk package limits exceeded');bytes+=s.size;files.push({path:path.relative(stage,p),bytes:s.size});}}}
  await walk(stage);
  // Captured-state teardown is completed and observed before publication.
  await step(()=>fs.rm(capture,{recursive:true,force:true}));capture=undefined;
  backup=stage+'.previous';check();
  try{await fs.rename(output,backup);oldMoved=true;check();}catch(e){if(e.code!=='ENOENT')throw e;check();}
  await fs.rename(stage,output);stage=undefined;published=true;check();
  commitMs=performance.now()-started;committed=true;
  // Commit occurred on time. Cleanup is awaited, but may cross the deadline;
  // deletion of an old backup is not advertised as a cancellable transaction.
  if(oldMoved){await fs.rm(backup,{recursive:true,force:true});oldMoved=false;}
  return {bytes,files,dependencies:inputs.filter(f=>f.includes('/node_modules/')).length};
 }catch(error){
  primaryError=error;
  if(!committed){
   if(published)try{await fs.rm(output,{recursive:true,force:true});}catch(e){cleanupErrors.push({path:output,error:e});}
   if(oldMoved)try{await fs.rename(backup,output);oldMoved=false;}catch(e){cleanupErrors.push({path:backup,error:e});}
  }else{error.message='Output committed; owned cleanup failed: '+error.message;error.committed=true;error.commitMs=commitMs;}
  throw error;
 }finally{
  // No background mutation. Cleanup/restoration is outside the120s commit
  // bound and requires the separately enforced170s external hard deadline.
  for(const owned of [stage,capture].filter(Boolean))try{await fs.rm(owned,{recursive:true,force:true});}catch(error){cleanupErrors.push({path:owned,error});}
  if(cleanupErrors.length){
   const cause=primaryError??cleanupErrors[0].error;
   const message=((committed?'Output committed; ':'')+String(cause.message)+'; owned cleanup/restoration failed').slice(0,limits.diagnostics);
   const error=new AggregateError([...(primaryError?[primaryError]:[]),...cleanupErrors.map(e=>e.error)],message,{cause});
   error.cleanupPaths=cleanupErrors.map(e=>e.path);
   if(committed){error.committed=true;error.commitMs=commitMs;}
   throw error;
  }
 }
}
if(process.argv[1]&&await fs.realpath(process.argv[1])===fileURLToPath(import.meta.url)){
 try{console.log(JSON.stringify(await buildProject(process.argv[2],process.argv[3])));}catch(error){console.error(String(error.message).slice(0,limits.diagnostics));process.exitCode=1;}
}
