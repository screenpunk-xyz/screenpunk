import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {buildProject,kitRoot} from './build.mjs';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import {Activity,ChartLine,Globe,RefreshCw,Layers,Search,Sun,Moon} from 'lucide-react';
const catalog=JSON.parse(await fs.readFile(path.join(kitRoot,'catalog.json'),'utf8'));
const tmp=await fs.mkdtemp(path.join(os.tmpdir(),'sp-catalog-'));
try {
 await fs.mkdir(path.join(tmp,'source/src'),{recursive:true});
 for(const entry of catalog.entries){
  await fs.writeFile(path.join(tmp,'source/src/main.tsx'),`import {${entry.exports.join(',')}} from '@screenpunk/ui';console.log(${entry.exports.join(',')});`);
  const result=await buildProject(path.join(tmp,'source'),path.join(tmp,'output'));
  entry.expectedSizeBytes=result.bytes;
  entry.sizeMethod='Standalone production import including React, emitted CSS and dependency notices; not additive across modules.';
 }
}finally{await fs.rm(tmp,{recursive:true,force:true});}
await fs.mkdir(path.join(kitRoot,'icons'),{recursive:true});
catalog.icons=[];
for(const [name,icon] of Object.entries({Activity,ChartLine,Globe,RefreshCw,Layers,Search,Sun,Moon})){
 const file=name.replace(/[A-Z]/g,(c,i)=>(i?'-':'')+c.toLowerCase())+'.svg';
 await fs.writeFile(path.join(kitRoot,'icons',file),renderToStaticMarkup(React.createElement(icon,{'aria-hidden':true})));
 catalog.icons.push({name,keywords:name.replace(/[A-Z]/g,c=>' '+c.toLowerCase()).trim().split(' '),reactImport:name,svg:'icons/'+file,license:'ISC; see icons/LICENSE.txt'});
}
await fs.copyFile(path.join(kitRoot,'node_modules/lucide-react/LICENSE'),path.join(kitRoot,'icons/LICENSE.txt'));
await fs.writeFile(path.join(kitRoot,'catalog.json'),JSON.stringify(catalog,null,2)+'\n');
