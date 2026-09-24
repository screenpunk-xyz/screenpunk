import fs from 'node:fs/promises';
import path from 'node:path';
export async function notices(inputs) {
  const roots = new Set();
  for (const input of inputs) {
    const marker = input.lastIndexOf('/node_modules/');
    if(marker < 0) continue;
    const tail=input.slice(marker+14).split('/');
    roots.add(input.slice(0,marker+14)+tail.slice(0,tail[0].startsWith('@')?2:1).join('/'));
  }
  const sections = [];
  for (const root of [...roots].sort()) {
    const pkg=JSON.parse(await fs.readFile(path.join(root,'package.json'),'utf8'));
    const licenses=(await fs.readdir(root)).filter(n=>/^(licen[cs]e|notice|copying)/i.test(n));
    if(!licenses.length) {
      const supplemental=new URL(`../licenses/${pkg.name.replaceAll('/','__')}.txt`,import.meta.url);
      sections.push(`${pkg.name}@${pkg.version} (${pkg.license})\n${await fs.readFile(supplemental,'utf8')}`);
      if(pkg.name === 'victory-vendor') {
        for(const name of await fs.readdir(path.join(root,'lib-vendor'))) {
          try { sections.push(`${name} (vendored)\n${await fs.readFile(path.join(root,'lib-vendor',name,'LICENSE'),'utf8')}`); } catch {}
        }
      }
      continue;
    }
    const texts=await Promise.all(licenses.map(n=>fs.readFile(path.join(root,n),'utf8')));
    sections.push(`${pkg.name}@${pkg.version} (${pkg.license})\n${texts.join('\n')}`);
  }
  // Editable controls retain the upstream shadcn notice even after bundling.
  sections.push(await fs.readFile(new URL('../ui/NOTICE.txt',import.meta.url),'utf8'));
  return sections.join('\n\n----------------------------------------\n\n');
}
