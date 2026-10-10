import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { planProjectInputs, insideApprovedRoots } from '../scripts/input-plan.mjs';

async function fixture(run) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'screenpunk-input-'));
  try {
    await fs.mkdir(path.join(root, 'src'));
    await fs.writeFile(path.join(root, 'src/main.tsx'), 'export {}');
    await run(root);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
}

test('plans a source tree without following links', async () => fixture(async root => {
  const plan = await planProjectInputs(root);
  assert.deepEqual([...plan.files.values()].map(file => file.relative), ['src/main.tsx']);
  await fs.symlink('/etc/hosts', path.join(root, 'src/outside.ts'));
  await assert.rejects(planProjectInputs(root), /link or escape/);
}));

test('rejects every project-selected config and dependency tree before compilation', async () => {
  for (const name of ['tsconfig.json', 'TSConfig.JSON', 'jsconfig.json', 'package.json', '.env', 'vite.config.ts', 'node_modules']) {
    await fixture(async root => {
      const file = path.join(root, name);
      if (name === 'node_modules') await fs.mkdir(file); else await fs.writeFile(file, '{}');
      await assert.rejects(planProjectInputs(root), /configuration or dependency tree/);
    });
  }
});

test('rejects special members and outside-root paths', async () => fixture(async root => {
  await fs.writeFile(path.join(root, 'src/unknown.sh'), 'exit 0');
  await assert.rejects(planProjectInputs(root), /Unsupported source member/);
  assert.equal(insideApprovedRoots('/etc/passwd', root, '/opt/kit'), false);
  assert.equal(insideApprovedRoots(path.join(root, 'src/main.tsx'), root, '/opt/kit'), true);
}));

test('accepts 31/32-component and 512-byte relative source paths, rejects 33 components', async () => {
  for (const components of [31, 32, 33]) {
    await fixture(async root => {
      const parts = ['src', ...Array(components - 2).fill('d'), 'asset.json'];
      const relative = parts.join('/');
      assert.equal(parts.length, components);
      const file = path.join(root, ...parts);
      await fs.mkdir(path.dirname(file), { recursive: true });
      await fs.writeFile(file, '{}');
      if (components <= 32) {
        const plan = await planProjectInputs(root);
        assert.equal([...plan.files.values()].some(member => member.relative === relative), true);
      } else {
        await assert.rejects(planProjectInputs(root), /nesting limit/);
      }
    });
  }
  await fixture(async root => {
    const directories = ['src', ...Array(22).fill('d'.repeat(16)), ...Array(8).fill('e'.repeat(15))];
    const parts = [...directories, 'a.json'];
    const relative = parts.join('/');
    assert.equal(Buffer.byteLength(relative), 512);
    assert.equal(parts.length, 32);
    const file = path.join(root, ...parts);
    await fs.mkdir(path.dirname(file), { recursive: true });
    await fs.writeFile(file, '{}');
    const plan = await planProjectInputs(root);
    assert.equal([...plan.files.values()].some(member => member.relative === relative), true);
  });
});

test('bounds directory traversal depth, entries, cancellation and deadline', async () => {
  await fixture(async root => {
    await fs.mkdir(path.join(root, 'src', ...Array(32).fill('d')), { recursive: true });
    await assert.rejects(planProjectInputs(root), /nesting limit/);
  });
  await fixture(async root => {
    const directory = path.join(root, 'src');
    for (let i = 0; i < 4000; i++) await fs.mkdir(path.join(directory, `d${i}`));
    await assert.rejects(planProjectInputs(root), /Too many source entries/);
  });
  await fixture(async root => {
    const controller = new AbortController(); controller.abort();
    await assert.rejects(planProjectInputs(root, { signal: controller.signal }), /cancelled or timed out/);
    await assert.rejects(planProjectInputs(root, { deadline: -1 }), /cancelled or timed out/);
  });
});
