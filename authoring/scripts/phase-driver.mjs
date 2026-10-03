import {fork} from 'node:child_process';
import {serialize} from 'node:v8';
import {fixedEnvironment,limits,exactKeys} from './runtime.mjs';
function validatePacket(name,p) {
 if(p?.type==='failure')return exactKeys(p,['type','message'])&&typeof p.message==='string'&&p.message.length<=limits.diagnostics;
 if(p?.type==='ready')return name==='bundle'&&exactKeys(p,['type','initializedMs'])&&Number.isFinite(p.initializedMs)&&p.initializedMs>=0;
 if(p?.type!=='result')return false;
 return exactKeys(p,name==='snapshot'?['type','manifest','manifestSha256','manifestIdentity','audit']:name==='bundle'?['type','result','audit']:['type','audit']);
}
// This entry point accepts only fixed phase names; caller build API supplies no
// hooks, worker paths, executable, env, flags or compiler options.
export async function phase(name,data,deadlineMs) {
 if(!['snapshot','typecheck','bundle'].includes(name)||!Number.isFinite(deadlineMs)||deadlineMs<=0||deadlineMs>limits.jobMs)throw Error('Invalid compiler phase');
 const start=performance.now();let child,timer,packet,ready,closed,spawnError,protocolError,deadline=false,messages=0,bytes=0,stderr='',stdoutBytes=0;
 try {
  child=fork(new URL('./'+name+'-worker.mjs',import.meta.url),[],{serialization:'advanced',execArgv:name==='bundle'?[]:['--jitless'],execPath:process.execPath,env:fixedEnvironment(data),stdio:['ignore','pipe','pipe','ipc']});
  const close=new Promise(resolve=>child.once('close',(code,signal)=>{closed={code,signal};resolve();}));
  const kill=()=>{if(child.pid&&!closed)child.kill('SIGKILL');};
  child.once('error',e=>{spawnError=e;kill();});
  child.stdout.on('data',b=>{stdoutBytes+=b.length;protocolError=Error('Unexpected compiler stdout');kill();});
  child.stderr.on('data',b=>{if(Buffer.byteLength(stderr)+b.length>65536){protocolError=Error('Compiler stderr exceeds bounds');kill();}stderr=(stderr+String(b)).slice(0,limits.diagnostics);});
  child.on('message',p=>{
   try {messages++;bytes+=serialize(p).length;if(messages>2||bytes>limits.protocolBytes||!validatePacket(name,p)||packet||(p.type==='ready'&&ready))throw Error('Invalid compiler controller protocol');
    if(p.type==='ready'){ready={initializedMs:p.initializedMs,observedMs:performance.now()-start};return;}
    if(name==='bundle'&&p.type==='result'&&!ready)throw Error('Compiler result before initialization');packet=p;
   }catch(e){protocolError=e;kill();}
  });
  timer=setTimeout(()=>{deadline=true;kill();},deadlineMs);
  await close; // close follows exit AND all stdio/IPC closure, including ENOENT.
  const receipt={phase:name,pid:child.pid,elapsedMs:performance.now()-start,exit:closed,reaped:true,ready,messages,bytes,stdoutBytes};
  const error=deadline?Error('Full build deadline exceeded'):spawnError??protocolError??(packet?.type==='failure'?Error(packet.message):closed.code!==0||!packet?Error(stderr||'Compiler phase failed'):undefined);
  if(error){error.phaseReceipt=receipt;throw error;}
  return {...packet,phaseReceipt:receipt};
 }finally{
  clearTimeout(timer);
  // fork may throw before returning a process. No handles exist in that case.
  if(child&&!closed){if(child.pid)child.kill('SIGKILL');await new Promise(resolve=>child.once('close',resolve));}
  if(child){child.removeAllListeners();child.stdout?.destroy();child.stderr?.destroy();if(child.connected)child.disconnect();}
 }
}
