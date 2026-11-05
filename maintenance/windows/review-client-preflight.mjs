// Classify every community finding; retain all findings, including unresolved ones.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
const release = path.resolve(process.argv[2]);
const profile = path.join(release,'profile');
const candidate=JSON.parse(await fs.readFile(path.join(release,'candidate.json'),'utf8'));
async function jsonFiles(dir) {
  const out=[];
  for(const f of await fs.readdir(dir,{withFileTypes:true})) {
    if(f.isDirectory()) out.push(...await jsonFiles(path.join(dir,f.name)));
    else if(f.name===`prompts-${candidate.version}.json`) out.push(path.join(dir,f.name));
  }
  return out;
}
const [catalogPath] = await jsonFiles(path.join(profile,'prompt-data-cache'));
const catalog=JSON.parse(await fs.readFile(catalogPath,'utf8'));
const hashes=JSON.parse(await fs.readFile(path.join(profile,'systemPromptOriginalHashes.json'),'utf8'));
const byId=new Map();
for(const p of catalog.prompts) {
  const original=p.pieces.map((piece,i)=>piece+(i<p.identifiers.length?(p.identifierMap?.[p.identifiers[i]]??p.identifiers[i]):'')).join('').trim();
  const values=byId.get(p.id)??[]; values.push(original); byId.set(p.id,values);
}
const log=await fs.readFile(path.join(release,'prompt-preflight.log'),'utf8');
const completion=log.match(/(\d+) finding\(s\): (\d+) error\(s\), (\d+) warning\(s\), (\d+) info\./);
const clean=/^0 findings\.$/m.test(log);
if (!completion && !clean) throw Error('Community preflight did not finish; inspect its original error instead of treating zero parsed findings as success');
const findings=[];
for(const line of log.split(/\r?\n/)) {
  const match=line.match(/^\[(cardinality|ownership|backtick-escape|raw-non-ascii)\] (\S+) \(site/);
  if(!match) continue;
  const [,kind,id]=match;
  let body=null;
  try {body=(await fs.readFile(path.join(profile,'system-prompts',id+'.md'),'utf8')).replace(/^<!--[^]*?-->\s*/,'').trim();} catch(e) {if(e.code!=='ENOENT')throw e;}
  // The community sync index uses MD5 for change detection, not authenticity.
  const digest=body===null?null:crypto.createHash('md5').update(body).digest('hex');
  const expectedHashes=catalog.prompts.filter(p=>p.id===id).map(p=>hashes[`${id}-${p.version}`]);
  const unchanged=body!==null && ((byId.get(id)??[]).includes(body)||expectedHashes.includes(digest));
  findings.push({kind,id,unchanged,bodyEmpty:body==='',line});
}
const changed=findings.filter(f=>!f.unchanged);
if (Number(completion?.[1] ?? 0) !== findings.length) throw Error('Unparsed community findings; review the changed format before applying');
const report={total:findings.length,unchanged:findings.filter(f=>f.unchanged).length,
  kinds:Object.fromEntries([...new Set(findings.map(f=>f.kind))].map(k=>[k,findings.filter(f=>f.kind===k).length])),
  changedOrUnresolved:changed,allFindings:findings};
await fs.writeFile(path.join(release,'preflight-review.json'),JSON.stringify(report,null,2));
console.log(JSON.stringify({...report,allFindings:undefined,changedOrUnresolved:changed.map(({line,...f})=>f)},null,2));
