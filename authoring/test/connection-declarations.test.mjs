import assert from 'node:assert/strict';
import {test} from 'node:test';
import ts from 'typescript';
import {validateConnectionFiles} from '../scripts/validate-connection-files.mjs';
const check=(text,connections=[])=>validateConnectionFiles(ts,[{path:'src/main.tsx',text}],{connections});
const tv={alias:'googleTV',required:false};
test('missing Google TV declaration is actionable across recognized syntax',()=>{
 for(const source of [
  `screenpunk.connections.request('googleTV','status',{})`,
  `window.screenpunk?.connections?.request?.('googleTV','status',{})`,
  `globalThis['screenpunk']['connections']['request']('googleTV','status',{})`,
  `const sp = window.screenpunk; sp.connections.request('googleTV','key',{})`,
  `const request = screenpunk.connections.request; request('googleTV','status',{})`,
  `import {useScreenpunk as useClient} from '@screenpunk/react'; const sp=useClient(); sp?.connections.request('googleTV','status',{})`,
 ]) assert.throws(()=>check(source),/main.tsx:1:.*missing connection declaration for "googleTV"/);
});
test('optional and required entries pass; unrelated edits preserve all fields',()=>{
 for(const required of [false,true]){
  const connections=[{...tv,required},{alias:'home',required:false,serviceCalls:[{domain:'light',service:'turn_on',entityIds:['light.room']}]}];
  const before=structuredClone(connections);
  check(`screenpunk.connections.request('googleTV','status',{})`,connections);
  check(`const title='New title'; screenpunk.connections.request('googleTV','status',{})`,connections);
  assert.deepEqual(connections,before);
  assert.throws(()=>check(`screenpunk.connections.request('googleTV','status',{})`,connections.filter(c=>c.alias!=='googleTV')),/missing connection/);
 }
});
test('comments strings names local lookalikes and SDK-independent APIs do not require Google TV',()=>{
 for(const source of [
  `// screenpunk.connections.request('googleTV','status',{})\nconst title='Google TV';`,
  `const example="screenpunk.connections.request('googleTV','status',{})";`,
  `const screenpunk={connections:{request(){}}}; screenpunk.connections.request('googleTV');`,
  `function example(screenpunk){screenpunk.connections.request('googleTV')}`,
  `const window={screenpunk:{connections:{request(){}}}};window.screenpunk.connections.request('googleTV');`,
  `screenpunk.state.get('googleTV'); new Audio('sound.mp3');`,
  `const x=/googleTV/;`,
 ]) assert.doesNotThrow(()=>check(source));
});
test('literal non-TV aliases and React public/subscription hooks require their own declarations',()=>{
 for(const [source,alias] of [
  [`screenpunk.connections.read('weather','now')`,'weather'],
  [`screenpunk.connections.request('googleCalendar','events',{})`,'googleCalendar'],
  [`screenpunk.connections.read('appleMaps','snapshot',{})`,'appleMaps'],
  [`screenpunk.homeAssistant.callService({})`,'home'],
  [`screenpunk.cameras.mount(element,{})`,'home'],
  [`import {usePublicRead as useRead} from '@screenpunk/react'; useRead('weather','now')`,'weather'],
  [`import {useConnectionSubscription} from '@screenpunk/react'; useConnectionSubscription('home','states',{},()=>{})`,'home'],
 ]) {assert.throws(()=>check(source),new RegExp(`missing connection declaration for "${alias}"`));check(source,[{alias,required:false}]);}
});
test('computed aliases and custom wrappers are explicitly outside static proof',()=>{
 check(`screenpunk.connections.request(alias,'status',{})`);
 check(`function send(client){client.connections.request('googleTV','status',{})}`);
});
