/** Authoring lint, not a runtime permission or proof of arbitrary JS behavior.
 * Takes the caller's captured TypeScript program; never reads the filesystem. */
export function validateConnectionDeclarations(ts, program, sourceFiles, config) {
  if (!Array.isArray(config?.connections)) throw Error('screen.json: connections must be an explicit array; preserve existing declarations when editing.');
  const declared = new Map(config.connections.map(c => [c.alias, c]));
  const checker = program.getTypeChecker();
  const unwrap = n => {
    while (n && (ts.isParenthesizedExpression(n) || ts.isAsExpression(n) || ts.isTypeAssertionExpression(n) || ts.isNonNullExpression(n))) n = n.expression;
    return n;
  };
  const literal = n => { n = unwrap(n); return n && (ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)) ? n.text : undefined; };
  const member = n => ts.isPropertyAccessExpression(n) ? n.name.text : ts.isElementAccessExpression(n) ? literal(n.argumentExpression) : undefined;
  // Follow only immutable local aliases and exact supported imports. A local
  // object named screenpunk or window is not the injected host client.
  function origin(node, seen = new Set()) {
    const n = unwrap(node); if (!n || seen.has(n) || seen.size > 24) return;
    seen = new Set(seen).add(n);
    if (ts.isIdentifier(n)) {
      const symbol = checker.getSymbolAtLocation(n);
      const declarations = symbol?.declarations ?? [];
      const local = declarations.filter(d => !d.getSourceFile().isDeclarationFile);
      if (!local.length && ['screenpunk', 'window', 'globalThis'].includes(n.text)) return n.text === 'screenpunk' ? 'client' : 'global';
      if (local.length !== 1) return;
      const d = local[0];
      if (ts.isVariableDeclaration(d) && ts.isIdentifier(d.name) && (d.parent.flags & ts.NodeFlags.Const) && d.initializer) return origin(d.initializer, seen);
      if (ts.isImportSpecifier(d)) {
        const imp = d.parent.parent.parent;
        if (ts.isImportDeclaration(imp) && literal(imp.moduleSpecifier) === '@screenpunk/react') {
          const name = (d.propertyName ?? d.name).text;
          if (['useScreenpunk','usePublicRead','useConnectionSubscription'].includes(name)) return name;
        }
      }
      return;
    }
    if (ts.isCallExpression(n) && origin(n.expression, seen) === 'useScreenpunk') return 'client';
    if (ts.isPropertyAccessExpression(n) || ts.isElementAccessExpression(n)) {
      const base = origin(n.expression, seen), name = member(n);
      if (base === 'global' && name === 'screenpunk') return 'client';
      if (base === 'client' && ['connections','homeAssistant','cameras'].includes(name)) return name;
      if (base === 'connections' && ['request','read','subscribe'].includes(name)) return 'connectionCall';
      if (base === 'homeAssistant' && name === 'callService') return 'homeCall';
      if (base === 'cameras' && name === 'mount') return 'cameraCall';
    }
  }
  for (const file of sourceFiles) {
    function visit(node) {
      if (ts.isCallExpression(node)) {
        const kind = origin(node.expression);
        const alias = ['connectionCall','usePublicRead','useConnectionSubscription'].includes(kind) ? literal(node.arguments[0]) : ['homeCall','cameraCall'].includes(kind) ? 'home' : undefined;
        if (alias !== undefined && !declared.has(alias)) {
          const p = file.getLineAndCharacterOfPosition(node.getStart(file));
          throw Error(`${file.fileName}:${p.line + 1}:${p.character + 1}: missing connection declaration for "${alias}". Add {"alias":${JSON.stringify(alias)},"required":false} to screen.json connections (or required:true if the entire screen needs setup), retain provider-specific operation/service/camera declarations, and rebuild. Native Settings discovers providers from the manifest; API calls and saved device settings do not declare them.`);
        }
      }
      ts.forEachChild(node, visit);
    }
    visit(file);
  }
}
