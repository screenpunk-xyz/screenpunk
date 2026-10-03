import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {limits,entryLimit,lineLimit,manifestLimit,trustedManifestLimit,same,exactKeys,validPath} from './runtime.mjs';
// Private capabilities stay outside the WASM VM. No original-path fallback.
const open=fs.openSync.bind(fs),close=fs.closeSync.bind(fs),lstat=fs.lstatSync.bind(fs),fstat=fs.fstatSync.bind(fs),read=fs.readSync.bind(fs);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function openRegular(file,expected,max) {
 const before=lstat(file);
 if(!before.isFile()||before.isSymbolicLink()||before.size>max||!same(before,expected))throw Error('Captured input identity changed');
 const fd=open(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW|fs.constants.O_NONBLOCK);
 try {if(!same(before,fstat(fd)))throw Error('Captured descriptor identity changed');return {fd,before};}catch(e){close(fd);throw e;}
}
export function readInventory(manifestFile,manifestSha256,manifestIdentity){
 if(!validPath(manifestFile)||path.basename(manifestFile)!=='manifest.ndjson'||!/^[a-f0-9]{64}$/.test(manifestSha256)||!exactKeys(manifestIdentity,['dev','ino','mode','size','mtimeMs','ctimeMs'])||Object.values(manifestIdentity).some(v=>!Number.isFinite(v)))throw Error('Invalid manifest capability');
 const {fd,before}=openRegular(manifestFile,manifestIdentity,manifestLimit),root=path.dirname(manifestFile),records=new Map();let header,cursor=0,sourceFiles=0,sourceBytes=0,trustedFiles=0,trustedBytes=0,trustedMetadata=0;
 try {
  // Authenticate the bounded regular descriptor before parsing any record. A
  // streaming first pass prevents an untrusted size from causing a bulk alloc.
  const chunk=Buffer.alloc(65536),hash=crypto.createHash('sha256');let position=0;
  while(position<before.size){const n=read(fd,chunk,0,Math.min(chunk.length,before.size-position),position);if(!n)throw Error('Captured manifest truncated');hash.update(chunk.subarray(0,n));position+=n;}
  if(hash.digest('hex')!==manifestSha256)throw Error('Captured manifest changed');
  const parsedHash=crypto.createHash('sha256');
  position=0;let pending=Buffer.alloc(0),lineNumber=0;
  const parseLine=b=>{
   if(b.length>(lineNumber===0?65536:lineLimit))throw Error('Captured manifest line exceeds bounds');const value=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(b));
   if(lineNumber++===0){
    if(b.length>65536)throw Error('Captured manifest header exceeds bounds');
    if(!exactKeys(value,['version','source','kit','backing','entries'])||value.version!==1||!validPath(value.source)||!validPath(value.kit)||!Number.isSafeInteger(value.entries)||value.entries<1||value.entries>entryLimit||!exactKeys(value.backing,['name','dev','ino','mode','size','mtimeMs','ctimeMs'])||value.backing.name!=='00000')throw Error('Invalid captured manifest header');
    const s=value.backing;if(Object.entries(s).some(([k,v])=>k!=='name'&&!Number.isFinite(v))||!Number.isSafeInteger(s.size)||s.size<0||s.size>limits.sourceBytes+limits.trustedBytes)throw Error('Captured backing exceeds bounds');header=value;return;
   }
   if(records.size>=header.entries||!Array.isArray(value)||value.length!==5)throw Error('Invalid captured record');
   const [p,name,offset,bytes,digest]=value;
   if(!validPath(p)||name!==String(records.size).padStart(5,'0')||!Number.isSafeInteger(offset)||offset!==cursor||!Number.isSafeInteger(bytes)||bytes<0||bytes>header.backing.size-cursor||!/^[a-f0-9]{64}$/.test(digest)||records.has(p)||!(p===header.source||p.startsWith(header.source+path.sep)||p===header.kit||p.startsWith(header.kit+path.sep)))throw Error('Overlapping or invalid captured ranges');
   if(p.startsWith(header.source+path.sep)){sourceFiles++;sourceBytes+=bytes;if(sourceFiles>limits.sourceFiles||sourceBytes>limits.sourceBytes)throw Error('Captured source exceeds bounds');}else{trustedFiles++;trustedBytes+=bytes;trustedMetadata+=b.length+1;if(trustedFiles>limits.trustedFiles||trustedBytes>limits.trustedBytes||trustedMetadata>trustedManifestLimit)throw Error('Captured trusted inventory exceeds bounds');}
   cursor+=bytes;records.set(p,{path:p,name,offset,bytes,sha256:digest});
  };
  while(position<before.size){const n=read(fd,chunk,0,Math.min(chunk.length,before.size-position),position);if(!n)throw Error('Captured manifest truncated');position+=n;parsedHash.update(chunk.subarray(0,n));let start=0;for(let i=0;i<n;i++){if(chunk[i]!==10)continue;const line=Buffer.concat([pending,chunk.subarray(start,i)]);parseLine(line);pending=Buffer.alloc(0);start=i+1;}pending=Buffer.concat([pending,chunk.subarray(start,n)]);if(pending.length>(lineNumber===0?65536:lineLimit))throw Error('Captured manifest line exceeds bounds');}
  if(parsedHash.digest('hex')!==manifestSha256||pending.length||!header||records.size!==header.entries||cursor!==header.backing.size||!same(before,fstat(fd))||!same(before,lstat(manifestFile)))throw Error('Captured manifest identity changed');
 }finally{close(fd);}
 let backingReads=0,backingBytes=0;
 const load=p=>{
  const record=records.get(p);if(!record)return undefined;
  const address=path.join(root,header.backing.name),{fd,before}=openRegular(address,header.backing,limits.sourceBytes+limits.trustedBytes);
  try {const b=Buffer.alloc(record.bytes);let offset=0;while(offset<b.length){const n=read(fd,b,offset,b.length-offset,record.offset+offset);if(!n)throw Error('Captured input truncated');offset+=n;}backingReads++;backingBytes+=b.length;if(!same(before,fstat(fd))||!same(before,lstat(address))||sha(b)!==record.sha256)throw Error('Captured input content changed');return b;}finally{close(fd);}
 };
 const directories=new Set();for(const p of records.keys()){let d=path.dirname(p);while(!directories.has(d)){directories.add(d);const parent=path.dirname(d);if(parent===d)break;d=parent;}}
 const check=p=>{p=path.resolve(p);if(!(p===header.source||p.startsWith(header.source+path.sep)||p===header.kit||p.startsWith(header.kit+path.sep)))throw Error('Input is outside captured inventory');return p;};
 return {source:header.source,files:{get:load,has:p=>records.has(p),keys:()=>records.keys(),sizeOf:p=>records.get(p)?.bytes,size:records.size},directories,read:p=>load(check(p)),has:p=>records.has(check(p)),check,directory:p=>directories.has(path.resolve(p)),manifest:header,audit:()=>({backingReads,backingBytes})};
}
