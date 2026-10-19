import test from 'node:test';
import assert from 'node:assert/strict';
import ts from '../node_modules/typescript/lib/typescript.js';
import {validateConnectionFiles} from '../scripts/validate-connection-files.mjs';
import {validatePackage} from './validate.mjs';
const tv="screenpunk.connections.request('googleTV','status',{})";
const check=(text,connections=[],path='index.html')=>validatePackage(ts,[{path,text}],connections,validateConnectionFiles);
test('external and HTML5 inline calls require declaration; optional declarations pass',()=>{
 for(const [text,path] of [[tv,'app.js'],[tv,'app.mjs'],['<html>\n<script type="module">'+tv+'</script>','index.html'],['<SCRIPT data-x=">">'+tv+'</SCRIPT>','index.html']]){
  assert.throws(()=>check(text,[],path),/missing connection declaration.*googleTV/);
  assert.doesNotThrow(()=>check(text,[{alias:'googleTV',required:false}],path));
 }
});
test('HTML parsing does not treat comments, data script, attributes or strings as executable calls',()=>{
 for(const text of ['<!-- <script>'+tv+'</script> -->','<script type="application/json">'+JSON.stringify(tv)+'</script>','<div data-code="'+tv+'"></div>','<script>const screenpunk={connections:{request(){}}};'+tv+'</script>','<script>const text='+JSON.stringify(tv)+'</script>','<script>screenpunk.state.get("x");screenpunk.audio.play("x")</script>'])assert.doesNotThrow(()=>check(text));
});
test('HTML line locations survive markup and quoted greater-than characters',()=>{
 assert.throws(()=>check('<div title=">">Hello</div>\n<script>\n'+tv+'\n</script>'),/index.html.inline-1.js:3:1/);
});
test('input limits reject large or excessive requests',()=>{
 assert.throws(()=>check(' '.repeat(5*1024*1024+1)),/5 MiB/);
 assert.throws(()=>validatePackage(ts,Array(2001).fill({path:'a.js',text:''}),[],validateConnectionFiles),/Invalid/);
});

test('real package members cannot hide an inline diagnostic by colliding with its synthetic name',()=>{
 assert.throws(()=>validatePackage(ts,[{path:'index.html',text:'<script>'+tv+'</script>'},{path:'index.html.inline-1.js',text:'const innocent=1'}],[],validateConnectionFiles),/missing connection.*googleTV/);
});
