// Use the published CLI's explicit pristine-JS input. Its implicit startup path
// resynchronizes missing stock stubs before validation, undoing exclusions.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { excludePristineLiterals } from './exclude-client-pristine-literals.mjs';
const [releaseArg,scratchArg]=process.argv.slice(2);
if(!releaseArg||!scratchArg)throw Error('Supply candidate release and exact scratch');
const release=path.resolve(releaseArg),scratch=path.resolve(scratchArg);
const m=JSON.parse(await fs.readFile(path.join(release,'candidate.json'),'utf8'));
if(m.schema!=='claudegpt.client_candidate.v1')throw Error('Invalid candidate');
process.env.TWEAKCC_CONFIG_DIR=m.profile;
process.env.TWEAKCC_CC_INSTALLATION_PATH=m.candidateBinary;
process.env.DISABLE_AUTOUPDATER='1';
process.env.TEMP=scratch;process.env.TMP=scratch;
await excludePristineLiterals(release);
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
let native=path.join(m.profile,'native-binary.backup');
try{await fs.access(native);}catch(e){if(e.code!=='ENOENT')throw e;native=m.candidateBinary;}
if(hash(await fs.readFile(native))!==m.vendorSha256)throw Error('Preflight requires the hash-bound pristine vendor binary');
const {readContent}=await import(pathToFileURL(path.join(release,'runtime/node_modules/tweakcc-fixed/dist/lib/index.mjs')).href);
const {content}=await readContent({path:native,version:m.version,kind:'native'});
await fs.mkdir(scratch,{recursive:true});
const pristine=path.join(scratch,`pristine-preflight-${m.version}.js`);
await fs.writeFile(pristine,content);
await fs.writeFile(path.join(release,'preflight-pristine.json'),JSON.stringify({version:m.version,nativeInputSha256:m.vendorSha256,pristineJsSha256:hash(content),temporaryPristineJs:pristine,communityCliUnchanged:true},null,2));
process.argv=[process.execPath,m.tool,'--validate-system-prompts',pristine];
await import(pathToFileURL(m.tool).href);
