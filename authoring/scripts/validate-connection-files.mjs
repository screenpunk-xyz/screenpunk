import {validateConnectionDeclarations} from './connection-declarations.mjs';
/** A closed in-memory host: no ts.sys, file imports, or package execution. */
export function validateConnectionFiles(ts, files, config) {
  const source = new Map(files.filter(f => /\.[cm]?[jt]sx?$/i.test(f.path)).map(f => ['/' + f.path, f.text]));
  const options = {noLib:true, noResolve:true, allowJs:true, target:ts.ScriptTarget.Latest, jsx:ts.JsxEmit.Preserve};
  const host = {
    getSourceFile:(p,v)=>source.has(p)?ts.createSourceFile(p,source.get(p),v,true):undefined,
    getDefaultLibFileName:()=>'', writeFile:()=>{}, getCurrentDirectory:()=>'/','getDirectories':()=>[],
    fileExists:p=>source.has(p), readFile:p=>source.get(p), getCanonicalFileName:p=>p,
    useCaseSensitiveFileNames:()=>true, getNewLine:()=>'\n'
  };
  const program=ts.createProgram([...source.keys()],options,host);
  validateConnectionDeclarations(ts,program,program.getSourceFiles(),config);
}
