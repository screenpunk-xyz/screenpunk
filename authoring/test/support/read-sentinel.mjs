// Trusted test bootstrap instruments actual content reads in the compiler
// process. No production preload, job override or hook is used.
import fs from 'node:fs';import path from 'node:path';
const job=JSON.parse(process.env.SP_PHASE),sentinel=path.join(path.dirname(job.source),'sentinel.ts'),target=fs.statSync(sentinel);let prohibitedReads=0;
const originalRead=fs.readSync,originalReadFile=fs.readFileSync,originalFstat=fs.fstatSync;
fs.readSync=(fd,...args)=>{const s=originalFstat(fd);if(s.dev===target.dev&&s.ino===target.ino){prohibitedReads++;throw Error('Prohibited sentinel content read');}return originalRead(fd,...args);};
fs.readFileSync=(p,...args)=>{if(typeof p==='number'){const s=originalFstat(p);if(s.dev===target.dev&&s.ino===target.ino){prohibitedReads++;throw Error('Prohibited sentinel content read');}}else if(path.resolve(String(p))===sentinel){prohibitedReads++;throw Error('Prohibited sentinel content read');}return originalReadFile(p,...args);};
process.on('exit',()=>console.log(JSON.stringify({prohibitedReads})));
if(!['typecheck','bundle'].includes(process.argv[2]))throw Error('Fixed test phase required');
await import('../../scripts/'+process.argv[2]+'-worker.mjs');
