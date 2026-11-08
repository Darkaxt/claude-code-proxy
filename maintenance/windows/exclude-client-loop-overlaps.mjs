// Keep the canonical named loop prompts; preserve reviewed overlapping blobs outside the active profile.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

export const reviewedLoopHashes = {
  'inline-loop-tick-absent.md': [
    'fe804cf34f84e41ee8225d1d89cf80e9771e69177aaf75efdb4da37727eb8691',
    '8524ce5471fc59de9365c4b2fb98779d77e3892b75f86e2223cd67caa1da4fe6',
  ],
  'inline-loop-tick-tasks.md': [
    'aeefd41c47c60aa5a23155623d16fab3571ee5a36896956e1b83594b90b1f790',
    '8a243bbbc38420b169df9f9726baabb47f3c44ab435d49992180dcf117b4975f',
  ],
};

export async function excludeLoopOverlaps(release, profile) {
  const exclusions = path.join(release, 'profile-exclusions');
  const members = [];
  for (const [name, hashes] of Object.entries(reviewedLoopHashes)) {
    const source = path.join(profile, 'system-prompts', name);
    const destination = path.join(exclusions, name);
    let content, active = true;
    try { content = await fs.readFile(source); }
    catch (e) { if (e.code !== 'ENOENT') throw e; active = false; content = await fs.readFile(destination); }
    const sha256 = crypto.createHash('sha256').update(content).digest('hex');
    if (!hashes.includes(sha256)) throw Error(`Loop overlap changed; review before excluding ${name}`);
    if (active) {
      try { await fs.access(destination); throw Error(`Loop exclusion already exists: ${name}`); }
      catch (e) { if (e.code !== 'ENOENT') throw e; }
    }
    members.push({ name, source, destination, sha256, active });
  }
  // Review the whole pair before moving either member; preserve unknown edits.
  await fs.mkdir(exclusions, { recursive: true });
  for (const member of members) if (member.active) await fs.rename(member.source, member.destination);
  return members.map(({name, sha256}) => ({name, sha256}));
}
