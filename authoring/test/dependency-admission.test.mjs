import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { inspectProjectScript, isProjectScript, rejectBuildWarnings } from '../scripts/dependency-admission.mjs';

const compilerPath = process.env.SCREENPUNK_TEST_TYPESCRIPT;
const ts = compilerPath ? (await import(pathToFileURL(compilerPath).href)).default : null;

test('normalizes accepted script extensions and rejects indirect dependencies',
  { skip: !ts && 'Provide SCREENPUNK_TEST_TYPESCRIPT for the read-only compiler fixture' }, () => {
    for (const name of ['main.TS', 'main.TSX', 'main.JS', 'main.JSX']) {
      assert.equal(isProjectScript(name), true);
      assert.throws(() => inspectProjectScript(ts, name, 'const r = require; r("outside");'), /Ambient module-loader/);
      assert.throws(() => inspectProjectScript(ts, name, 'const r = globalThis["require"]; r("outside");'), /Ambient module-loader/);
      assert.throws(() => inspectProjectScript(ts, name, 'const r = globalThis[`require`]; r("./fixture");'), /Ambient module-loader/);
      assert.throws(() => inspectProjectScript(ts, name, 'const r = globalThis["re" + "quire"]; r("./fixture");'), /Ambient module-loader/);
      assert.throws(() => inspectProjectScript(ts, name, 'const g = globalThis; g[key]("./fixture");'), /Ambient module-loader/);
      assert.throws(() => inspectProjectScript(ts, name, 'import("./" + name);'), /literal path/);
      assert.doesNotThrow(() => inspectProjectScript(ts, name, 'import("./inside.js");'));
      assert.doesNotThrow(() => inspectProjectScript(ts, name, 'const record = { a: 1 }; const value = record[key];'));
    }
  });

test('known template project scripts satisfy the ES module admission policy',
  { skip: !ts && 'Provide SCREENPUNK_TEST_TYPESCRIPT for the read-only compiler fixture' }, async () => {
    for (const relative of ['earthquakes/src/main.tsx', 'earthquakes/src/data.ts', 'gallery/src/main.tsx']) {
      const url = new URL(`../templates/${relative}`, import.meta.url);
      const contents = await fs.readFile(url, 'utf8');
      assert.doesNotThrow(() => inspectProjectScript(ts, url.pathname, contents));
    }
  });

test('fails a successful compiler result with unresolved or unsupported warnings', () => {
  assert.doesNotThrow(() => rejectBuildWarnings([]));
  assert.throws(() => rejectBuildWarnings([{ text: 'non-analyzable import left unresolved' }]),
    /dependency warnings/);
});
