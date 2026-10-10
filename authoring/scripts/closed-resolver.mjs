import fs from 'node:fs/promises';
import path from 'node:path';
import { insideApprovedRoots } from './input-plan.mjs';

const extensions = ['.tsx', '.ts', '.jsx', '.js', '.mjs', '.cjs', '.css', '.json', '.svg', '.png', '.jpg', '.jpeg', '.webp', '.woff', '.woff2'];
const loaders = new Map([['.tsx','tsx'],['.ts','ts'],['.jsx','jsx'],['.js','js'],['.mjs','js'],['.cjs','js'],['.css','css'],['.json','json'],['.svg','file'],['.png','file'],['.jpg','file'],['.jpeg','file'],['.webp','file'],['.woff','file'],['.woff2','file']]);

function contains(root, candidate) { return candidate === root || candidate.startsWith(root + path.sep); }
function safePackageName(name) { return /^(?:@[a-z0-9._-]+\/)?[a-z0-9._-]+$/.test(name) && !name.includes('..'); }

export function createClosedResolver({ source, kit, sourceFiles }) {
  const loaded = new Set();
  const emptyModule = path.join(kit, '.screenpunk-empty-module.js');
  const sourceSet = new Set(sourceFiles);
  const metadataCache = new Map();
  const allowed = candidate => insideApprovedRoots(candidate, source, kit);

  async function stat(candidate) {
    if (!allowed(candidate)) throw Error(`Resolution escaped approved roots: ${candidate}`);
    try {
      const value = await fs.lstat(candidate);
      if (value.isSymbolicLink() || (!value.isFile() && !value.isDirectory())) throw Error(`Unsupported link or member: ${candidate}`);
      return value;
    } catch (error) {
      if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return undefined;
      throw error;
    }
  }

  async function metadata(directory) {
    if (!contains(kit, directory)) throw Error('Project package metadata is unsupported');
    if (metadataCache.has(directory)) return metadataCache.get(directory);
    const file = path.join(directory, 'package.json');
    const info = await stat(file);
    if (!info) { metadataCache.set(directory, {}); return {}; }
    if (!info.isFile() || info.size > 1024 * 1024) throw Error('Invalid kit package metadata');
    const value = JSON.parse(await fs.readFile(file, 'utf8'));
    metadataCache.set(directory, value);
    return value;
  }

  async function containingPackage(file) {
    if (!contains(kit, file)) return undefined;
    for (let directory = path.dirname(file); contains(kit, directory); directory = path.dirname(directory)) {
      const info = await stat(path.join(directory, 'package.json'));
      if (info?.isFile()) return { directory, meta: await metadata(directory) };
      if (directory === kit) break;
    }
    return undefined;
  }

  async function fileAt(candidate) {
    const alternatives = [candidate, ...extensions.map(extension => candidate + extension)];
    for (const name of alternatives) {
      const info = await stat(name);
      if (info?.isFile()) {
        if (!loaders.has(path.extname(name).toLowerCase())) throw Error(`Unsupported input loader: ${name}`);
        if (contains(source, name) && !sourceSet.has(name)) throw Error(`Source was not in the frozen input plan: ${name}`);
        return name;
      }
    }
    const directory = await stat(candidate);
    if (directory?.isDirectory()) {
      const meta = contains(kit, candidate) ? await metadata(candidate) : {};
      for (const main of [meta.browser, meta.module, meta.main]) {
        if (typeof main === 'string' && !path.isAbsolute(main) && !/^[a-z][a-z0-9+.-]*:/i.test(main)) {
          const target = path.resolve(candidate, main);
          if (target === candidate) continue;
          const selected = await fileAt(target);
          if (selected) return selected;
        }
      }
      for (const extension of extensions) {
        const selected = await stat(path.join(candidate, 'index' + extension));
        if (selected?.isFile()) return path.join(candidate, 'index' + extension);
      }
    }
    return undefined;
  }

  function condition(value, kind, wildcard = '') {
    if (typeof value === 'string') return value.replaceAll('*', wildcard);
    if (Array.isArray(value)) {
      for (const option of value) {
        const selected = condition(option, kind, wildcard);
        if (selected) return selected;
      }
      return undefined;
    }
    if (!value || typeof value !== 'object') return undefined;
    const preferred = kind === 'require-call' ? ['browser','require','production','default'] : ['browser','import','module','production','default'];
    for (const key of preferred) {
      if (Object.hasOwn(value, key)) {
        const selected = condition(value[key], kind, wildcard);
        if (selected) return selected;
      }
    }
    return undefined;
  }

  function exportTarget(exports, subpath, kind) {
    if (typeof exports === 'string' || Array.isArray(exports)) return subpath === '.' ? condition(exports, kind) : undefined;
    if (!exports || typeof exports !== 'object') return undefined;
    const keys = Object.keys(exports);
    if (!keys.some(key => key.startsWith('.'))) return subpath === '.' ? condition(exports, kind) : undefined;
    if (Object.hasOwn(exports, subpath)) return condition(exports[subpath], kind);
    const matches = keys.filter(key => key.includes('*') && key.startsWith('.')).sort((a,b) => b.length - a.length);
    for (const key of matches) {
      const [prefix, suffix] = key.split('*');
      if (subpath.startsWith(prefix) && subpath.endsWith(suffix) && subpath.length >= prefix.length + suffix.length) {
        const wildcard = subpath.slice(prefix.length, subpath.length - suffix.length);
        const selected = condition(exports[key], kind, wildcard);
        if (selected) return selected;
      }
    }
    return undefined;
  }

  async function packageEntry(directory, subpath, kind) {
    const meta = await metadata(directory);
    if (meta.exports !== undefined) {
      const target = exportTarget(meta.exports, subpath, kind);
      if (typeof target !== 'string' || !target.startsWith('./')) throw Error(`Unsupported or unresolved package export: ${subpath}`);
      const selected = await fileAt(path.resolve(directory, target));
      if (selected) return selected;
      throw Error(`Missing package export: ${subpath}`);
    }
    if (subpath !== '.') {
      const selected = await fileAt(path.resolve(directory, subpath.slice(2)));
      if (selected) return selected;
      throw Error(`Missing package subpath: ${directory} ${subpath}`);
    }
    for (const main of [meta.browser, meta.module, meta.main, './index.js']) {
      if (typeof main !== 'string') continue;
      const selected = await fileAt(path.resolve(directory, main));
      if (selected) return selected;
    }
    throw Error(`Missing package entry: ${directory}`);
  }

  async function bare(specifier, importer, kind) {
    const parts = specifier.split('/');
    const packageName = specifier.startsWith('@') ? parts.slice(0,2).join('/') : parts[0];
    if (!safePackageName(packageName)) throw Error(`Invalid package name: ${specifier}`);
    const tail = parts.slice(packageName.startsWith('@') ? 2 : 1);
    if (tail.some(part => !part || part === '.' || part === '..')) throw Error('Unsafe package subpath');
    const subpath = tail.length ? './' + tail.join('/') : '.';
    const roots = [];
    if (importer && contains(kit, importer)) {
      for (let dir = path.dirname(importer); contains(kit, dir); dir = path.dirname(dir)) {
        roots.push(path.join(dir, 'node_modules', packageName));
        if (dir === kit) break;
      }
    } else { roots.push(path.join(kit, 'node_modules', packageName)); }
    for (const candidate of roots) {
      const info = await stat(candidate);
      if (info?.isDirectory()) return packageEntry(candidate, subpath, kind);
    }
    throw Error(`Package is not in the verified kit: ${packageName}`);
  }

  async function resolve(specifier, importer = '', kind = 'import-statement') {
    if (/^(?:https?:|data:|node:|\/\/)/i.test(specifier) || specifier.includes('?') || specifier.includes('#')) {
      throw Error(`Unsupported external or dynamic resolution: ${specifier}`);
    }
    const importerPackage = importer ? await containingPackage(importer) : undefined;
    const browserMap = importerPackage?.meta.browser;
    if (browserMap && typeof browserMap === 'object' && Object.hasOwn(browserMap, specifier)) {
      const replacement = browserMap[specifier];
      if (replacement === false) return emptyModule;
      if (typeof replacement !== 'string') throw Error(`Unsupported kit browser mapping: ${specifier}`);
      specifier = replacement.startsWith('./') ? path.resolve(importerPackage.directory, replacement) : replacement;
    }
    if (specifier === '@screenpunk/react') specifier = path.join(kit, 'react/index.tsx');
    if (specifier === '@screenpunk/ui') specifier = path.join(kit, 'ui/index.tsx');
    if (specifier === 'react-remove-scroll-bar') specifier = path.join(kit, 'ui/scrollbar.tsx');
    let result;
    if (path.isAbsolute(specifier)) result = await fileAt(path.resolve(specifier));
    else if (specifier.startsWith('.')) {
      const base = importer ? path.dirname(importer) : source;
      result = await fileAt(path.resolve(base, specifier));
    } else result = await bare(specifier, importer, kind);
    if (!result) throw Error(`Unresolved input: ${specifier}`);
    const owner = await containingPackage(result);
    if (owner && owner.meta.browser && typeof owner.meta.browser === 'object') {
      const key = './' + path.relative(owner.directory, result).split(path.sep).join('/');
      if (Object.hasOwn(owner.meta.browser, key)) {
        const replacement = owner.meta.browser[key];
        if (replacement === false) result = emptyModule;
        else if (typeof replacement === 'string' && replacement.startsWith('./')) {
          result = await fileAt(path.resolve(owner.directory, replacement));
          if (!result) throw Error(`Missing kit browser replacement: ${replacement}`);
        } else throw Error(`Unsupported kit browser replacement: ${key}`);
      }
    }
    return result;
  }

  async function load(file) {
    if (file === emptyModule) return { contents: '', loader: 'js', resolveDir: kit };
    const info = await stat(file);
    if (!info?.isFile() || info.size > 50 * 1024 * 1024) throw Error(`Input member limit: ${file}`);
    if (contains(source, file) && !sourceSet.has(file)) throw Error(`Source was not in the frozen input plan: ${file}`);
    const loader = loaders.get(path.extname(file).toLowerCase());
    if (!loader) throw Error(`Unsupported input loader: ${file}`);
    loaded.add(file);
    return { contents: await fs.readFile(file), loader, resolveDir: path.dirname(file) };
  }

  return { resolve, load, loaded };
}
