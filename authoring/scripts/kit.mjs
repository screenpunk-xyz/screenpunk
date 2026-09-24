import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { notices } from './notices.mjs';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const finalDestination=path.resolve(process.argv[2]??path.join(root,'dist/AuthoringKit'));
if(finalDestination===root || root.startsWith(finalDestination+path.sep))throw Error('Unsafe kit destination');
await fs.mkdir(path.dirname(finalDestination),{recursive:true});
const destination=await fs.mkdtemp(path.join(path.dirname(finalDestination),'.AuthoringKit-'));
try {
const archive=process.env.SCREENPUNK_NODE_ARCHIVE;
if(!archive) throw Error('Set SCREENPUNK_NODE_ARCHIVE to the verified Node archive; see toolchain.json');
const pin=JSON.parse(await fs.readFile(path.join(root,'toolchain.json'),'utf8'));
const bytes=await fs.readFile(archive);
if(createHash('sha256').update(bytes).digest('hex')!==pin.node.sha256) throw Error('Node archive checksum mismatch');
await fs.mkdir(destination,{recursive:true});
for(const name of ['scripts','react','ui','templates','licenses','icons','catalog.json','README.md','package.json','package-lock.json','toolchain.json']) await fs.cp(path.join(root,name),path.join(destination,name),{recursive:true});
await fs.cp(path.join(root,'node_modules'),path.join(destination,'node_modules'),{recursive:true,filter:src=>!src.split(path.sep).includes('.bin')});
await fs.mkdir(path.join(root,'dist'),{recursive:true});
const extraction=await fs.mkdtemp(path.join(root,'dist/node-'));
try {
 execFileSync('/usr/bin/tar',['-xzf',archive,'-C',extraction]);
 const distribution=path.join(extraction,(await fs.readdir(extraction))[0]);
 await fs.mkdir(path.join(destination,'bin'),{recursive:true});
 await fs.copyFile(path.join(distribution,'bin/node'),path.join(destination,'bin/node'));
 await fs.chmod(path.join(destination,'bin/node'),0o755);
 await fs.copyFile(path.join(distribution,'LICENSE'),path.join(destination,'NODE-LICENSE.txt'));
} finally {await fs.rm(extraction,{recursive:true,force:true});}
const packages=[];
for(const entry of await fs.readdir(path.join(root,'node_modules'))) {
 if(entry.startsWith('.'))continue;
 const dir=path.join(root,'node_modules',entry);
 if(entry.startsWith('@'))for(const sub of await fs.readdir(dir))packages.push(path.join(dir,sub,'package.json'));
 else packages.push(path.join(dir,'package.json'));
}
await fs.writeFile(path.join(destination,'THIRD-PARTY-NOTICES.txt'),await notices(packages));
await fs.writeFile(path.join(destination,'kit.json'),JSON.stringify({version:'1.0.0',node:pin.node.version,platform:'darwin-arm64',lockSha256:createHash('sha256').update(await fs.readFile(path.join(root,'package-lock.json'))).digest('hex')},null,2));
const backup=finalDestination+'.previous-'+process.pid;
let replaced=false;
try {await fs.rename(finalDestination,backup);replaced=true;} catch(e){if(e.code!=='ENOENT')throw e;}
try {await fs.rename(destination,finalDestination);} catch(e){if(replaced)await fs.rename(backup,finalDestination);throw e;}
if(replaced)await fs.rm(backup,{recursive:true,force:true});
console.log(finalDestination);
} finally {await fs.rm(destination,{recursive:true,force:true});}
