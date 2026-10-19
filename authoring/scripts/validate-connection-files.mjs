import {validateConnectionDeclarations} from './connection-declarations.mjs';
/** A closed in-memory host: no ts.sys, file imports, or package execution. */
export function validateConnectionFiles(ts, files, config) {
  const source = new Map(files.filter(f => /\.[cm]?[jt]sx?$/i.test(f.path)).map(f => ['/' + f.path, f.text]));
  const options = {noLib:true, noResolve:true, allowJs:true, allowNonTsExtensions:true, target:ts.ScriptTarget.Latest, jsx:ts.JsxEmit.Preserve};
  const scriptKind = p => /\.tsx$/i.test(p) ? ts.ScriptKind.TSX : /\.jsx$/i.test(p) ? ts.ScriptKind.JSX : /\.[cm]?ts$/i.test(p) ? ts.ScriptKind.TS : ts.ScriptKind.JS;
  const host = {
    getSourceFile:(p,v)=>source.has(p)?ts.createSourceFile(p,source.get(p),v,true,scriptKind(p)):undefined,
    getDefaultLibFileName:()=>'', writeFile:()=>{}, getCurrentDirectory:()=>'/','getDirectories':()=>[],
    fileExists:p=>source.has(p), readFile:p=>source.get(p), getCanonicalFileName:p=>p,
    useCaseSensitiveFileNames:()=>true, getNewLine:()=>'\n'
  };
  const program=ts.createProgram([...source.keys()],options,host);
  // TypeScript can omit unsupported root extensions without throwing. Every
  // selected executable member must actually reach the AST checker.
  for (const path of source.keys()) {
    if (!program.getSourceFile(path)) throw Error('Connection validation could not parse an executable package member.');
  }
  validateConnectionDeclarations(ts,program,program.getSourceFiles(),config);
}
