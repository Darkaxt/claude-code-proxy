// Read back the patched native payload using the community library.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { body, digest, overrideForCommunity } from './adapt-client-authorization.mjs';

const release = path.resolve(process.argv[2]);
const m = JSON.parse(await fs.readFile(path.join(release, 'candidate.json'), 'utf8'));
process.env.TWEAKCC_CONFIG_DIR = m.profile;
const libPath = path.join(release, 'runtime/node_modules/tweakcc-fixed/dist/lib/index.mjs');
const { readContent } = await import(pathToFileURL(libPath).href);
const { content, clearBytecode } = await readContent({ path:m.candidateBinary, version:m.version, kind:'native' });
const original = await fs.readFile(path.join(m.profile, 'native-claudejs-orig.js'), 'utf8');
const intended = await fs.readFile(path.join(m.profile, 'native-claudejs-patched.js'), 'utf8');
const adaptation = JSON.parse(await fs.readFile(path.join(release, 'authorization-adaptation.json'), 'utf8'));
const authorization = body(await fs.readFile(overrideForCommunity(adaptation.communitySha256).url, 'utf8'));
const literals = JSON.parse(await fs.readFile(path.join(release, 'literal-profile-exclusions.json'), 'utf8'));
const selected = new Set(JSON.parse(await fs.readFile(path.join(release, 'selected-patches.json'), 'utf8')));
const checks = {
  payloadChanged: content !== original,
  matchesExactCommunityPatchedPayload: content === intended,
  staleBytecodeAbsent: !clearBytecode,
  defaultReadConfigurable: content.includes('process.env.CLAUDE_CODE_READ_DEFAULT_LINES'),
  honestRewindHeader: content.includes('This session was rewound') || content.includes('This summary comes from a rewind'),
  rewindCanonicalHeaderPreserved: ['2.9.22','2.9.23','2.9.24'].includes(m.tweakVersion) ||
    (content.includes('This summary comes from a rewind') &&
     !content.includes('.replace(/This session is being continued')),
  emptyReminderHandling: content.includes('trim()') && content.includes('(no content)'),
  durableAuthorizationPresent: adaptation.adaptedBodySha256 === digest(authorization) &&
    (content.includes(authorization) || content.includes(JSON.stringify(authorization).slice(1, -1))),
  staleSharedStateReconfirmationAbsent: !content.includes('If the target, destination, payload, or relevant shared state changes after confirmation, that confirmation no longer applies.'),
  staleBlanketSharedStateGateAbsent: !content.includes('and before any action that mutates shared or collaborator-visible state, production, or a third-party system'),
  pristineLiteralStubsUnselected: literals.excluded.every(item => !selected.has(item.id)),
};
const sampleOverrides = [];
for (const name of await fs.readdir(path.join(m.profile, 'system-prompts'))) {
  if (!name.startsWith('system-prompt-') || !name.endsWith('.md')) continue;
  const text = await fs.readFile(path.join(m.profile, 'system-prompts', name), 'utf8');
  const body = text.replace(/^<!--[^]*?-->\s*/, '').trim();
  const phrase = body.split('\n').map(s=>s.trim()).find(s=>s.length >= 45 && s.length < 200 && !s.includes('${') && /^[A-Za-z]/.test(s));
  if (!phrase) continue;
  const encoded = JSON.stringify(phrase).slice(1,-1);
  if ((!original.includes(phrase) && !original.includes(encoded)) &&
      (content.includes(phrase) || content.includes(encoded))) {
    sampleOverrides.push({name, phrase});
    if (sampleOverrides.length === 3) break;
  }
}
checks.communityOverrideSamplesPresent = sampleOverrides.length === 3;
const result = {
  checks, sampleOverrides, remainingBytecodeReported:clearBytecode,
  payloadSha256:crypto.createHash('sha256').update(content).digest('hex'),
  originalPayloadSha256:crypto.createHash('sha256').update(original).digest('hex'),
};
await fs.writeFile(path.join(release, 'payload-inspection.json'), JSON.stringify(result,null,2));
console.log(JSON.stringify(result,null,2));
if (Object.values(checks).some(v=>!v)) process.exitCode = 1;
