import fs from 'node:fs/promises';
import path from 'node:path';

const configNames = new Set([
  'tsconfig.json', 'jsconfig.json', 'package.json', 'package-lock.json',
  'yarn.lock', 'pnpm-lock.yaml', '.npmrc', '.node-version', '.babelrc',
  'babel.config.js', 'vite.config.js', 'vite.config.ts', 'webpack.config.js',
]);
const supported = /\.(?:tsx?|jsx?|json|css|svg|png|jpe?g|webp|woff2?)$/i;
const maxFiles = 2000;
const maxEntries = 4000;
const maxDepth = 32;
const maxBytes = 50 * 1024 * 1024;

function below(root, candidate) {
  return candidate === root || candidate.startsWith(root + path.sep);
}

/**
 * V1 React builds use fixed compiler options and the kit's fixed dependency graph.
 * Project-selected compiler and package configuration cannot be interpreted safely.
 */
export async function planProjectInputs(source, { signal, deadline = performance.now() + 120_000 } = {}) {
  const check = () => {
    if (signal?.aborted || performance.now() >= deadline) throw Error('Source traversal cancelled or timed out');
  };
  check();
  if ((await fs.lstat(source)).isSymbolicLink()) throw Error('Project source root is a link');
  const root = await fs.realpath(source);
  const rootStat = await fs.lstat(root);
  if (!rootStat.isDirectory()) throw Error('Project source is not a directory');
  const files = new Map();
  const names = new Set();
  let bytes = 0;
  let entries = 0;
  async function walk(dir, depth) {
    check();
    const directory = await fs.opendir(dir);
    for await (const entry of directory) {
      check();
      if (++entries > maxEntries) throw Error('Too many source entries');
      const absolute = path.join(dir, entry.name);
      const relative = path.relative(root, absolute).split(path.sep).join('/');
      if (depth + 1 > maxDepth) throw Error(`Source nesting limit: ${relative}`);
      const portable = relative.toLowerCase();
      if (!/^[A-Za-z0-9_.@/-]{1,512}$/.test(relative) || relative.split('/').some(part => part === '.' || part === '..') || names.has(portable)) {
        throw Error(`Unsafe or colliding source member: ${relative}`);
      }
      names.add(portable);
      if (!below(root, absolute) || entry.isSymbolicLink()) throw Error(`Source link or escape: ${relative}`);
      const lower = entry.name.toLowerCase();
      if (lower === 'node_modules' || lower === 'dist' || configNames.has(lower) ||
          /^(?:\.env(?:\.|$)|\.pnp\.|.*\.config\.[cm]?[jt]s$)/.test(lower)) {
        throw Error(`Project-selected configuration or dependency tree is unsupported: ${relative}`);
      }
      if (entry.isDirectory()) { await walk(absolute, depth + 1); continue; }
      if (!entry.isFile() || !supported.test(entry.name)) throw Error(`Unsupported source member: ${relative}`);
      const stat = await fs.lstat(absolute);
      if (stat.nlink !== 1 || !stat.isFile() || stat.size > maxBytes - bytes) throw Error(`Source member limit: ${relative}`);
      files.set(absolute, { relative, bytes: stat.size, dev: stat.dev, ino: stat.ino });
      bytes += stat.size;
      if (files.size > maxFiles) throw Error('Too many source files');
    }
  }
  await walk(root, 0);
  if (!files.has(path.join(root, 'src/main.tsx'))) throw Error('Missing src/main.tsx');
  return Object.freeze({ root, files, bytes });
}

export function insideApprovedRoots(candidate, source, kit) {
  const absolute = path.resolve(candidate);
  return below(source, absolute) || below(kit, absolute);
}
