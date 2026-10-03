import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {createInputInventory} from './input-inventory.mjs';
import {workerJob,trustedBytes,limits,lineLimit,manifestLimit,trustedManifestLimit,identity,sendPacket,failWorker} from './runtime.mjs';
const start=performance.now();
try {
 const job=workerJob('snapshot'),cpu=process.cpuUsage();
 const inventory=createInputInventory(job.source,job.kit,job.sourceIdentity),configPath=path.join(job.kit,'tsconfig.json');
 // Validate actual operator bootstrap bytes, not caller config or URLs.
 trustedBytes('tsconfig.json');trustedBytes('node_modules/typescript/lib/typescript.js');trustedBytes('node_modules/esbuild-wasm/lib/browser.js');trustedBytes('node_modules/esbuild-wasm/esbuild.wasm');
 fs.mkdirSync(job.store,{mode:0o700});
 const backingPath=path.join(job.store,'00000'),fd=fs.openSync(backingPath,'wx',0o400),entries=[];let offset=0;
 try {for(const [p,b]of inventory.files){if(/\/(?:tsconfig|jsconfig)\.json$/.test(p)&&p!==configPath)continue;let n=0;while(n<b.length){const c=fs.writeSync(fd,b,n,b.length-n,offset+n);if(!c)throw Error('Captured backing write failed');n+=c;}entries.push([p,String(entries.length).padStart(5,'0'),offset,b.length,crypto.createHash('sha256').update(b).digest('hex')]);offset+=b.length;}}finally{fs.closeSync(fd);}
 let trustedMetadata=0;for(const e of entries)if(!e[0].startsWith(job.source+path.sep)){trustedMetadata+=Buffer.byteLength(JSON.stringify(e)+'\n');}if(trustedMetadata>trustedManifestLimit)throw Error('Pinned kit metadata exceeds its qualified manifest capacity');
 const manifest=path.join(job.store,'manifest.ndjson'),manifestFD=fs.openSync(manifest,'wx',0o400),hash=crypto.createHash('sha256');let manifestBytes=0;
 const write=(value,header=false)=>{const b=Buffer.from(JSON.stringify(value)+'\n');if(b.length>(header?65536:lineLimit)||b.length>manifestLimit-manifestBytes)throw Error('Captured manifest exceeds bounds');let n=0;while(n<b.length){const c=fs.writeSync(manifestFD,b,n,b.length-n,manifestBytes+n);if(!c)throw Error('Captured manifest write failed');n+=c;}hash.update(b);manifestBytes+=b.length;};
 try{write({version:1,source:job.source,kit:job.kit,backing:{name:'00000',...identity(fs.lstatSync(backingPath))},entries:entries.length},true);for(const e of entries)write(e);}finally{fs.closeSync(manifestFD);}
 await sendPacket({type:'result',manifest,manifestSha256:hash.digest('hex'),manifestIdentity:identity(fs.lstatSync(manifest)),audit:{elapsedMs:performance.now()-start,cpu:process.cpuUsage(cpu),inputFiles:entries.length,inputBytes:offset,maxRSSKiB:process.resourceUsage().maxRSS}});
 if(process.connected)process.disconnect();
}catch(error){await failWorker(error);}
