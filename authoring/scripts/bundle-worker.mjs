import { readInventory } from './captured-store.mjs';
import {workerJob,trustedBytes,limits,sendPacket,failWorker} from './runtime.mjs';
import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import { webcrypto } from 'node:crypto';

try {
const workerData=workerJob('bundle');
// Trusted bootstrap only. Compiler runtime receives no Node module loader/fs.
const start = performance.now(),cpuStart=process.cpuUsage();
const browser=trustedBytes('node_modules/esbuild-wasm/lib/browser.js').toString('utf8');
const wasmBytes=trustedBytes('node_modules/esbuild-wasm/esbuild.wasm');
const inventory=readInventory(workerData.manifest,workerData.manifestSha256,workerData.manifestIdentity);const {files}=inventory;
const dirs = new Map([['/', new Set()]]);
for (const file of files.keys()) {
  let dir = path.posix.dirname(file), child = path.posix.basename(file);
  while (true) {
    if (!dirs.has(dir)) dirs.set(dir, new Set());
    dirs.get(dir).add(child);
    if (dir === '/') break;
    child = path.posix.basename(dir); dir = path.posix.dirname(dir);
  }
}
const counts = {}, absent = [], reads = new Set(), loads = new Set(), descriptors = new Map(), logs=[]; let nextFD = 3, ioRead, ioWrite, networkAttempts = 0, nativeAttempts = 0, protocolInputBytes=0,protocolOutputBytes=0;
const protocolByteLimit=limits.protocolBytes,protocolOutputByteLimit=limits.protocolBytes;
const err = code => Object.assign(new Error(code), { code });
const note = (op, p) => { counts[op] = (counts[op] || 0) + 1; if (p && !files.has(p) && !dirs.has(p) && absent.length < 100) absent.push({op,path:p}); };
const normalize = p => { if (typeof p !== 'string' || !p.startsWith('/') || p.includes('\0') || p.includes('\\')) throw err('ENOENT'); return path.posix.normalize(p); };
const info = p => {
  if (!files.has(p) && !dirs.has(p)) throw err('ENOENT');
  return {dev:1, ino:1, mode:dirs.has(p)?0o40555:0o100444, nlink:1, uid:0, gid:0, rdev:0, size:files.sizeOf(p)||0, blksize:4096, blocks:0, atimeMs:0, mtimeMs:0, ctimeMs:0,isDirectory:()=>dirs.has(p),isFile:()=>files.has(p),isSymbolicLink:()=>false};
};
const callback = (cb, fn) => { let value,error;try { value=fn(); } catch (e) {error=e;}queueMicrotask(()=>cb(error||null,value)); };
const host = {
  constants:{O_WRONLY:1,O_RDWR:2,O_CREAT:64,O_TRUNC:512,O_APPEND:1024,O_EXCL:128,O_DIRECTORY:65536},
  open(p, flags, mode, cb) { note('open',p); callback(cb,()=>{p=normalize(p);info(p);if(flags&(1|2|64|512|1024|128))throw err('EROFS');const fd=nextFD++;descriptors.set(fd,{path:p,position:0});return fd;}); },
  close(fd,cb) {note('close');callback(cb,()=>{if(!descriptors.delete(fd))throw err('EBADF');});},
  stat(p,cb){note('stat',p);callback(cb,()=>info(normalize(p)));},
  lstat(p,cb){note('lstat',p);callback(cb,()=>info(normalize(p)));},
  fstat(fd,cb){note('fstat');callback(cb,()=>{const d=descriptors.get(fd);if(!d)throw err('EBADF');return info(d.path);});},
  readdir(p,cb){note('readdir',p);callback(cb,()=>{p=normalize(p);if(!dirs.has(p))throw err(files.has(p)?'EINVAL':'ENOENT');return [...dirs.get(p)];});},
  readlink(p,cb){note('readlink',p);cb(err('EINVAL'));},
  fsync(fd,cb){cb(err('EROFS'));},
  write(fd,buf,offset,length,position,cb){if(fd!==1&&fd!==2)return cb(err('EROFS'));callback(cb,()=>host.writeSync(fd,buf.subarray(offset,offset+length)));},
};
const inventoryRead=(fd,buf,offset,length,position,cb)=>{note('read');callback(cb,()=>{const d=descriptors.get(fd);if(!d)throw err('EBADF');const bytes=files.get(d.path);if(!bytes)throw err('EISDIR');reads.add(d.path);const pos=position===null?d.position:position;const count=Math.min(length,Math.max(0,bytes.length-pos));buf.set(bytes.subarray(pos,pos+count),offset);if(position===null)d.position+=count;return count;});};
// Upstream browser service replaces read/writeSync for its protocol pipes.
// Keep protocol descriptors separate from the read-only inventory descriptors.
Object.defineProperty(host,'read',{get:()=>((fd,buf,offset,length,position,cb)=>fd===0?ioRead(fd,buf,offset,length,position,(error,count)=>{protocolInputBytes+=count||0;if(protocolInputBytes>protocolByteLimit)throw Error('Compiler protocol input limit exceeded');cb(error,count);}):inventoryRead(fd,buf,offset,length,position,cb)),set:fn=>{ioRead=fn;}});
Object.defineProperty(host,'writeSync',{get:()=>((fd,bytes)=>{if(fd===1||fd===2){protocolOutputBytes+=bytes.length;if(protocolOutputBytes>protocolOutputByteLimit){throw Error('Compiler protocol output limit exceeded');}return ioWrite(fd,bytes);}throw err('EROFS');}),set:fn=>{ioWrite=fn;}});
for(const name of ['chmod','chown','fchmod','fchown','ftruncate','lchown','link','mkdir','rename','rmdir','symlink','truncate','unlink','utimes'])host[name]=(...args)=>{note(name);args.at(-1)(err('EROFS'));};
// Sentinel every native filesystem entry after explicit trusted bootstrap.
for (const key of Object.keys(fs)) if(typeof fs[key]==='function') {try{fs[key]=()=>{nativeAttempts++;throw Error('Native filesystem unavailable after bootstrap');};}catch{}}
const processHost={cwd:()=>workerData.kit, chdir:()=>{throw err('EROFS');},getuid:()=>-1,getgid:()=>-1,geteuid:()=>-1,getegid:()=>-1,getgroups:()=>[],pid:-1,ppid:-1,umask:()=>0};
const log=(...s)=>{if(logs.join('\n').length<16000)logs.push(s.join(' ').slice(0,1000));};
const sandbox={fs:host,process:processHost,path:{resolve:(...s)=>path.posix.resolve(...s)},crypto:{getRandomValues:a=>webcrypto.getRandomValues(a)},performance:{now:()=>performance.now()},TextEncoder,TextDecoder,WebAssembly,Uint8Array,Uint8ClampedArray,ArrayBuffer,DataView,RegExp,setTimeout,clearTimeout,console:{log,warn:log,error:log},fetch:()=>{networkAttempts++;throw Error('Network unavailable');}};
sandbox.self=sandbox;
const context=vm.createContext(sandbox,{codeGeneration:{strings:false,wasm:true}});
vm.runInContext(browser,context,{timeout:1000});
const api=sandbox.esbuild;
const module=await WebAssembly.compile(wasmBytes);
await api.initialize({wasmModule:module,worker:false});
const initialized=performance.now();
await sendPacket({type:'ready',initializedMs:initialized-start});

const source=workerData.source,kit=workerData.kit,output=workerData.output;
let result, failure;
try { result=await api.build({absWorkingDir:kit,entryPoints:[source+'/src/main.tsx'],bundle:true,write:false,outfile:output+'/screen.js',format:'iife',platform:'browser',target:['safari16','ios16'],jsx:'automatic',minify:true,metafile:true,sourcemap:false,legalComments:'none',define:{'process.env.NODE_ENV':'"production"'},assetNames:'assets/[hash]',loader:{'.svg':'file','.png':'file','.jpg':'file','.jpeg':'file','.woff':'file','.woff2':'file'},nodePaths:[kit+'/node_modules'],alias:{'@screenpunk/react':kit+'/react/index.tsx','@screenpunk/ui':kit+'/ui/index.tsx'},plugins:[{name:'inventory-boundary',setup(b){
  b.onResolve({filter:/^react-remove-scroll-bar$/},()=>({path:kit+'/ui/scrollbar.tsx'}));
  b.onResolve({filter:/.*/},args=>{if(/^(?:[a-zA-Z][a-zA-Z\d+.-]*:|\/\/)/.test(args.path)||args.path.includes('\\')||args.path.includes('\0'))return{errors:[{text:'Only inventory dependencies and assets are supported'}]};});
  b.onLoad({filter:/.*/},args=>{loads.add(args.path);const bytes=files.get(args.path);if(!bytes)return{errors:[{text:'Input is not in immutable inventory'}]};const ext=path.posix.extname(args.path);let contents=bytes;const loader={'.ts':'ts','.tsx':'tsx','.mts':'ts','.cts':'ts','.js':'js','.jsx':'jsx','.mjs':'js','.cjs':'js','.css':'css','.json':'json','.svg':'file','.png':'file','.jpg':'file','.jpeg':'file','.woff':'file','.woff2':'file'}[ext];if(!loader)return{errors:[{text:'Unsupported packaged input format'}]};if(args.path===kit+'/node_modules/@radix-ui/react-select/dist/index.mjs'){const text=new TextDecoder().decode(bytes),pattern=/jsx\(\s*"style",\s*\{\s*dangerouslySetInnerHTML:[\s\S]*?nonce\s*\}\s*\)/;if(!pattern.test(text))throw Error('Pinned Radix adapter changed');contents=text.replace(pattern,'null');}return{contents,loader,resolveDir:path.posix.dirname(args.path)};});
}}],logLevel:'silent',logLimit:20}); } catch(error) { failure=error.message.slice(0,16000); }
const audit={counts,absent,readCount:reads.size,loadCount:loads.size,nativeAttempts,networkAttempts,protocolInputBytes,protocolOutputBytes,protocolByteLimit,initializedMs:initialized-start,bundleMs:performance.now()-initialized,workerMs:performance.now()-start,cpu:process.cpuUsage(cpuStart),workerMemory:process.memoryUsage(),maxRSSKiB:process.resourceUsage().maxRSS,backingStore:inventory.audit(),moduleRequire:vm.runInContext('typeof require',context),moduleGlobal:vm.runInContext('typeof module',context),nativeProcess:vm.runInContext('typeof process.getBuiltinModule',context),openDescriptors:descriptors.size};
await api.stop();if(failure)await sendPacket({type:'failure',message:failure});else await sendPacket({type:'result',result:{metafile:result.metafile,outputFiles:result.outputFiles.map(f=>({path:f.path,contents:Buffer.from(f.contents)}))},audit});if(process.connected)process.disconnect();
}catch(error){await failWorker(error);}
