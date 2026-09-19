import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createDashboardClient, type BridgeTransport} from '../src/client.ts';
import {validatePublicRead, type ManifestConnection} from '../src/package.ts';
import type {BridgeMessage} from '../src/bridge.ts';

test('older hosts report unsupported while current hosts retain approval failures', async () => {
  for (const supported of [false, true]) {
    let receive: (m: BridgeMessage) => void = () => {};
    const client = createDashboardClient({transport: {
      onMessage(h) { receive = h; return () => {}; },
      send(m) {
        if (m.method === 'connections.request') receive({protocolVersion:1,id:m.id,kind:'error',code:'permission_required'});
        if (m.method === 'runtime.onStatus') receive({protocolVersion:1,id:m.id,kind:'response',value:supported ? {publicReadHTTP:1} : {}});
      }
    }});
    await assert.rejects(client.connections.read('data','timeline'), {code:supported ? 'permission_required' : 'unsupported_version'});
    client.dispose();
  }
});

test('public reads preserve explicit freshness and release scoped resources', async () => {
  let receive: (m: BridgeMessage) => void = () => {};
  const sent: BridgeMessage[] = [];
  const resourceURL = 'screenpunk://package/__native-raster/fixture';
  const transport: BridgeTransport = {
    onMessage(h) { receive = h; return () => {}; },
    send(m) { sent.push(m); if(m.method === 'connections.request') receive({protocolVersion:1,id:m.id,kind:'response',value:{state:'stale',resourceURL,status:503,fetchedAt:'2026-01-01T00:00:00Z'}}); }
  };
  const client = createDashboardClient({transport});
  const result = await client.connections.read('data','frame',{timestamp:'1000'});
  assert.equal(result.state,'stale'); assert.equal(result.resourceURL,resourceURL);
  client.connections.release(resourceURL);
  assert.equal(sent.at(-1)?.method,'connections.release');
  client.dispose();
});
test('abort cancels the exact native request and dispose releases leases', async () => {
  const sent: BridgeMessage[] = [];
  const client = createDashboardClient({transport:{send(m){sent.push(m);},onMessage(){return () => {};}}});
  const abort = new AbortController();
  const promise = client.connections.read('data','frame',{timestamp:'1000'},{signal:abort.signal});
  abort.abort();
  await assert.rejects(promise,{name:'AbortError'});
  assert.equal(sent[1].method,'connections.cancel'); assert.equal(sent[1].parameters?.requestId,sent[0].id);
  client.dispose();
});
test('fixed comma queries and coordinate pairs stay bounded declarations', () => {
  const connection: ManifestConnection = {alias:'data',required:true,publicHTTP:{origin:'https://data.example.org',userAgent:'Screenpunk/1',operations:[{name:'frame',path:'/points/{point}',response:'raster',maxAgeSeconds:10,staleSeconds:20,parameters:{point:{location:'path',values:['12.5,-40.5']},bbox:{location:'query',values:['-10,20,30,40']},fields:{location:'query',values:['first,second']}}}]}};
  validatePublicRead(connection);
  for(const value of ['../secret','%2fsecret','https://elsewhere.example']) {
    const denied = structuredClone(connection); denied.publicHTTP!.operations[0].parameters.point.values = [value];
    assert.throws(() => validatePublicRead(denied));
  }
  const invalid = structuredClone(connection); invalid.publicHTTP!.userAgent = 'X\r\nAuthorization: Y';
  assert.throws(() => validatePublicRead(invalid));
});
