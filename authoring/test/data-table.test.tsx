import {test} from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {create,act} from 'react-test-renderer';
import {registerHooks} from 'node:module';
const aliases=registerHooks({load(url,context,nextLoad){if(url.endsWith("/ui/theme.css"))return {format:"module",source:"",shortCircuit:true};return nextLoad(url,context);},resolve(specifier,context,nextResolve){return nextResolve(specifier==='@screenpunk/react'?new URL('../react/index.tsx',import.meta.url).href:specifier,context);}});
const {DataTable}=await import('../ui/index.tsx');
aliases.deregister();

test('DataTable preserves rendering, sorting and filtering with the v9 compatibility adapter',async()=>{
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT=true;
  let renderer:ReturnType<typeof create>;
  await act(async()=>{renderer=create(<DataTable data={[{name:'Zulu'},{name:'Alpha'}]} columns={[{accessorKey:'name',header:'Name'}]}/>);});
  const text=(node:any):string=>typeof node==='string'?node:(node.children??[]).map(text).join('');
  const cells=()=>renderer!.root.findAllByType('td').map(text);
  assert.deepEqual(cells(),['Zulu','Alpha']);
  await act(async()=>{renderer!.root.findAllByType('button')[0].props.onClick({persist(){},shiftKey:false});});
  assert.deepEqual(cells(),['Alpha','Zulu']);
  assert.equal(renderer!.root.findByType('th').props['aria-sort'],'ascending');
  await act(async()=>{renderer!.root.findByType('input').props.onChange({target:{value:'zul'}});});
  assert.deepEqual(cells(),['Zulu']);
  await act(async()=>{renderer!.root.findByType('input').props.onChange({target:{value:''}});});
  assert.deepEqual(cells(),['Alpha','Zulu']);
  await act(async()=>renderer!.unmount());
});
