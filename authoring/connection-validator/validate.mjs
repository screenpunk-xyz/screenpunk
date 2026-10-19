import {parse} from 'parse5';

// Never execute screen code. Parse HTML using the HTML5 tokenizer/tree builder;
// preserve original offsets by blanking markup before each inline script.
export function validatePackage(ts, files, connections, validateConnectionFiles) {
  if (!Array.isArray(files) || files.length>2000 || !Array.isArray(connections)) throw Error('Invalid package validation input.');
  const sources=[]; const allocated=new Set(files.map(f=>f.path)); let total=0, extracted=0, scriptCount=0;
  for(const f of files) {
    if(typeof f.path!=='string'||f.path.length>512||typeof f.text!=='string') throw Error('Invalid package validation member.');
    total+=Buffer.byteLength(f.text);if(total>5*1024*1024)throw Error('Connection validation supports at most 5 MiB of executable JavaScript and HTML.');
    if(/\.[cm]?[jt]sx?$/i.test(f.path)){sources.push(f);continue;}
    if(!/\.html?$/i.test(f.path))continue;
    const document=parse(f.text,{sourceCodeLocationInfo:true});
    const stack=[document];let scripts=0;
    while(stack.length){const n=stack.pop();
      if(n.tagName==='script'){
        const attrs=Object.fromEntries((n.attrs??[]).map(a=>[a.name,a.value]));
        const type=(attrs.type??'').trim().toLowerCase();
        const executable=!type||type==='module'||/^(?:text|application)\/(?:java|ecma)script$/.test(type);
        const loc=n.sourceCodeLocation;
        if(executable&&!Object.hasOwn(attrs,'src')&&loc?.startTag){
          const start=loc.startTag.endOffset,end=loc.endTag?.startOffset??f.text.length;
          scripts++;if(++scriptCount>512)throw Error('Too many inline scripts for connection validation.');
          // A synthetic JS suffix selects the JS parser without losing HTML location.
          extracted+=end;if(extracted>10*1024*1024)throw Error("Inline script analysis exceeds 10 MiB including location padding.");
          let synthetic=f.path+'.inline-'+scripts+'.js';
          while(allocated.has(synthetic))synthetic+='_.js';
          allocated.add(synthetic);
          sources.push({path:synthetic,text:f.text.slice(0,start).replace(/[^\r\n]/g,' ')+f.text.slice(start,end)});
        }
      }
      // Template content is inert until instantiated, but scanning script bodies is
      // conservative. No event attributes or javascript: URLs are evaluated here.
      if(n.content)stack.push(n.content);
      if(n.childNodes)for(const child of n.childNodes)stack.push(child);
    }
  }
  validateConnectionFiles(ts,sources,{connections});
}
