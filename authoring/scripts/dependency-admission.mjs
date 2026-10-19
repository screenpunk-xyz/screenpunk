import path from 'node:path';

export function isProjectScript(file) { return /\.(?:tsx?|jsx?)$/i.test(file); }

// V1 project code uses ES module imports. Ambient module-loader and code-generation
// objects are outside that syntax policy, including computed aliases of their properties.
const unsupportedAmbientIdentifiers = new Set([
  'require', 'module', 'exports', 'global', 'globalThis', 'window', 'self',
  'process', 'eval', 'Function',
]);

/** Run on every admitted project script, including files esbuild loads after the TS program. */
export function inspectProjectScript(ts, file, contents) {
  if (!isProjectScript(file)) return;
  const extension = path.extname(file).toLowerCase();
  const kind = extension === '.tsx' ? ts.ScriptKind.TSX : extension === '.jsx' ? ts.ScriptKind.JSX :
    extension === '.js' ? ts.ScriptKind.JS : ts.ScriptKind.TS;
  const syntax = ts.createSourceFile(file, contents, ts.ScriptTarget.ES2022, true, kind);
  if (syntax.parseDiagnostics.length) throw Error(`Unparseable project script: ${file}`);
  const inspect = node => {
    if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword &&
        (node.arguments.length !== 1 || !ts.isStringLiteral(node.arguments[0]))) {
      throw Error(`Dynamic imports must use a literal path: ${file}`);
    }
    // This intentionally rejects ambient-capability references rather than trying to
    // evaluate every computed spelling of "require". Ordinary local indexing remains valid.
    if (ts.isIdentifier(node) && unsupportedAmbientIdentifiers.has(node.text)) {
      throw Error(`Ambient module-loader or code-generation access is unsupported in project scripts: ${file}`);
    }
    ts.forEachChild(node, inspect);
  };
  inspect(syntax);
}

export function rejectBuildWarnings(warnings) {
  if (warnings.length) {
    throw Error(`Compiler emitted unresolved or unsupported dependency warnings: ${warnings.map(w => w.text).join('; ')}`);
  }
}
