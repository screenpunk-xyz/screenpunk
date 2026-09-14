import os, json, subprocess, select, time, pathlib, sys, tempfile
if len(sys.argv) != 2:
 raise SystemExit("Usage: python3 scripts/check-packaged-mcp.py /path/to/Screenpunk.app")
exe=str(pathlib.Path(sys.argv[1]).resolve() / 'Contents/MacOS/screenpunk-mcp')
test_store=tempfile.TemporaryDirectory(prefix='screenpunk-packaged-mcp-')
env=dict(os.environ, SCREENPUNK_CONTROLLER_HOME=test_store.name,SCREENPUNK_AGENT_NAME='Build Verification')
log=open('/tmp/screenpunk-mcp-smoke.stderr','w')
p=subprocess.Popen([exe],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,env=env,text=True,bufsize=1)
def send(data): p.stdin.write(json.dumps(data)+'\n'); p.stdin.flush()
def response(id, timeout=45):
 deadline=time.time()+timeout
 while time.time()<deadline:
  if select.select([p.stdout],[],[],max(0,deadline-time.time()))[0]:
   line=p.stdout.readline()
   if not line: raise RuntimeError('MCP exited: '+str(p.poll()))
   value=json.loads(line)
   if value.get('id')==id: return value
 raise TimeoutError(id)
def call(id,name,args):
 send({'jsonrpc':'2.0','id':id,'method':'tools/call','params':{'name':name,'arguments':args}})
 r=response(id)
 if r.get('error') or r.get('result',{}).get('isError'): raise RuntimeError(json.dumps(r))
 return r['result']
try:
 send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'Build Verification','version':'1'}}})
 print('initialize:',response(1)['result']['serverInfo'],flush=True)
 send({'jsonrpc':'2.0','method':'notifications/initialized'})
 send({'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}})
 print('tools:',len(response(2)['result']['tools']),flush=True)
 print('discovery:',call(3,'discover_services',{}),flush=True)
 created=call(4,'update_dashboard',{'name':'Smoke Clock','files':[{'path':'index.html','text':'<!doctype html><html><body><h1>Native build verified</h1><script src="ready.js"></script></body></html>'},{'path':'ready.js','text':'window.screenpunk.runtime.ready();'}]})
 payload=json.loads(created['content'][0]['text'])
 print('saved:',payload,flush=True)
 dashboard=payload.get('dashboardId') or payload.get('dashboard',{}).get('dashboardId')
 preview=call(5,'preview_dashboard',{'dashboardId':dashboard})
 images=[c for c in preview['content'] if c.get('type')=='image']
 assert images
 import base64
 data=base64.b64decode(images[0]['data']); assert data.startswith(b'\x89PNG\r\n\x1a\n')
 pathlib.Path('/tmp/screenpunk-native-preview.png').write_bytes(data)
 print('preview: PNG',len(data),'bytes',flush=True)
finally:
 p.stdin.close()
 try: p.wait(timeout=5)
 except subprocess.TimeoutExpired: p.terminate()

 test_store.cleanup()
