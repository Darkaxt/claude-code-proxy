// Keep the canonical named loop prompts; preserve reviewed overlapping blobs outside the active profile.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

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
  const missing = [];
  for (const [name, hashes] of Object.entries(reviewedLoopHashes)) {
    const source = path.join(profile, 'system-prompts', name);
    const destination = path.join(exclusions, name);
    let content, active = true;
    try { content = await fs.readFile(source); }
    catch (e) {
      if (e.code !== 'ENOENT') throw e;
      active = false;
      try { content = await fs.readFile(destination); }
      catch (e) { if (e.code !== 'ENOENT') throw e; missing.push(name); continue; }
    }
    const sha256 = crypto.createHash('sha256').update(content).digest('hex');
    if (!hashes.includes(sha256)) throw Error(`Loop overlap changed; review before excluding ${name}`);
    if (active) {
      try { await fs.access(destination); throw Error(`Loop exclusion already exists: ${name}`); }
      catch (e) { if (e.code !== 'ENOENT') throw e; }
    }
    members.push({ name, source, destination, sha256, active });
  }
  if (missing.length) {
    // The community removed these redundant blobs. Absence in a local profile
    // alone is not sufficient: bind it to the pinned Git tree and keep both
    // canonical variable-mapped replacements byte-identical to that source.
    if (missing.length !== Object.keys(reviewedLoopHashes).length) throw Error('Incomplete loop overlap pair');
    const manifest = JSON.parse(await fs.readFile(path.join(release, 'candidate.json'), 'utf8'));
    if (!/^[a-f0-9]{40}$/.test(manifest.promptCommit)) throw Error('Invalid pinned prompt commit');
    const source = path.join(release, 'prompt-source');
    const git = (...args) => execFileSync('git', ['-C', source, ...args], {windowsHide: true});
    if (git('rev-parse', 'HEAD').toString().trim() !== manifest.promptCommit) throw Error('Pinned prompt checkout changed');
    for (const name of missing) {
      if (git('ls-tree', manifest.promptCommit, '--', `system-prompts-lcc/${name}`).length) throw Error(`Missing local override present in pinned source: ${name}`);
    }
    const canonical = [];
    for (const name of ['system-prompt-loop-tick-loop-md-absent-dynamic.md', 'system-prompt-loop-tick-loop-md-tasks-dynamic.md']) {
      const expected = git('show', `${manifest.promptCommit}:system-prompts-lcc/${name}`);
      const actual = await fs.readFile(path.join(profile, 'system-prompts', name));
      if (!actual.equals(expected)) throw Error(`Canonical loop prompt changed: ${name}`);
      canonical.push({name, sha256: crypto.createHash('sha256').update(actual).digest('hex')});
    }
    return missing.map(name => ({name, disposition: 'absent-in-pinned-source', sourceCommit: manifest.promptCommit, canonical}));
  }
  // Review the whole pair before moving either member; preserve unknown edits.
  await fs.mkdir(exclusions, { recursive: true });
  for (const member of members) if (member.active) await fs.rename(member.source, member.destination);
  return members.map(({name, sha256}) => ({name, sha256}));
}
