import {test} from 'node:test';import assert from 'node:assert/strict';import {parseQuakes} from '../templates/earthquakes/src/data';
test('empty and malformed public data are distinct',()=>{assert.deepEqual(parseQuakes({features:[]}),[]);assert.throws(()=>parseQuakes({error:true}));assert.throws(()=>parseQuakes({features:[{properties:{time:'bad'}}]}));});
