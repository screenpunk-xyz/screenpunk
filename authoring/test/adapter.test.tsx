import React, { StrictMode } from 'react';
import { act, create, type ReactTestRenderer } from 'react-test-renderer';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ScreenpunkProvider, useScreenReady, usePublicRead, useConnectionSubscription, type ScreenpunkClient } from '../react/index';
(globalThis as any).IS_REACT_ACT_ENVIRONMENT=true;
function fake(){let status:(s:unknown)=>void=()=>{};const calls={ready:0,subs:0,unsubs:0,reads:0,aborts:0};const client:ScreenpunkClient={runtime:{ready(){calls.ready++},onStatus(f){status=f;return()=>{status=()=>{}}}},connections:{async read(_a,_o,_p,options){calls.reads++;options?.signal?.addEventListener('abort',()=>calls.aborts++);return {state:'fresh',status:200,data:[] as any}},release(){},subscribe(){calls.subs++;return()=>{calls.unsubs++}}}};return {client,calls,status:(v:unknown)=>status(v)}}
const tick=()=>new Promise(r=>setTimeout(r,10));
test('StrictMode readiness is once, subscription cleanup and host suspension are balanced',async()=>{const f=fake();function App(){useScreenReady();useConnectionSubscription('home','states',{},()=>{});return null}let tree:ReactTestRenderer;await act(async()=>{tree=create(<StrictMode><ScreenpunkProvider client={f.client}><App/></ScreenpunkProvider></StrictMode>)});assert.equal(f.calls.ready,1);assert.equal(f.calls.subs-f.calls.unsubs,1);await act(async()=>f.status({active:false}));assert.equal(f.calls.subs,f.calls.unsubs);await act(async()=>f.status({active:true}));assert.equal(f.calls.subs-f.calls.unsubs,1);await act(async()=>tree!.unmount());assert.equal(f.calls.subs,f.calls.unsubs)});
test('public reads cancel on suspension and resume once',async()=>{const f=fake();function App(){usePublicRead('public','read');return null}let tree:ReactTestRenderer;await act(async()=>{tree=create(<ScreenpunkProvider client={f.client}><App/></ScreenpunkProvider>)});await act(tick);assert.equal(f.calls.reads,1);await act(async()=>f.status({active:false}));assert.equal(f.calls.aborts,1);await act(async()=>f.status({active:true}));await act(tick);assert.equal(f.calls.reads,2);await act(async()=>tree!.unmount());assert.equal(f.calls.aborts,2)});
test('late responses from a superseded request are ignored and permission failure is explicit',async()=>{const f=fake();let finish:(v:any)=>void=()=>{};let observed:any;f.client.connections.read=()=>new Promise(r=>{finish=r});function App({alias}:{alias:string}){observed=usePublicRead(alias,'read').result;return null}let tree:ReactTestRenderer;await act(async()=>{tree=create(<ScreenpunkProvider client={f.client}><App alias="first"/></ScreenpunkProvider>)});await act(tick);const late=finish;f.client.connections.read=async()=>{throw {code:'permission_required'}};await act(async()=>tree!.update(<ScreenpunkProvider client={f.client}><App alias="second"/></ScreenpunkProvider>));await act(tick);assert.equal(observed.state,'permission-required');await act(async()=>late({state:'fresh',status:200,data:'wrong'}));assert.equal(observed.state,'permission-required');await act(async()=>tree!.unmount())});
test('stale, unavailable and errors stay explicit; Retry-After delays manual refresh',async()=>{
 const f=fake();let observed:any;let refresh=()=>{};
 let reply:any={state:'stale',status:503,data:[1],retryAfterSeconds:0.08};
 f.client.connections.read=async()=>{f.calls.reads++;return reply};
 function App(){const read=usePublicRead('public','read');observed=read.result;refresh=read.refresh;return null}
 let tree:ReactTestRenderer;
 await act(async()=>{tree=create(<ScreenpunkProvider client={f.client}><App/></ScreenpunkProvider>)});await act(tick);
 assert.equal(observed.state,'stale');await act(async()=>refresh());await act(tick);assert.equal(f.calls.reads,1);
 reply={state:'unavailable',status:503};await act(async()=>{await new Promise(r=>setTimeout(r,90))});assert.equal(observed.state,'unavailable');
 reply={state:'error',status:500,code:'provider_failed'};await act(async()=>refresh());await act(tick);assert.equal(observed.state,'error');
 await act(async()=>tree!.unmount());
});
