import fs from 'node:fs';
import path from 'node:path';
import {validPath} from './runtime.mjs';

export const sourceLimits = Object.freeze({ files: 2000, bytes: 50 * 1024 * 1024 });
const same = (a, b) => a.dev === b.dev && a.ino === b.ino && a.mode === b.mode && a.size === b.size && a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs;
const inside = (root, file) => file === root || file.startsWith(root + path.sep);
export const containmentError = () => Error('Compiler input is outside the immutable project or pinned kit inventory');

// Never read through an unverified path. Open without following the final symlink,
// compare the descriptor with the inventoried inode, and recheck every ancestor
// before reading a bounded buffer. Compilers subsequently see only these buffers.
export function snapshotTree(root, { limits = sourceLimits, skip = new Set(['node_modules', 'dist']), include = () => true, rootIdentity } = {}) {
  root = path.resolve(root);
  const dirs = new Map(); const pending = []; const files = new Map(); let bytes = 0;
  const verifyDirs = file => {
    let dir = path.dirname(file);
    while (inside(root, dir)) {
      const expected = dirs.get(dir);
      const actual = fs.lstatSync(dir);
      if (!expected || !actual.isDirectory() || !same(expected, actual)) throw Error('Compiler input directory changed during snapshot');
      if (dir === root) break;
      dir = path.dirname(dir);
    }
  };
  function walk(dir) {
    const stat = fs.lstatSync(dir);
    if (dir===root && rootIdentity && ['dev','ino','mode'].some(k=>stat[k]!==rootIdentity[k])) throw Error('Selected project root changed before snapshot');
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw Error('Source symlinks and special files are not allowed');
    if (fs.realpathSync(dir) !== dir) throw containmentError();
    if (dirs.size >= 10000) throw Error('Too many source directories');
    dirs.set(dir, stat);
    const directory = fs.opendirSync(dir);
    try {
      for (let item; (item = directory.readSync()) !== null;) {
        const file = path.join(dir, item.name);
        if (!validPath(file)) throw Error('Compiler input path exceeds bounds');
        verifyDirs(file);
        const entry = fs.lstatSync(file);
        if (entry.isSymbolicLink() || (!entry.isDirectory() && !entry.isFile())) throw Error('Source symlinks and special files are not allowed');
        if (entry.isDirectory()) { if (!skip.has(item.name)) walk(file); }
        else if (include(file)) {
          if (pending.length >= limits.files || entry.size > limits.bytes - bytes) throw Error(`Compiler input limits exceeded (${limits.files} files / ${limits.bytes} bytes)`);
          bytes += entry.size; pending.push([file, entry]);
        }
      }
    } finally { directory.closeSync(); }
    if (!same(stat, fs.lstatSync(dir))) throw Error('Compiler input directory changed during snapshot');
  }
  walk(root);
  for (const [file, stat] of pending) {
    verifyDirs(file);
    if (!same(stat, fs.lstatSync(file)) || fs.realpathSync(file) !== file) throw Error('Compiler input changed during snapshot');
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
      if (!same(stat, fs.fstatSync(fd))) throw Error('Compiler input changed during snapshot');
      verifyDirs(file);
      if (!same(stat, fs.lstatSync(file)) || fs.realpathSync(file) !== file) throw Error('Compiler input changed during snapshot');
      const data = Buffer.alloc(stat.size); let offset = 0;
      while (offset < data.length) {
        const count = fs.readSync(fd, data, offset, data.length - offset, offset);
        if (!count) throw Error('Compiler input changed during snapshot');
        offset += count;
      }
      if (!same(stat, fs.fstatSync(fd)) || !same(stat, fs.lstatSync(file))) throw Error('Compiler input changed during snapshot');
      verifyDirs(file);
      files.set(file, data);
    } finally { fs.closeSync(fd); }
  }
  // Also detect mutations to earlier files during a later read.
  for (const [file, stat] of pending) { verifyDirs(file); if (!same(stat, fs.lstatSync(file))) throw Error('Compiler input changed during snapshot'); }
  return { root, files, bytes };
}

export function createInputInventory(source, kitRoot, sourceIdentity) {
  const project = snapshotTree(source, {rootIdentity:sourceIdentity});
  const files = new Map(project.files);
  const trustedLimits = { files: 100000, bytes: 512 * 1024 * 1024 };
  let trustedFiles = 0; let trustedBytes = 0;
  function add(root, include, skip = new Set(['node_modules'])) {
    const snapshot = snapshotTree(root, { limits: { files: trustedLimits.files - trustedFiles, bytes: trustedLimits.bytes - trustedBytes }, skip, include });
    trustedFiles += snapshot.files.size; trustedBytes += snapshot.bytes;
    for (const [file, data] of snapshot.files) files.set(file, data);
    return snapshot;
  }
  for (const dir of ['react', 'ui', 'icons', 'licenses']) add(path.join(kitRoot, dir));
  // The lockfile and kit are operator-installed trusted input, never project input.
  // Enumerate only packages in that catalog; a caller's node_modules is excluded.
  const lockFile = path.join(kitRoot, 'package-lock.json');
  const kitPackageFile = path.join(kitRoot, 'package.json');
  const configFile = path.join(kitRoot, 'tsconfig.json');
  const lockSnapshot = add(kitRoot, file => file === lockFile || file === kitPackageFile || file === configFile, new Set(fs.readdirSync(kitRoot).filter(name => fs.lstatSync(path.join(kitRoot, name)).isDirectory())));
  const lock = JSON.parse(lockSnapshot.files.get(lockFile).toString('utf8'));
  const packages = new Map();
  for (const [relative, metadata] of Object.entries(lock.packages)) {
    if (!relative.startsWith('node_modules/') || relative.includes('..') || metadata.link) continue;
    const root = path.join(kitRoot, relative);
    if (!fs.existsSync(root)) { if (metadata.optional) continue; throw Error('Pinned dependency is missing'); }
    add(root, file => relative === 'node_modules/typescript'
      ? file === path.join(root, 'package.json') || (path.dirname(file) === path.join(root, 'lib') && /^lib\..*\.d\.ts$/.test(path.basename(file)))
      : /\.(?:[cm]?[jt]sx?|css|json|svg|png|jpe?g|woff2?|txt|md)$/.test(file) || /^(?:licen[cs]e|notice|copying)/i.test(path.basename(file)));
    const pkgFile = path.join(root, 'package.json');
    const pkg = JSON.parse(files.get(pkgFile)?.toString('utf8') ?? 'null');
    if (!pkg || pkg.version !== metadata.version) throw Error('Pinned dependency version does not match the catalog');
    packages.set(root, pkg);
  }
  const directories = new Set();
  for (const file of files.keys()) { let dir = path.dirname(file); while (!directories.has(dir)) { directories.add(dir); const parent = path.dirname(dir); if (parent === dir) break; dir = parent; } }
  const roots = [project.root, kitPackageFile, lockFile, ...packages.keys(), configFile, ...['react', 'ui', 'icons', 'licenses'].map(dir => path.join(kitRoot, dir))];
  function scope(file) { file = path.resolve(file); const root = roots.filter(root => inside(root, file)).sort((a,b) => b.length - a.length)[0]; if (!root) throw containmentError(); return root; }
  function check(file) { file = path.resolve(file); scope(file); return file; }
  return Object.freeze({ source: project.root, files, packages, directories,
    read(file) { file = check(file); return files.get(file); },
    has(file) { return files.has(check(file)); },
    directory(file) { file = path.resolve(file); return (inside(project.root, file) || inside(kitRoot, file)) && directories.has(file); },
    check, scope,
  });
}
