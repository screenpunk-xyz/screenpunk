import fs from 'node:fs';
import ts from 'typescript';
import {validateConnectionFiles} from '../scripts/validate-connection-files.mjs';
import {validatePackage} from './validate.mjs';
try {
 const input=process.argv[2];const stat=fs.lstatSync(input);
 if(!stat.isFile()||stat.isSymbolicLink()||stat.size>32*1024*1024)throw Error('Invalid or oversized validation request.');
 const request=JSON.parse(fs.readFileSync(input,'utf8'));
 validatePackage(ts,request.files,request.connections,validateConnectionFiles);
 process.stdout.write(JSON.stringify({ok:true}));
}catch(e){process.stdout.write(JSON.stringify({ok:false,message:String(e.message).slice(0,4096)}));process.exitCode=1;}
