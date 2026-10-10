// Synthetic fixture instrumentation only. It observes JS-level file reads and denies
// common Node network entry points; native esbuild and OS syscalls are outside its scope.
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import net from 'node:net';
import http from 'node:http';
import https from 'node:https';
import dns from 'node:dns';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const source = path.resolve(process.argv[2]);
const kit = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const outsideReads = new Set();
let reads = 0;
let networkCalls = 0;
function allowed(candidate) {
  return candidate === source || candidate.startsWith(source + path.sep) ||
    candidate === kit || candidate.startsWith(kit + path.sep);
}
function note(candidate) {
  const name = candidate instanceof URL ? fileURLToPath(candidate) :
    typeof candidate === 'string' ? candidate : null;
  if (!name || !path.isAbsolute(name)) return;
  reads++;
  if (!allowed(path.resolve(name))) outsideReads.add(name);
}
function wrap(object, key) {
  const original = object[key];
  object[key] = function (candidate, ...rest) {
    note(candidate);
    return Reflect.apply(original, this, [candidate, ...rest]);
  };
}
for (const key of ['readFileSync', 'openSync']) wrap(fs, key);
for (const key of ['readFile', 'open']) wrap(fsp, key);
function denyNetwork() {
  networkCalls++;
  throw Error('Synthetic read-closure fixture blocked a network call');
}
globalThis.fetch = denyNetwork;
for (const object of [net, http, https]) {
  for (const key of ['connect', 'request', 'get']) if (typeof object[key] === 'function') object[key] = denyNetwork;
}
dns.lookup = denyNetwork;

export function reportReadClosure() {
  console.log('SCREENPUNK_READ_PROBE=' + JSON.stringify({
    reads, outsideReads: [...outsideReads].sort(), networkCalls,
  }));
}
