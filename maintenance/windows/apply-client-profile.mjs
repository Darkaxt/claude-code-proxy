// Keep the large prompt-ID selection in-process; Windows has a short argv limit.
// This runs the published community CLI unchanged, against an isolated candidate.
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';

const release = path.resolve(process.argv[2] ?? '');
const manifest = JSON.parse(await fs.readFile(path.join(release, 'candidate.json'), 'utf8'));
if (manifest.schema !== 'claudegpt.client_candidate.v1') throw new Error('Invalid candidate');
process.env.TWEAKCC_CONFIG_DIR = manifest.profile;
process.env.TWEAKCC_CC_INSTALLATION_PATH = manifest.candidateBinary;
process.env.DISABLE_AUTOUPDATER = '1';
const files = await fs.readdir(path.join(manifest.profile, 'system-prompts'));
const review = JSON.parse(await fs.readFile(path.join(release,'preflight-review.json'),'utf8'));
if (review.total !== review.allFindings.length || review.kinds['raw-non-ascii'] || review.kinds['backtick-escape']) {
  throw new Error('Unreviewed encoding/escaping finding; do not apply');
}
// No unique native Windows site means no replacement can be certified there.
// Keep the source intact and select only uniquely addressable catalogue IDs.
const excludedIds = new Set(review.allFindings.filter(f=>f.kind==='cardinality').map(f=>f.id));
const legacy = ['inline-loop-tick-absent.md','inline-loop-tick-tasks.md'];
const exclusions = path.join(release,'profile-exclusions');
await fs.mkdir(exclusions,{recursive:true});
for (const name of legacy) {
  const source=path.join(manifest.profile,'system-prompts',name);
  let text;
  try { text=await fs.readFile(source,'utf8'); }
  catch(e) { if(e.code!=='ENOENT')throw e; text=await fs.readFile(path.join(exclusions,name),'utf8'); }
  if(!text.includes('ccVersion: \'2.1.138\'') || !text.includes('${dY}')) {
    throw new Error(`Legacy override changed; review before excluding ${name}`);
  }
  try { await fs.rename(source,path.join(exclusions,name)); } catch(e) {if(e.code!=='ENOENT')throw e;}
}
async function findCatalog(dir) {
  for(const f of await fs.readdir(dir,{withFileTypes:true})) {
    const p=path.join(dir,f.name);
    if(f.isDirectory()) {const found=await findCatalog(p);if(found)return found;}
    else if(f.name===`prompts-${manifest.version}.json`) return p;
  }
}
const catalog=JSON.parse(await fs.readFile(await findCatalog(path.join(manifest.profile,'prompt-data-cache')),'utf8'));
const present=new Set(files.filter(n=>n.endsWith('.md')).map(n=>n.slice(0,-3)));
const require=createRequire(path.join(release,'runtime/package.json'));
const matter=require('gray-matter');
// These two reminder owners declare their shadows in the patcher's registry.
// Other owners declare them in Markdown frontmatter below.
const shadowedIds=new Set([
  'system-reminder-mid-turn-user-message-surfacing',
  'system-reminder-background-task-event-not-user-input',
]);
for(const folder of ['system-prompts','system-reminders']) {
  const dir=path.join(manifest.profile,folder);
  const names=(await fs.readdir(dir)).filter(n=>n.endsWith('.md'));
  for(let i=0;i<names.length;i+=32) {
    await Promise.all(names.slice(i,i+32).map(async name=>{
      const {data}=matter(await fs.readFile(path.join(dir,name),'utf8'),{delimiters:['<!--','-->']});
      if(Array.isArray(data.shadows)) for(const id of data.shadows)shadowedIds.add(id);
    }));
  }
}
const ids=[...new Set(catalog.prompts.map(p=>p.id))].filter(id=>present.has(id)&&!excludedIds.has(id)&&!shadowedIds.has(id));
await fs.writeFile(path.join(release,'profile-adaptation.json'),JSON.stringify({
  excludedCatalogueIds:[...excludedIds],
  shadowedCatalogueIds:[...shadowedIds],
  excludedLegacyFiles:legacy,
  reason:'Windows sites must be uniquely addressable. Legacy inline loop prompts contain stale minified bindings and shadow current named loop prompts; use the canonical variable-mapped overrides.'
},null,2));
ids.push('fix-summarize-from-here', 'fix-rewind-summary-header',
  'strip-empty-system-reminders', 'read-default-lines');
await fs.writeFile(path.join(release, 'selected-patches.json'), JSON.stringify(ids, null, 2));
process.argv = [process.execPath, manifest.tool, '--apply', '--patches', ids.join(',')];
await import(pathToFileURL(manifest.tool).href);
