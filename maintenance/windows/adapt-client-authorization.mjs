// A reviewed local prompt adaptation, applied before the unchanged community CLI.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';

export const promptId = 'system-prompt-action-safety-and-truthful-reporting';
export const reviewedCommunitySha256 = 'e33a97eb90ba7ce072e3f63af7fdb68233335a9134854c3695ff4e8ab2cfd8e5';
export const digest = text => crypto.createHash('sha256').update(text).digest('hex');
export const body = text => text.replace(/^<!--[^]*?-->\s*/, '').trim();
export const overrideUrl = new URL(`./client-overrides/${promptId}.md`, import.meta.url);

export async function adaptClientAuthorization(release) {
  const manifest = JSON.parse(await fs.readFile(path.join(release, 'candidate.json'), 'utf8'));
  if (manifest.schema !== 'claudegpt.client_candidate.v1') throw Error('Invalid candidate');
  const source = await fs.readFile(path.join(release, 'prompt-source/system-prompts-lcc', `${promptId}.md`), 'utf8');
  if (digest(source) !== reviewedCommunitySha256) throw Error('Action-safety community prompt changed; review before adapting');
  const replacement = await fs.readFile(overrideUrl, 'utf8');
  const target = path.join(manifest.profile, 'system-prompts', `${promptId}.md`);
  const current = await fs.readFile(target, 'utf8');
  if (current !== source && current !== replacement) throw Error('Action-safety profile has local edits; preserve and review');
  // Preserve the three unrelated paragraphs byte for byte.
  const oldParagraphs = body(source).split(/\r?\n\r?\n/);
  const newParagraphs = body(replacement).split(/\r?\n\r?\n/);
  if (oldParagraphs.length !== 5 || newParagraphs.length !== 5 ||
      [1, 3, 4].some(i => oldParagraphs[i] !== newParagraphs[i])) {
    throw Error('Credential, authorization provenance or reporting paragraphs changed');
  }
  if (current !== replacement) await fs.writeFile(target, replacement);
  const result = { revision: 'auth1', promptId, communitySha256: digest(source),
    adaptedSha256: digest(replacement), adaptedBodySha256: digest(body(replacement)),
    unchangedParagraphs: ['authorization-provenance', 'credential-protection', 'truthful-reporting'] };
  await fs.writeFile(path.join(release, 'authorization-adaptation.json'), JSON.stringify(result, null, 2));
  return result;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  if (!process.argv[2]) throw Error('Supply a prepared candidate release directory');
  console.log(JSON.stringify(await adaptClientAuthorization(path.resolve(process.argv[2])), null, 2));
}
