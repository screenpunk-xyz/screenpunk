import http from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);
const orientationCLI = process.argv[3];
const simulator = '4D3753FC-F9CF-4DC9-B422-16499348A0F9';
import { writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
const container = process.argv[2];
if (!container) throw new Error('Pass the isolated Simulator preview app data directory.');
const destination = path.join(container, 'Documents', 'design-state.json');
const scenarios = ['New device','Needs setup','Partly ready','Ready','Needs attention'];
const guidedStates = ['Not set up','Enabled, inactive','Active'];
const presentations = ['Current', 'iOS 18–25', 'iOS 16–17'];
const screens = ['TV remote','Daily information','Home controls'];
let state = { scenario:'Partly ready', screen:'TV remote', count:2, view:'menu', guided:'Not set up', appearance:'System', orientation:'Landscape', presentation:'Current', revision:0 };
await mkdir(path.dirname(destination), {recursive:true});
await writeFile(destination, JSON.stringify(state));
const page = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Screenpunk · Device settings studio</title><style>
*{box-sizing:border-box}body{margin:0;height:100vh;display:flex;flex-direction:column;overflow:hidden;background:#0b0b0c;color:#f3f3f4;font:14px system-ui}header{flex-shrink:0;padding:16px 22px;background:#202023;border-bottom:1px solid #3b3b3f;display:flex;align-items:center;gap:20px;flex-wrap:wrap}h1{font-size:15px;margin:0}small{display:block;color:#a6a6ae;font-size:11px;margin-top:4px}label{display:flex;align-items:center;gap:8px;color:#c9c9d1}select,button{font:inherit;color:white;background:#303036;border:1px solid #56565e;border-radius:7px;padding:8px 10px}button{cursor:pointer}button[aria-pressed=true]{background:#385ddc;border-color:#6c8bfa}nav{display:flex;gap:7px}#status{font-size:12px;color:#a6c9b5}iframe{border:0;width:100%;flex:1;min-height:0;display:block}aside{flex-shrink:0;padding:7px 22px;font-size:12px;color:#a6a6ae}</style></head><body>
<header><div><h1>Screenpunk settings studio</h1><small>Native iPad preview · isolated sample state</small></div>
<label>State <select id="scenario">${scenarios.map(x=>`<option${x===state.scenario?' selected':''}>${x}</option>`).join('')}</select></label>
<label>Screen <select id="screen">${screens.map(x=>`<option>${x}</option>`).join('')}</select></label>
<label>Installed <select id="count"><option value="0">None</option><option value="1">One screen</option><option value="2" selected>Two screens</option><option value="3">Three screens</option><option value="6">Six screens</option><option value="12">Twelve screens</option></select></label>
<label>Guided Access <select id="guided">${guidedStates.map(x=>`<option>${x}</option>`).join('')}</select></label>
<label>Appearance <select id="appearance"><option>System</option><option>Light</option><option>Dark</option></select></label>
<label>iOS presentation <select id="presentation">${presentations.map(x=>`<option>${x}</option>`).join('')}</select></label>
<label>Orientation <select id="orientation"><option>Portrait</option><option selected>Landscape</option></select></label>
<nav><button data-view="welcome">First launch</button><button data-view="screen">Screen</button><button data-view="menu" aria-pressed="true">Screenpunk menu</button><button data-view="settings">Settings</button></nav><span id="status">Sample state</span></header>
<aside>First design pass · First launch and the two-finger hold open the same menu. All screens and connections are sample state. Older presentation modes approximate app behavior; system styling uses the installed simulator OS.</aside>
<iframe title="Native iPad Simulator" src="http://localhost:3200"></iframe>
<script>
let view='menu';
async function update(){const status=document.getElementById('status');status.textContent='Applying…';try{const r=await fetch('/state',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({scenario:document.getElementById('scenario').value,screen:document.getElementById('screen').value,count:Number(document.getElementById('count').value),guided:document.getElementById('guided').value,appearance:document.getElementById('appearance').value,orientation:document.getElementById('orientation').value,presentation:document.getElementById('presentation').value,view})});if(!r.ok)throw Error();status.textContent='Applied to preview';}catch{status.textContent='Preview update failed';}}
for(const id of ['scenario','screen','count','guided','appearance','orientation','presentation'])document.getElementById(id).addEventListener('change',update);
for(const button of document.querySelectorAll('[data-view]'))button.addEventListener('click',()=>{view=button.dataset.view;document.querySelectorAll('[data-view]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));update()});
</script></body></html>`;
http.createServer(async(req,res)=>{
 if(req.method==='GET'&&req.url==='/'){res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});return res.end(page);}
 if(req.method==='POST'&&req.url==='/state'){
  if(req.headers.origin!=='http://localhost:3201'&&req.headers.origin!=='http://127.0.0.1:3201'){res.writeHead(403);return res.end();}
  let raw='';for await(const chunk of req){raw+=chunk;if(raw.length>2048){res.writeHead(413);return res.end();}}
  try{const v=JSON.parse(raw);if(!presentations.includes(v.presentation)||!scenarios.includes(v.scenario)||!screens.includes(v.screen)||![0,1,2,3,6,12].includes(v.count)||!guidedStates.includes(v.guided)||!['System','Light','Dark'].includes(v.appearance)||!['Portrait','Landscape'].includes(v.orientation)||!['welcome','screen','menu','settings'].includes(v.view))throw Error();if(v.orientation!==state.orientation){if(!orientationCLI)throw Error('Missing orientation CLI');await run(process.execPath,[orientationCLI,'rotate',v.orientation==='Landscape'?'landscape_left':'portrait','-d',simulator]);}state={...v,revision:state.revision+1};await writeFile(destination,JSON.stringify(state));res.writeHead(200);res.end('ok');}catch{res.writeHead(400);res.end('Invalid state');}return;
 }res.writeHead(404);res.end();
}).listen(3201,'127.0.0.1',()=>console.log('Settings studio: http://localhost:3201'));
