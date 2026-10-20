import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import ts from 'typescript-api';
import {createInputInventory} from '../scripts/input-inventory.mjs';
import {kitRoot, trustedBytes} from '../scripts/runtime.mjs';

test('operator CLI is TypeScript 7 while the pinned authoring API remains 5.9.3', () => {
  const version = execFileSync(process.execPath, [path.join(kitRoot, 'node_modules/typescript/bin/tsc'), '--version'], {encoding:'utf8'}).trim();
  assert.equal(version, 'Version 7.0.2');
  assert.equal(ts.version, '5.9.3');
  assert.ok(trustedBytes('node_modules/typescript-api/lib/typescript.js').length > 0);
  assert.throws(() => trustedBytes('node_modules/typescript/lib/typescript.js'), /Unapproved compiler bootstrap/);
});

test('aliased API standard libraries are captured without admitting compiler implementation source', () => {
  const source = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'sp-compiler-alias-')));
  try {
    fs.mkdirSync(path.join(source, 'src'));
    fs.writeFileSync(path.join(source, 'src/main.tsx'), 'export const value: string = "captured";');
    const inventory = createInputInventory(source, kitRoot);
    const apiRoot = path.join(kitRoot, 'node_modules/typescript-api');
    assert.equal(inventory.packages.get(apiRoot).version, '5.9.3');
    assert.ok(inventory.has(ts.getDefaultLibFilePath({target:ts.ScriptTarget.ES2022})));
    assert.ok(inventory.has(path.join(apiRoot, 'lib/lib.dom.d.ts')));
    assert.equal(inventory.has(path.join(apiRoot, 'lib/typescript.js')), false);
    assert.equal(inventory.has(path.join(apiRoot, 'lib/tsc.js')), false);
  } finally {
    fs.rmSync(source, {recursive:true, force:true});
  }
});
