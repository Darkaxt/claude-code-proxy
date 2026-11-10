import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import { excludePristineLiterals } from './exclude-client-pristine-literals.mjs';
const scratch=process.argv[2];if(!scratch)throw Error('Supply exact task scratch');
const root=await fs.mkdtemp(path.join(scratch,'literal-fixture-'));
const profile=path.join(root,'profile');
const source=path.join(root,'prompt-source/system-prompts-lcc');
await fs.mkdir(path.join(profile,'system-prompts'),{recursive:true});
await fs.mkdir(path.join(profile,'prompt-data-cache/v0.0.0'),{recursive:true});
await fs.mkdir(source,{recursive:true});
await fs.writeFile(path.join(root,'candidate.json'),JSON.stringify({schema:'claudegpt.client_candidate.v1',profile,version:'0.0.0',tweakVersion:'0.0.0'}));
const literal='A literal `${` starts interpolation.';
const balanced='Keep the literal shell ${VAR} text.';
const edited='A community customization containing ${VAR}.';
const original='Original stock ${ENV} text.';
for(const [id,text] of [['literal',literal],['balanced',balanced],['edited',edited]]){
 const file=`<!--\nname: ${id}\n-->\n\n${text}\n`;
 await fs.writeFile(path.join(source,`${id}.md`),file);
 await fs.writeFile(path.join(profile,'system-prompts',`${id}.md`),file);
}
await fs.writeFile(path.join(profile,'prompt-data-cache/v0.0.0/prompts-0.0.0.json'),JSON.stringify({prompts:[{id:'literal',identifiers:[],pieces:[literal]},{id:'balanced',identifiers:[],pieces:[balanced+'\n\n']},{id:'edited',identifiers:[],pieces:[original]}]}));
const result=await excludePristineLiterals(root);
assert.deepEqual(result.excluded.map(x=>x.id),['literal','balanced']);
for(const item of result.excluded){assert.equal(await fs.readFile(item.retained,'utf8'),await fs.readFile(path.join(source,`${item.id}.md`),'utf8'));assert.equal(await fs.stat(path.join(profile,'system-prompts',`${item.id}.md`)).then(()=>true,()=>false),false);}
assert.ok((await fs.readFile(path.join(profile,'system-prompts/edited.md'),'utf8')).includes(edited));
assert.deepEqual(await excludePristineLiterals(root),result);
const regenerated=(await fs.readFile(path.join(source,'literal.md'),'utf8')).replace('-->\n\n','-->\n');
await fs.writeFile(path.join(profile,'system-prompts/literal.md'),regenerated);
const resynced=await excludePristineLiterals(root);
assert.equal(await fs.readFile(resynced.excluded[0].retained,'utf8'),regenerated);
assert.deepEqual(await excludePristineLiterals(root),resynced);
// The published implicit startup path regenerates pristine missing stubs.
await fs.copyFile(path.join(source,'literal.md'),path.join(profile,'system-prompts/literal.md'));
assert.deepEqual(await excludePristineLiterals(root),result);
const changed=literal+' Owner edit.';
await fs.writeFile(path.join(profile,'system-prompts/literal.md'),changed);
await assert.rejects(excludePristineLiterals(root),/local edits/);
assert.equal(await fs.readFile(path.join(profile,'system-prompts/literal.md'),'utf8'),changed);
console.log(JSON.stringify({passed:true,stockLiteralsRetainedOutsideProfile:true,customOverrideUnchanged:true,localEditsPreserved:true,idempotent:true,fixture:root}));
