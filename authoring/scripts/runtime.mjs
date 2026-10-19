import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
export const kitRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const limits = Object.freeze({sourceFiles:2000, sourceBytes:50*1024*1024, trustedFiles:100000, trustedBytes:512*1024*1024, outputFiles:2000, outputBytes:50*1024*1024, pathBytes:4096, diagnostics:16000, protocolBytes:128*1024*1024, jobMs:120000});
export const entryLimit = limits.sourceFiles + limits.trustedFiles;
export const lineLimit = limits.pathBytes*6 + 256;
// JSON escaped paths have at most six bytes per input byte. The manifest is
// streamed, never allocated at this theoretical upper bound.
export const manifestLimit = 64*1024*1024;
export const trustedManifestLimit = manifestLimit - 65536 - limits.sourceFiles*lineLimit;
export const pins = Object.freeze({
  'tsconfig.json':'61f587ee4ec21279ed19a879ffed2c7fb16fa31bd10e768a0521523c704732aa',
  'node_modules/typescript/lib/typescript.js':'3ae902c92cc44dace175c0e69e13a4b0899f6983c6121d76b9ab8dd5795e7675',
  'node_modules/esbuild-wasm/lib/browser.js':'91593b8f5d1021600a92443717a52e311bb1e1b772981f6aab76cd0ffba33169',
  'node_modules/esbuild-wasm/esbuild.wasm':'b1831a5c0f6cf688034fb94d0419812f165ea316a3380d3fc00a151e562d2eaf'
});
export const same = (a,b) => a.dev===b.dev && a.ino===b.ino && a.mode===b.mode && a.size===b.size && a.mtimeMs===b.mtimeMs && a.ctimeMs===b.ctimeMs;
export function identity(s) {return {dev:s.dev,ino:s.ino,mode:s.mode,size:s.size,mtimeMs:s.mtimeMs,ctimeMs:s.ctimeMs};}
export function validPath(p) {return typeof p==='string' && path.isAbsolute(p) && path.normalize(p)===p && !p.includes('\0') && !p.includes('\\') && Buffer.byteLength(p)<=limits.pathBytes;}
export function exactKeys(value, keys) {return value && typeof value==='object' && !Array.isArray(value) && Object.keys(value).sort().join('\0')===keys.slice().sort().join('\0');}
export function trustedBytes(relative) {
  if(!Object.hasOwn(pins,relative))throw Error('Unapproved compiler bootstrap');
  const file=path.join(kitRoot,relative), before=fs.lstatSync(file);
  if(!before.isFile() || before.isSymbolicLink() || fs.realpathSync(file)!==file || before.size>32*1024*1024)throw Error('Unsafe compiler bootstrap');
  const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW|fs.constants.O_NONBLOCK);
  try {if(!same(before,fs.fstatSync(fd)))throw Error('Compiler bootstrap changed');const b=Buffer.alloc(before.size);let n=0;while(n<b.length){const c=fs.readSync(fd,b,n,b.length-n,n);if(!c)throw Error('Compiler bootstrap truncated');n+=c;}if(!same(before,fs.fstatSync(fd))||!same(before,fs.lstatSync(file))||crypto.createHash('sha256').update(b).digest('hex')!==pins[relative])throw Error('Pinned compiler bootstrap changed');return b;}finally{fs.closeSync(fd);}
}
export function assertRuntime() {
  const [major,minor,patch]=process.versions.node.split('.').map(Number);
  if(major!==24||minor<11||(minor===11&&patch<1)||!['darwin','linux'].includes(process.platform))throw Error('Screenpunk requires Node >=24.11.1 <25 on macOS or Linux');
}
export function fixedEnvironment(job) {return {SP_PHASE:JSON.stringify(job),TZ:'UTC',LANG:'C.UTF-8',UV_USE_IO_URING:'0',...(process.platform==='darwin'?{__CF_USER_TEXT_ENCODING:'0x'+process.getuid().toString(16).toUpperCase()+':0x0:0x0'}:{})};}
export function workerJob(phase) {
  assertRuntime();
  const expected=['SP_PHASE','TZ','LANG','UV_USE_IO_URING',...(process.platform==='darwin'?['__CF_USER_TEXT_ENCODING']:[])];
  if(Object.keys(process.env).sort().join('\0')!==expected.sort().join('\0')||process.env.TZ!=='UTC'||process.env.LANG!=='C.UTF-8'||process.env.UV_USE_IO_URING!=='0'||(process.platform==='darwin'&&process.env.__CF_USER_TEXT_ENCODING!=='0x'+process.getuid().toString(16).toUpperCase()+':0x0:0x0'))throw Error('Unexpected compiler child environment');
  if(process.execArgv.join('\0')!==(phase==='bundle'?'':'--jitless'))throw Error('Unexpected compiler child flags');
  if(!process.env.SP_PHASE||Buffer.byteLength(process.env.SP_PHASE)>65536)throw Error('Compiler job exceeds protocol bounds');
  const job=JSON.parse(process.env.SP_PHASE),keys=phase==='snapshot'?['source','sourceIdentity','store']:['source','store','manifest','manifestSha256','manifestIdentity','output'];
  if(!exactKeys(job,keys)||!validPath(job.source)||!validPath(job.store)||(phase!=='snapshot'&&(!validPath(job.output)||job.manifest!==path.join(job.store,'manifest.ndjson')||!/^[a-f0-9]{64}$/.test(job.manifestSha256))))throw Error('Invalid compiler job');
  if(phase==='snapshot'&&(!exactKeys(job.sourceIdentity,['dev','ino','mode'])||Object.values(job.sourceIdentity).some(v=>!Number.isFinite(v))))throw Error('Invalid selected root identity');
  return Object.freeze({...job,kit:kitRoot});
}
export async function sendPacket(packet) {await new Promise((resolve,reject)=>process.send(packet,e=>e?reject(e):resolve()));}
export async function failWorker(error) {try{await sendPacket({type:'failure',message:String(error.message??error).slice(0,limits.diagnostics)});}finally{if(process.connected)process.disconnect();}}
