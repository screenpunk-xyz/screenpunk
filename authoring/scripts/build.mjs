import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import ts from 'typescript';
import { notices } from './notices.mjs';
export const kitRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
async function compileProject(source, output) {
  source = await fs.realpath(source); output = path.resolve(output);
  if (output === source || source.startsWith(output + path.sep)) throw Error('Output must not contain project source');
  const files = [];
  async function walk(dir) {
    for (const item of await fs.readdir(dir, { withFileTypes: true })) {
      const p = path.join(dir, item.name);
      if (item.isSymbolicLink()) throw Error('Source symlinks are not allowed');
      if (item.isDirectory()) { if (item.name !== 'node_modules' && item.name !== 'dist') await walk(p); }
      else if (/\.(tsx?|css|json|svg|png|jpe?g|woff2?)$/.test(p)) files.push(p);
    }
  }
  await walk(source);
  if (files.length > 2000) throw Error('Too many source files');
  const options = { strict: true, noEmit: true, skipLibCheck: true, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler, jsx: ts.JsxEmit.ReactJSX, esModuleInterop: true, resolveJsonModule: true,
    baseUrl: kitRoot, paths: { '@screenpunk/react': ['react/index.tsx'], '@screenpunk/ui': ['ui/index.tsx'], 'react': ['node_modules/@types/react/index.d.ts'], 'react/*': ['node_modules/@types/react/*'], 'react-dom/*': ['node_modules/@types/react-dom/*'], '*': ['node_modules/*'] }, typeRoots: [path.join(kitRoot, 'node_modules/@types')], types: ['react','react-dom'], lib: ['lib.es2022.d.ts','lib.dom.d.ts','lib.dom.iterable.d.ts'] };
  const program = ts.createProgram(files.filter(f => /\.tsx?$/.test(f)), options);
  for(const file of program.getSourceFiles().filter(f=>f.fileName.startsWith(source+path.sep))) {
    const visit=node=>{
      if(ts.isCallExpression(node) && node.expression.kind===ts.SyntaxKind.ImportKeyword && (!node.arguments[0] || !ts.isStringLiteral(node.arguments[0]))) throw Error('Dynamic imports must use a literal package-local path');
      ts.forEachChild(node,visit);
    };
    visit(file);
  }
  const diagnostics = ts.getPreEmitDiagnostics(program);
  if (diagnostics.length) throw Error(ts.formatDiagnosticsWithColorAndContext(diagnostics, { getCanonicalFileName: f => f, getCurrentDirectory: () => source, getNewLine: () => '\n' }));
  await fs.mkdir(output, { recursive: true });
  const result = await build({ absWorkingDir: kitRoot, entryPoints: [path.join(source,'src/main.tsx')], bundle: true, outfile: path.join(output,'screen.js'), format: 'iife', platform: 'browser', target: ['safari16','ios16'], jsx: 'automatic', minify: true, metafile: true, sourcemap: false, legalComments: 'none', define: { 'process.env.NODE_ENV': '"production"' }, assetNames: 'assets/[hash]', loader: { '.svg':'file','.png':'file','.jpg':'file','.jpeg':'file','.woff':'file','.woff2':'file' }, nodePaths: [path.join(kitRoot,'node_modules')], alias: { '@screenpunk/react': path.join(kitRoot,'react/index.tsx'), '@screenpunk/ui': path.join(kitRoot,'ui/index.tsx') }, plugins: [{ name:'screenpunk-local-only', setup(b) {
    b.onResolve({filter:/^react-remove-scroll-bar$/},()=>({path:path.join(kitRoot,'ui/scrollbar.tsx')}));
    b.onLoad({filter:/@radix-ui\/react-select\/dist\/index\.mjs$/},async args=>{
      const text=await fs.readFile(args.path,'utf8');
      const pattern=/jsx\(\s*"style",\s*\{\s*dangerouslySetInnerHTML:[\s\S]*?nonce\s*\}\s*\)/;
      if(!pattern.test(text))throw Error('Pinned Radix Select stylesheet changed; review the static CSS adapter');
      return {contents:text.replace(pattern,'null'),loader:'js'};
    });
    b.onResolve({ filter: /.*/ }, args => {
      if (/^(https?:|data:|node:|\/\/)/.test(args.path)) return { errors:[{ text:'Only packaged browser dependencies and local assets are supported' }] };
      if (args.path.startsWith('.') || path.isAbsolute(args.path)) {
        const resolved = path.resolve(args.resolveDir || kitRoot,args.path);
        if (![source,kitRoot].some(root => resolved.startsWith(root + path.sep))) return { errors:[{ text:'Import escapes the project or authoring kit' }] };
      }
    });
  }}] });
  try { await fs.access(path.join(output,'screen.css')); } catch { await fs.writeFile(path.join(output,'screen.css'),''); }
  await fs.writeFile(path.join(output,'index.html'), '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="screen.css"><title>Screenpunk</title></head><body><div id="root"></div><script src="screen.js"></script></body></html>');
  const inputs = [...new Set(Object.values(result.metafile.outputs).flatMap(o => Object.entries(o.inputs).filter(([,v]) => v.bytesInOutput > 0).map(([f]) => path.resolve(kitRoot,f))))];
  await fs.writeFile(path.join(output,'THIRD-PARTY-NOTICES.txt'), await notices(inputs));
  let bytes = 0; const assets = [];
  async function inventory(dir) { for (const item of await fs.readdir(dir,{withFileTypes:true})) { const p=path.join(dir,item.name); if(item.isDirectory()) await inventory(p); else { const size=(await fs.stat(p)).size; bytes+=size; assets.push({path:path.relative(output,p),bytes:size}); } } }
  await inventory(output);
  if (assets.length > 2000 || bytes > 50*1024*1024) throw Error('Screenpunk package limits exceeded');
  return { bytes, files:assets, dependencies:inputs.filter(f=>f.includes('/node_modules/')).length };
}
export async function buildProject(source, output) {
  source=await fs.realpath(source);output=path.resolve(output);
  if(output===path.parse(output).root || output===source || source.startsWith(output+path.sep) || output===kitRoot || kitRoot.startsWith(output+path.sep) || (output.startsWith(source+path.sep) && !output.startsWith(path.join(source,'dist')+path.sep) && output!==path.join(source,'dist'))) throw Error('Unsafe output directory');
  await fs.mkdir(path.dirname(output),{recursive:true});
  const stage=await fs.mkdtemp(path.join(path.dirname(output),'.screenpunk-build-'));
  try {
    const result=await compileProject(source,stage);
    const backup=output+'.previous-'+process.pid;
    let replaced=false;
    try { await fs.rename(output,backup);replaced=true; } catch(e) {if(e.code!=='ENOENT')throw e;}
    try {await fs.rename(stage,output);} catch(e){if(replaced)await fs.rename(backup,output);throw e;}
    if(replaced)await fs.rm(backup,{recursive:true,force:true});
    return result;
  } finally {await fs.rm(stage,{recursive:true,force:true});}
}
if (process.argv[1] && await fs.realpath(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(await buildProject(process.argv[2],process.argv[3]))); }
  catch(error) { console.error(error.message); process.exitCode=1; }
}
