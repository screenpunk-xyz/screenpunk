import path from 'node:path';import {readInventory} from './captured-store.mjs';
import {workerJob,trustedBytes,sendPacket,failWorker} from './runtime.mjs';
const start=performance.now(),cpu=process.cpuUsage();
try {const job=workerJob('typecheck');trustedBytes('node_modules/typescript/lib/typescript.js');
const {default:ts}=await import(job.kit+'/node_modules/typescript/lib/typescript.js'); const inventory=readInventory(job.manifest,job.manifestSha256,job.manifestIdentity),source=job.source,kitRoot=job.kit;
  const files = [...inventory.files.keys()].filter(file => file.startsWith(source + path.sep));
  const options = { strict: true, noEmit: true, skipLibCheck: true, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler, jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true, resolveJsonModule: true, allowJs: true,
    baseUrl: kitRoot, paths: { '@screenpunk/react': ['react/index.tsx'], '@screenpunk/ui': ['ui/index.tsx'], 'react': ['node_modules/@types/react/index.d.ts'], 'react/*': ['node_modules/@types/react/*'], 'react-dom/*': ['node_modules/@types/react-dom/*'], '*': ['node_modules/*'] }, typeRoots: [path.join(kitRoot, 'node_modules/@types')], types: ['react','react-dom'], lib: ['lib.es2022.d.ts','lib.dom.d.ts','lib.dom.iterable.d.ts'] };
  const host = ts.createCompilerHost(options);
  const permitted = file => { try { return inventory.check(file); } catch { return undefined; } };
  host.readFile = file => { const key = permitted(file); return key && inventory.read(key)?.toString('utf8'); };
  host.fileExists = file => { const key = permitted(file); return !!key && inventory.has(key); };
  host.directoryExists = dir => inventory.directory(dir);
  host.realpath = file => { const key = permitted(file); return key && (inventory.has(key) || inventory.directory(key)) ? key : file; };
  host.getDirectories = dir => {
    const key = path.resolve(dir); if (!inventory.directory(key)) return [];
    return [...inventory.directories].filter(value => path.dirname(value) === key);
  };
  host.readDirectory = (dir, extensions, excludes, includes, depth) => {
    const key = path.resolve(dir); if (!inventory.directory(key)) return [];
    return ts.matchFiles(key, extensions, excludes, includes, true, source, depth,
      directory => ({ files: [...inventory.files.keys()].filter(file => path.dirname(file) === directory).map(file => path.basename(file)), directories: host.getDirectories(directory).map(file => path.basename(file)) }), host.realpath);
  };
  // createCompilerHost's default getSourceFile closes over ts.sys.readFile.
  host.getSourceFile = (file, languageVersion) => {
    const text = host.readFile(file);
    return text === undefined ? undefined : ts.createSourceFile(file, text, languageVersion);
  };
  host.getCurrentDirectory = () => source;
  host.writeFile = () => { throw Error('Compiler emission is disabled'); };
  const program = ts.createProgram(files.filter(f => /\.[cm]?[jt]sx?$/.test(f)), options, host);
  for(const file of program.getSourceFiles().filter(f=>f.fileName.startsWith(source+path.sep))) {
    const visit=node=>{
      if(ts.isCallExpression(node) && node.expression.kind===ts.SyntaxKind.ImportKeyword && (!node.arguments[0] || !ts.isStringLiteral(node.arguments[0]))) throw Error('Dynamic imports must use a literal package-local path');
      ts.forEachChild(node,visit);
    };
    visit(file);
  }
  const diagnostics = ts.getPreEmitDiagnostics(program);
  if (diagnostics.length) throw Error(ts.formatDiagnostics(diagnostics.slice(0, 20), { getCanonicalFileName: f => f, getCurrentDirectory: () => source, getNewLine: () => '\n' }).slice(0, 16000));

await sendPacket({type:'result',audit:{elapsedMs:performance.now()-start,cpu:process.cpuUsage(cpu),maxRSSKiB:process.resourceUsage().maxRSS,...inventory.audit()}});
if(process.connected)process.disconnect();
}catch(error){await failWorker(error);}
